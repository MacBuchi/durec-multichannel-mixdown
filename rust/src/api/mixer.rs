//! Bridge API: thin DTO layer over `durecmix-engine`.
//!
//! Keep this file free of logic — it only converts between bridge types and
//! engine types so the engine stays independently testable.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use anyhow::Context;
use durecmix_engine::analysis;
use durecmix_engine::chain::MasterParams;
use durecmix_engine::ixml;
use durecmix_engine::mix::{EqBand, HpfSlope, TrackEq, TrackParams};
use durecmix_engine::playback::Player;
use durecmix_engine::render::{self, LoudnessMode, OutputFormat, RenderSettings};
use durecmix_engine::session::Session;
use durecmix_engine::wav::WavReader;

use crate::frb_generated::StreamSink;

static PLAYER: OnceLock<Mutex<Option<Player>>> = OnceLock::new();

fn player_slot() -> &'static Mutex<Option<Player>> {
    PLAYER.get_or_init(|| Mutex::new(None))
}

pub struct ApiEqBand {
    pub enabled: bool,
    pub freq: f64,
    pub gain_db: f64,
    pub q: f64,
}

pub enum ApiHpfSlope {
    Db12,
    Db24,
}

pub struct ApiTrackEq {
    pub hpf_enabled: bool,
    pub hpf_freq: f64,
    pub hpf_slope: ApiHpfSlope,
    pub low: ApiEqBand,
    pub mid: ApiEqBand,
    pub high: ApiEqBand,
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
    pub eq: ApiTrackEq,
}

pub enum ApiFormat {
    Wav16,
    Wav24,
    Wav32Float,
    Flac16,
    Flac24,
    /// MP3 CBR 320 kbps (LAME).
    Mp3,
}

pub enum ApiLoudnessMode {
    None,
    PeakDbfs,
    LufsIntegrated,
}

/// Loudness target: `value` is dBFS for `PeakDbfs`, LUFS for
/// `LufsIntegrated`, ignored for `None`. (A plain struct instead of an enum
/// with payload — FRB would need freezed for the latter.)
pub struct ApiLoudness {
    pub mode: ApiLoudnessMode,
    pub value: f64,
}

/// Master-bus settings: loudness target, output format, limiter, dither.
pub struct ApiMaster {
    pub loudness: ApiLoudness,
    pub format: ApiFormat,
    pub limiter_enabled: bool,
    pub ceiling_dbtp: f64,
    pub dither: bool,
}

pub struct RecordingInfo {
    pub path: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub num_frames: u64,
    pub duration_seconds: f64,
    pub tracks: Vec<ApiTrack>,
    /// Master settings restored from the session (defaults for a fresh take).
    pub master: ApiMaster,
}

pub struct ApiRenderReport {
    pub peak_dbfs_before: f64,
    pub gain_applied_db: f64,
    pub duration_seconds: f64,
    pub sample_rate: u32,
    pub integrated_lufs: f64,
    pub true_peak_dbtp: f64,
    pub lra_lu: f64,
    pub source_integrated_lufs: f64,
}

/// One event of the render stream: progress ticks while rendering, and the
/// final event (progress == 1.0) carries the report.
pub struct RenderEvent {
    pub progress: f32,
    pub report: Option<ApiRenderReport>,
}

fn to_engine_band(b: &ApiEqBand) -> EqBand {
    EqBand {
        enabled: b.enabled,
        freq: b.freq,
        gain_db: b.gain_db,
        q: b.q,
    }
}

fn from_engine_band(b: &EqBand) -> ApiEqBand {
    ApiEqBand {
        enabled: b.enabled,
        freq: b.freq,
        gain_db: b.gain_db,
        q: b.q,
    }
}

fn to_engine_eq(eq: &ApiTrackEq) -> TrackEq {
    TrackEq {
        hpf_enabled: eq.hpf_enabled,
        hpf_freq: eq.hpf_freq,
        hpf_slope: match eq.hpf_slope {
            ApiHpfSlope::Db12 => HpfSlope::Db12,
            ApiHpfSlope::Db24 => HpfSlope::Db24,
        },
        low: to_engine_band(&eq.low),
        mid: to_engine_band(&eq.mid),
        high: to_engine_band(&eq.high),
    }
}

fn from_engine_eq(eq: &TrackEq) -> ApiTrackEq {
    ApiTrackEq {
        hpf_enabled: eq.hpf_enabled,
        hpf_freq: eq.hpf_freq,
        hpf_slope: match eq.hpf_slope {
            HpfSlope::Db12 => ApiHpfSlope::Db12,
            HpfSlope::Db24 => ApiHpfSlope::Db24,
        },
        low: from_engine_band(&eq.low),
        mid: from_engine_band(&eq.mid),
        high: from_engine_band(&eq.high),
    }
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
        eq: to_engine_eq(&t.eq),
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
        eq: from_engine_eq(&t.eq),
    }
}

fn to_engine_settings(m: &ApiMaster) -> RenderSettings {
    RenderSettings {
        loudness: match m.loudness.mode {
            ApiLoudnessMode::None => LoudnessMode::None,
            ApiLoudnessMode::PeakDbfs => LoudnessMode::PeakDbfs(m.loudness.value),
            ApiLoudnessMode::LufsIntegrated => LoudnessMode::LufsIntegrated(m.loudness.value),
        },
        format: match m.format {
            ApiFormat::Wav16 => OutputFormat::Wav16,
            ApiFormat::Wav24 => OutputFormat::Wav24,
            ApiFormat::Wav32Float => OutputFormat::Wav32Float,
            ApiFormat::Flac16 => OutputFormat::Flac16,
            ApiFormat::Flac24 => OutputFormat::Flac24,
            ApiFormat::Mp3 => OutputFormat::Mp3,
        },
        limiter_enabled: m.limiter_enabled,
        ceiling_dbtp: m.ceiling_dbtp,
        dither: m.dither,
    }
}

fn from_engine_settings(s: &RenderSettings) -> ApiMaster {
    ApiMaster {
        loudness: match s.loudness {
            LoudnessMode::None => ApiLoudness {
                mode: ApiLoudnessMode::None,
                value: 0.0,
            },
            LoudnessMode::PeakDbfs(db) => ApiLoudness {
                mode: ApiLoudnessMode::PeakDbfs,
                value: db,
            },
            LoudnessMode::LufsIntegrated(lufs) => ApiLoudness {
                mode: ApiLoudnessMode::LufsIntegrated,
                value: lufs,
            },
        },
        format: match s.format {
            OutputFormat::Wav16 => ApiFormat::Wav16,
            OutputFormat::Wav24 => ApiFormat::Wav24,
            OutputFormat::Wav32Float => ApiFormat::Wav32Float,
            OutputFormat::Flac16 => ApiFormat::Flac16,
            OutputFormat::Flac24 => ApiFormat::Flac24,
            OutputFormat::Mp3 => ApiFormat::Mp3,
        },
        limiter_enabled: s.limiter_enabled,
        ceiling_dbtp: s.ceiling_dbtp,
        dither: s.dither,
    }
}

fn to_master_params(m: &ApiMaster) -> MasterParams {
    MasterParams {
        limiter_enabled: m.limiter_enabled,
        ceiling_dbtp: m.ceiling_dbtp,
    }
}

/// Open a multichannel WAV/RF64, parse iXML track metadata and merge the
/// session at `session_path` (falling back once to a legacy sibling file
/// next to the WAV, from before sessions moved into the app container).
pub fn load_recording(path: String, session_path: String) -> anyhow::Result<RecordingInfo> {
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

    let session = match Session::load_or_migrate(Path::new(&session_path), Path::new(&path)) {
        Some(saved) => saved.merged_with(&infos),
        None => Session::from_track_info(&infos),
    };

    Ok(RecordingInfo {
        path,
        sample_rate: spec.sample_rate,
        channels: spec.channels,
        bits_per_sample: spec.bits_per_sample,
        num_frames: reader.num_frames(),
        duration_seconds: reader.duration_seconds(),
        tracks: session.tracks.iter().map(from_engine_track).collect(),
        master: from_engine_settings(&session.settings),
    })
}

/// Persist the current mix to `session_path` (an app-container location
/// chosen by the UI layer; parent directories are created as needed).
pub fn save_session(
    session_path: String,
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
) -> anyhow::Result<()> {
    let session = Session {
        tracks: tracks.iter().map(to_engine_track).collect(),
        settings: to_engine_settings(&master),
        ..Session::default()
    };
    session
        .save(Path::new(&session_path))
        .context("save session")?;
    Ok(())
}

/// Render the stereo mixdown. Streams `RenderEvent`s to Dart: progress in
/// 0.0..1.0 while rendering, then a final event with the report attached.
pub fn render_mix(
    wav_path: String,
    out_path: String,
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
    events: StreamSink<RenderEvent>,
) -> anyhow::Result<()> {
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let settings = to_engine_settings(&master);
    let report = render::render_to_file(&wav_path, &engine_tracks, &settings, &out_path, |p| {
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
            integrated_lufs: report.integrated_lufs,
            true_peak_dbtp: report.true_peak_dbtp,
            lra_lu: report.lra_lu,
            source_integrated_lufs: report.source_integrated_lufs,
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
    /// Integrated loudness since start/seek — pre-normalisation preview.
    pub lufs_integrated: f32,
    /// Running true-peak max since start/seek (linear).
    pub true_peak: f32,
    pub correlation: f32,
}

/// Start (or restart) live playback of the mix at `start_frame`.
pub fn player_start(
    path: String,
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
    start_frame: u64,
) -> anyhow::Result<()> {
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let new_player = Player::start(&path, engine_tracks, to_master_params(&master), start_frame)
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

/// Push updated mix/master parameters to the running player (~0.2 s).
pub fn player_update_params(tracks: Vec<ApiTrack>, master: ApiMaster) {
    if let Some(p) = player_slot().lock().unwrap().as_ref() {
        p.update_params(
            tracks.iter().map(to_engine_track).collect(),
            to_master_params(&master),
        );
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
                lufs_integrated: s.lufs_integrated,
                true_peak: s.true_peak,
                correlation: s.correlation,
            }
        }
        None => ApiPlayerState {
            playing: false,
            position_frames: 0,
            peak_l: 0.0,
            peak_r: 0.0,
            lufs_momentary: -70.0,
            lufs_integrated: -70.0,
            true_peak: 0.0,
            correlation: 0.0,
        },
    }
}
