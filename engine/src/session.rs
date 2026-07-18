//! Per-recording session persistence (successor of MixConf.json).
//!
//! A session file stores every track's mix parameters plus master settings,
//! so reopening a recording restores the mix exactly. The caller (the app)
//! decides where sessions live — sandboxed platforms (macOS App Sandbox,
//! Android SAF) forbid writing next to the source WAV, so the app passes a
//! path inside its own container. Legacy sessions that were written as a
//! sibling of the WAV (`<name>.durecmix.json`) are still read as a one-time
//! migration fallback.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::ixml::{default_pan_for_name, TrackInfo};
use crate::mix::TrackParams;
use crate::render::RenderSettings;

/// v1: tracks + loudness/format. v2: adds per-track EQ. v3: adds reference
/// mastering. v4: multi-reference list (serde defaults keep older files
/// loadable unchanged).
pub const SESSION_VERSION: u32 = 4;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub version: u32,
    pub tracks: Vec<TrackParams>,
    pub settings: RenderSettings,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            version: SESSION_VERSION,
            tracks: Vec::new(),
            settings: RenderSettings::default(),
        }
    }
}

/// True for channel names that are clearly monitor/cue feeds, which never
/// belong in a fresh mixdown (they double the FOH signal and push a unity
/// mix far over full scale). Conservative on purpose.
pub fn is_monitor_feed(name: &str) -> bool {
    let n = name.to_lowercase();
    n.contains("in ear")
        || n.contains("inear")
        || n.contains("phones")
        || n.contains("headphone")
        || n.contains("talkback")
        || n.contains("iem")
        || n.contains("line out")
        || n.contains("monitor")
}

impl Session {
    /// Build a fresh session from iXML track info, applying the L/R pan
    /// heuristic for stereo pairs and excluding obvious monitor feeds
    /// (In Ear / Phones / Talkback etc.) from the mix. `*_Out` stems are
    /// deliberately NOT excluded — engineers often mix from those.
    pub fn from_track_info(tracks: &[TrackInfo]) -> Self {
        Self {
            tracks: tracks
                .iter()
                .map(|t| {
                    let mut p =
                        TrackParams::new(t.index, t.name.clone(), default_pan_for_name(&t.name));
                    p.in_mix = !is_monitor_feed(&t.name);
                    p
                })
                .collect(),
            ..Self::default()
        }
    }

    /// Merge saved parameters into a freshly scanned track list: tracks are
    /// matched by name (fall back to index), so a session survives re-scans
    /// and channel-order changes between takes.
    pub fn merged_with(&self, fresh: &[TrackInfo]) -> Session {
        let tracks = fresh
            .iter()
            .map(|info| {
                self.tracks
                    .iter()
                    .find(|t| t.name == info.name)
                    .or_else(|| self.tracks.iter().find(|t| t.index == info.index))
                    .map(|saved| TrackParams {
                        index: info.index,
                        name: info.name.clone(),
                        ..saved.clone()
                    })
                    .unwrap_or_else(|| {
                        TrackParams::new(
                            info.index,
                            info.name.clone(),
                            default_pan_for_name(&info.name),
                        )
                    })
            })
            .collect();
        Session {
            version: SESSION_VERSION,
            tracks,
            settings: self.settings.clone(),
        }
    }

    /// Where pre-sandbox-fix versions stored the session: next to the WAV.
    /// Only used as a read-only migration fallback in [`Session::load_or_migrate`].
    pub fn legacy_sibling_path(wav_path: &Path) -> std::path::PathBuf {
        wav_path.with_extension("durecmix.json")
    }

    pub fn load(path: &Path) -> Result<Session> {
        let data = std::fs::read_to_string(path)?;
        Ok(serde_json::from_str(&data)?)
    }

    /// Load `session_path`; if it is absent or unreadable, fall back once to
    /// the legacy sibling file next to the WAV. Returns `None` when neither
    /// exists (fresh recording).
    pub fn load_or_migrate(session_path: &Path, wav_path: &Path) -> Option<Session> {
        Session::load(session_path)
            .or_else(|_| Session::load(&Session::legacy_sibling_path(wav_path)))
            .ok()
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_string_pretty(self)?;
        std::fs::write(path, data)?;
        Ok(())
    }
}
