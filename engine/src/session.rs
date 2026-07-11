//! Per-recording session persistence (successor of MixConf.json).
//!
//! A session file lives next to the source WAV (`<name>.durecmix.json`) and
//! stores every track's mix parameters plus master settings, so reopening a
//! recording restores the mix exactly.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::ixml::{default_pan_for_name, TrackInfo};
use crate::mix::TrackParams;
use crate::render::{LoudnessMode, OutputFormat, RenderSettings};

pub const SESSION_VERSION: u32 = 1;

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
            settings: RenderSettings {
                loudness: LoudnessMode::PeakDbfs(-1.0),
                format: OutputFormat::Wav24,
            },
        }
    }
}

impl Session {
    /// Build a fresh session from iXML track info, applying the L/R pan
    /// heuristic for stereo pairs.
    pub fn from_track_info(tracks: &[TrackInfo]) -> Self {
        Self {
            tracks: tracks
                .iter()
                .map(|t| TrackParams::new(t.index, t.name.clone(), default_pan_for_name(&t.name)))
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
            settings: self.settings,
        }
    }

    pub fn session_path_for(wav_path: &Path) -> std::path::PathBuf {
        wav_path.with_extension("durecmix.json")
    }

    pub fn load(path: &Path) -> Result<Session> {
        let data = std::fs::read_to_string(path)?;
        Ok(serde_json::from_str(&data)?)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let data = serde_json::to_string_pretty(self)?;
        std::fs::write(path, data)?;
        Ok(())
    }
}
