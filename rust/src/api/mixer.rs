//! Bridge API: thin DTO layer over `durecmix-engine`.
//!
//! Keep this file free of logic — it only converts between bridge types and
//! engine types so the engine stays independently testable.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use anyhow::Context;
use durecmix_engine::analysis;
use durecmix_engine::ixml;
use durecmix_engine::mix::TrackParams;
use durecmix_engine::playback::Player;
use durecmix_engine::render::{self, LoudnessMode, OutputFormat, RenderSettings};
use durecmix_engine::session::Session;
use durecmix_engine::wav::WavReader;

use crate::frb_generated::StreamSink;

static PLAYER: OnceLock<Mutex<Option<Player>>> = OnceLock::new();

fn player_slot() -> &'static Mutex<Option<Player>> {
    PLAYER.get_or_init(|| Mutex::new(None))
}

pub struct ApiTrack {
    pub index: u32,
    pub name: String,
    pub gain_db: f64,
    pub pan: f64,
    pub polarity_invert: bool,
    pub muted: bool,
    pub solo: bool,
    pub in_mix: bool,
}

pub enum ApiFormat {
    Wav16,
    Wav24,
    Wav32Float,
}

pub struct RecordingInfo {
    pub path: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub num_frames: u64,
    pub duration_seconds: f64,
    pub tracks: Vec<ApiTrack>,
}

pub struct ApiRenderReport {
    pub peak_dbfs_before: f64,
    pub gain_applied_db: f64,
    pub duration_seconds: f64,
    pub sample_rate: u32,
}

/// One event of the render stream: progress ticks while rendering, and the
/// final event (progress == 1.0) carries the report.
pub struct RenderEvent {
    pub progress: f32,
    pub report: Option<ApiRenderReport>,
}

fn to_engine_track(t: &ApiTrack) -> TrackParams {
    TrackParams {
        index: t.index,
        name: t.name.clone(),
        gain_db: t.gain_db,
        pan: t.pan,
        polarity_invert: t.polarity_invert,
        muted: t.muted,
        solo: t.solo,
        in_mix: t.in_mix,
    }
}

fn from_engine_track(t: &TrackParams) -> ApiTrack {
    ApiTrack {
        index: t.index,
        name: t.name.clone(),
        gain_db: t.gain_db,
        pan: t.pan,
        polarity_invert: t.polarity_invert,
        muted: t.muted,
        solo: t.solo,
        in_mix: t.in_mix,
    }
}

/// `peak_dbfs`: `Some(target)` normalises the mix peak to that dBFS value,
/// `None` leaves levels untouched (clip-protected only).
fn to_engine_settings(peak_dbfs: Option<f64>, format: &ApiFormat) -> RenderSettings {
    RenderSettings {
        loudness: match peak_dbfs {
            None => LoudnessMode::None,
            Some(db) => LoudnessMode::PeakDbfs(db),
        },
        format: match format {
            ApiFormat::Wav16 => OutputFormat::Wav16,
            ApiFormat::Wav24 => OutputFormat::Wav24,
            ApiFormat::Wav32Float => OutputFormat::Wav32Float,
        },
    }
}

/// Open a multichannel WAV/RF64, parse iXML track metadata and merge any
/// existing session file next to it.
pub fn load_recording(path: String) -> anyhow::Result<RecordingInfo> {
    let reader = WavReader::open(&path).with_context(|| format!("open {path}"))?;
    let spec = reader.spec();

    let infos = reader.ixml().map(ixml::parse_tracks).unwrap_or_default();
    // Files without iXML still get one generic track per channel.
    let infos = if infos.is_empty() {
        (1..=spec.channels as u32)
            .map(|i| ixml::TrackInfo {
                index: i,
                name: format!("Channel {i}"),
            })
            .collect()
    } else {
        infos
    };

    let session_path = Session::session_path_for(Path::new(&path));
    let session = match Session::load(&session_path) {
        Ok(saved) => saved.merged_with(&infos),
        Err(_) => Session::from_track_info(&infos),
    };

    Ok(RecordingInfo {
        path,
        sample_rate: spec.sample_rate,
        channels: spec.channels,
        bits_per_sample: spec.bits_per_sample,
        num_frames: reader.num_frames(),
        duration_seconds: reader.duration_seconds(),
        tracks: session.tracks.iter().map(from_engine_track).collect(),
    })
}

/// Persist the current mix next to the source WAV (`<name>.durecmix.json`).
pub fn save_session(
    wav_path: String,
    tracks: Vec<ApiTrack>,
    peak_dbfs: Option<f64>,
    format: ApiFormat,
) -> anyhow::Result<()> {
    let session = Session {
        tracks: tracks.iter().map(to_engine_track).collect(),
        settings: to_engine_settings(peak_dbfs, &format),
        ..Session::default()
    };
    let path = Session::session_path_for(Path::new(&wav_path));
    session.save(&path).context("save session")?;
    Ok(())
}

/// Render the stereo mixdown. Streams `RenderEvent`s to Dart: progress in
/// 0.0..1.0 while rendering, then a final event with the report attached.
pub fn render_mix(
    wav_path: String,
    out_path: String,
    tracks: Vec<ApiTrack>,
    peak_dbfs: Option<f64>,
    format: ApiFormat,
    events: StreamSink<RenderEvent>,
) -> anyhow::Result<()> {
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let settings = to_engine_settings(peak_dbfs, &format);
    let report = render::render_to_wav(&wav_path, &engine_tracks, &settings, &out_path, |p| {
        if p < 1.0 {
            let _ = events.add(RenderEvent {
                progress: p,
                report: None,
            });
        }
    })
    .with_context(|| format!("render {wav_path}"))?;
    let _ = events.add(RenderEvent {
        progress: 1.0,
        report: Some(ApiRenderReport {
            peak_dbfs_before: report.peak_dbfs_before,
            gain_applied_db: report.gain_applied_db,
            duration_seconds: report.duration_seconds,
            sample_rate: report.sample_rate,
        }),
    });
    Ok(())
}

// ── waveform analysis ───────────────────────────────────────────────────────

pub struct ApiChannelWaveform {
    pub min: Vec<f32>,
    pub max: Vec<f32>,
    pub peak_dbfs: f32,
}

/// Streamed min/max envelope of every channel, `buckets` values per channel.
pub fn analyze_waveforms(path: String, buckets: usize) -> anyhow::Result<Vec<ApiChannelWaveform>> {
    let waves =
        analysis::analyze_waveforms(&path, buckets).with_context(|| format!("analyze {path}"))?;
    Ok(waves
        .into_iter()
        .map(|w| ApiChannelWaveform {
            min: w.min,
            max: w.max,
            peak_dbfs: w.peak_dbfs,
        })
        .collect())
}

// ── live preview playback ───────────────────────────────────────────────────

pub struct ApiPlayerState {
    pub playing: bool,
    pub position_frames: u64,
    pub peak_l: f32,
    pub peak_r: f32,
    pub lufs_momentary: f32,
    pub correlation: f32,
}

/// Start (or restart) live playback of the mix at `start_frame`.
pub fn player_start(path: String, tracks: Vec<ApiTrack>, start_frame: u64) -> anyhow::Result<()> {
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let new_player = Player::start(&path, engine_tracks, start_frame)
        .with_context(|| format!("start playback of {path}"))?;
    let mut slot = player_slot().lock().unwrap();
    if let Some(old) = slot.take() {
        old.stop();
    }
    *slot = Some(new_player);
    Ok(())
}

pub fn player_stop() {
    let mut slot = player_slot().lock().unwrap();
    if let Some(p) = slot.take() {
        p.stop();
    }
}

pub fn player_seek(frame: u64) {
    if let Some(p) = player_slot().lock().unwrap().as_ref() {
        p.seek(frame);
    }
}

/// Push updated mix parameters to the running player (audible in ~0.2 s).
pub fn player_update_tracks(tracks: Vec<ApiTrack>) {
    if let Some(p) = player_slot().lock().unwrap().as_ref() {
        p.update_tracks(tracks.iter().map(to_engine_track).collect());
    }
}

/// Poll playback position and meters (call at UI frame rate).
#[flutter_rust_bridge::frb(sync)]
pub fn player_state() -> ApiPlayerState {
    let slot = player_slot().lock().unwrap();
    match slot.as_ref() {
        Some(p) => {
            let s = p.snapshot();
            ApiPlayerState {
                playing: s.playing,
                position_frames: s.position_frames,
                peak_l: s.peak_l,
                peak_r: s.peak_r,
                lufs_momentary: s.lufs_momentary,
                correlation: s.correlation,
            }
        }
        None => ApiPlayerState {
            playing: false,
            position_frames: 0,
            peak_l: 0.0,
            peak_r: 0.0,
            lufs_momentary: -70.0,
            correlation: 0.0,
        },
    }
}
