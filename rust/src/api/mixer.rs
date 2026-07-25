//! Bridge API: thin DTO layer over `durecmix-engine`.
//!
//! Keep this file free of logic — it only converts between bridge types and
//! engine types so the engine stays independently testable.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use anyhow::Context;
use durecmix_engine::analysis;
#[cfg(not(target_family = "wasm"))]
use durecmix_engine::chain::MasterParams;
use durecmix_engine::ixml;
use durecmix_engine::mastering::{
    design_mastering, merge_profiles, MasteringPlan, MasteringStats, ReferenceProfile,
    PROFILE_VERSION,
};
use durecmix_engine::mix::{EqBand, HpfSlope, TrackEq, TrackParams};
// Live playback is native-only until PLAN-PWA S4 (Web Audio); the API
// surface below stays identical on wasm so the generated bindings match.
#[cfg(not(target_family = "wasm"))]
use durecmix_engine::playback::Player;
use durecmix_engine::reference;
use durecmix_engine::render::{
    self, LoudnessMode, MasteringReference, MasteringSettings, OutputFormat, RenderSettings,
};
use durecmix_engine::session::Session;
use durecmix_engine::sink::OutputHandle;
use durecmix_engine::wav::{self, InputHandle};

/// Prefer the raw fd when the platform provided one (Android SAF), else the
/// path. The path is still passed for display/session purposes.
fn input_handle(path: &str, fd: Option<i32>) -> InputHandle {
    match fd {
        Some(fd) => InputHandle::Fd(fd),
        None => InputHandle::Path(path.to_string()),
    }
}

use crate::frb_generated::StreamSink;

#[cfg(not(target_family = "wasm"))]
static PLAYER: OnceLock<Mutex<Option<Player>>> = OnceLock::new();

#[cfg(not(target_family = "wasm"))]
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

/// Master-bus settings: loudness target, output format, limiter, dither,
/// trim range and fades.
pub struct ApiMaster {
    pub loudness: ApiLoudness,
    pub format: ApiFormat,
    pub limiter_enabled: bool,
    pub ceiling_dbtp: f64,
    pub dither: bool,
    pub trim_start_frame: u64,
    /// One-past-last frame; `None` = end of file.
    pub trim_end_frame: Option<u64>,
    pub fade_in_ms: f64,
    pub fade_out_ms: f64,
    /// Reference mastering (session state; the render acts on the profile
    /// passed to `render_mix`, not on these fields alone). Multiple
    /// references average into one genre target curve.
    pub mastering_enabled: bool,
    pub mastering_references: Vec<ApiMasteringReference>,
}

/// One chosen mastering reference (path/URI + display name).
pub struct ApiMasteringReference {
    pub path: String,
    pub name: String,
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

/// Lightweight file metadata for the in-app WAV browser: header parse only
/// (no audio scan, no session I/O) — cheap even on slow USB media.
pub struct ApiProbe {
    pub channels: u16,
    pub sample_rate: u32,
    pub bits_per_sample: u16,
    pub num_frames: u64,
    pub duration_seconds: f64,
    /// Number of iXML track entries; 0 when the file carries no iXML.
    pub ixml_track_count: u32,
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
    pub mastering_applied: bool,
    pub mastering_gain_db: f64,
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
        trim_start_frame: m.trim_start_frame,
        trim_end_frame: m.trim_end_frame,
        fade_in_ms: m.fade_in_ms,
        fade_out_ms: m.fade_out_ms,
        mastering: (m.mastering_enabled || !m.mastering_references.is_empty()).then(|| {
            MasteringSettings {
                enabled: m.mastering_enabled,
                // Legacy single-reference fields mirror the first entry so a
                // v3 reader of the session file still shows something sane.
                reference_path: m
                    .mastering_references
                    .first()
                    .map(|r| r.path.clone())
                    .unwrap_or_default(),
                reference_name: m
                    .mastering_references
                    .first()
                    .map(|r| r.name.clone())
                    .unwrap_or_default(),
                references: m
                    .mastering_references
                    .iter()
                    .map(|r| MasteringReference {
                        path: r.path.clone(),
                        name: r.name.clone(),
                    })
                    .collect(),
            }
        }),
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
        trim_start_frame: s.trim_start_frame,
        trim_end_frame: s.trim_end_frame,
        fade_in_ms: s.fade_in_ms,
        fade_out_ms: s.fade_out_ms,
        mastering_enabled: s.mastering.as_ref().is_some_and(|m| m.enabled),
        mastering_references: s
            .mastering
            .as_ref()
            .map(|m| {
                m.normalized_references()
                    .into_iter()
                    .map(|r| ApiMasteringReference {
                        path: r.path,
                        name: r.name,
                    })
                    .collect()
            })
            .unwrap_or_default(),
    }
}

#[cfg(not(target_family = "wasm"))]
fn to_master_params(m: &ApiMaster) -> MasterParams {
    MasterParams {
        limiter_enabled: m.limiter_enabled,
        ceiling_dbtp: m.ceiling_dbtp,
    }
}

/// Open a multichannel WAV/RF64, parse iXML track metadata and merge the
/// session at `session_path` (falling back once to a legacy sibling file
/// next to the WAV, from before sessions moved into the app container).
/// Probe a WAV without loading a session or scanning audio — used by the
/// in-app browser to annotate directory listings.
pub fn probe_recording(path: String, fd: Option<i32>) -> anyhow::Result<ApiProbe> {
    let info = wav::probe(&input_handle(&path, fd)).with_context(|| format!("probe {path}"))?;
    Ok(ApiProbe {
        channels: info.channels,
        sample_rate: info.sample_rate,
        bits_per_sample: info.bits_per_sample,
        num_frames: info.num_frames,
        duration_seconds: info.duration_seconds,
        ixml_track_count: info.ixml_track_count,
    })
}

/// One RIFF chunk located by [`scan_wav_chunks`].
pub struct ApiChunk {
    pub id: String,
    pub offset: u64,
    pub size: u64,
}

/// Outcome of one scan window; `next_offset` is `None` when done.
pub struct ApiChunkScan {
    pub chunks: Vec<ApiChunk>,
    pub next_offset: Option<u64>,
}

/// Locate RIFF chunks in a buffer the caller fetched — the web build has no
/// filesystem, so Dart reads ranges out of a `Blob` and the parsing stays
/// here (docs/PLAN-PWA.md S2). `buf` covers `[buf_offset, +buf.len())`.
#[flutter_rust_bridge::frb(sync)]
pub fn scan_wav_chunks(
    buf: Vec<u8>,
    buf_offset: u64,
    file_size: u64,
) -> anyhow::Result<ApiChunkScan> {
    let scan = wav::scan_chunks(&buf, buf_offset, file_size)
        .with_context(|| format!("scan chunks at {buf_offset}"))?;
    Ok(ApiChunkScan {
        chunks: scan
            .chunks
            .into_iter()
            .map(|c| ApiChunk {
                id: c.id,
                offset: c.offset,
                size: c.size,
            })
            .collect(),
        next_offset: scan.next_offset,
    })
}

/// Assemble a probe from the chunk payloads the caller fetched after
/// [`scan_wav_chunks`] — the filesystem-free twin of [`probe_recording`].
#[flutter_rust_bridge::frb(sync)]
pub fn probe_from_chunks(
    fmt_chunk: Vec<u8>,
    ixml_chunk: Option<Vec<u8>>,
    data_bytes: u64,
) -> anyhow::Result<ApiProbe> {
    let info = wav::probe_from_parts(&fmt_chunk, ixml_chunk.as_deref(), data_bytes)
        .context("probe from chunks")?;
    Ok(ApiProbe {
        channels: info.channels,
        sample_rate: info.sample_rate,
        bits_per_sample: info.bits_per_sample,
        num_frames: info.num_frames,
        duration_seconds: info.duration_seconds,
        ixml_track_count: info.ixml_track_count,
    })
}

/// Track names out of an iXML payload the caller fetched (web build).
#[flutter_rust_bridge::frb(sync)]
pub fn track_names_from_ixml(ixml_chunk: Vec<u8>) -> Vec<String> {
    wav::track_names_from_ixml(&ixml_chunk)
}

pub fn load_recording(
    path: String,
    session_path: String,
    fd: Option<i32>,
) -> anyhow::Result<RecordingInfo> {
    let reader = input_handle(&path, fd)
        .open()
        .with_context(|| format!("open {path}"))?;
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

/// Open a take from chunk payloads the caller fetched, for platforms
/// without a filesystem (web). `session_json` restores a stored mix when
/// the caller has one — the browser keeps sessions itself, since there is
/// no app container to read (docs/PLAN-PWA.md S2b).
pub fn load_recording_from_chunks(
    source: String,
    fmt_chunk: Vec<u8>,
    ixml_chunk: Option<Vec<u8>>,
    data_bytes: u64,
    session_json: Option<String>,
) -> anyhow::Result<RecordingInfo> {
    let spec = wav::spec_from_fmt_chunk(&fmt_chunk).context("parse fmt chunk")?;
    let infos = ixml_chunk
        .as_deref()
        .map(|x| ixml::parse_tracks(&String::from_utf8_lossy(x)))
        .unwrap_or_default();
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

    let session = match session_json.as_deref().and_then(Session::from_json) {
        Some(saved) => saved.merged_with(&infos),
        None => Session::from_track_info(&infos),
    };

    let num_frames = data_bytes / spec.bytes_per_frame() as u64;
    Ok(RecordingInfo {
        path: source,
        sample_rate: spec.sample_rate,
        channels: spec.channels,
        bits_per_sample: spec.bits_per_sample,
        num_frames,
        duration_seconds: num_frames as f64 / spec.sample_rate as f64,
        tracks: session.tracks.iter().map(from_engine_track).collect(),
        master: from_engine_settings(&session.settings),
    })
}

/// Serialise the current mix, for platforms that store sessions themselves
/// (web — there is no app container to write into).
#[flutter_rust_bridge::frb(sync)]
pub fn session_to_json(tracks: Vec<ApiTrack>, master: ApiMaster) -> anyhow::Result<String> {
    let session = Session {
        tracks: tracks.iter().map(to_engine_track).collect(),
        settings: to_engine_settings(&master),
        ..Session::default()
    };
    session.to_json().context("serialise session")
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
#[allow(clippy::too_many_arguments)] // flat FRB surface, one arg per Dart param
pub fn render_mix(
    wav_path: String,
    out_path: String,
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
    reference: Option<ApiReferenceProfile>,
    input_fd: Option<i32>,
    output_fd: Option<i32>,
    events: StreamSink<RenderEvent>,
) -> anyhow::Result<()> {
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let settings = to_engine_settings(&master);
    let profile = match (&master.mastering_enabled, reference) {
        (true, Some(p)) => Some(to_engine_profile(p)),
        _ => None,
    };
    let output = match output_fd {
        Some(fd) => OutputHandle::Fd(fd),
        None => OutputHandle::Path(out_path.clone()),
    };
    let report = render::render_io(
        &input_handle(&wav_path, input_fd),
        &engine_tracks,
        &settings,
        profile.as_ref(),
        &output,
        |p| {
            if p < 1.0 {
                let _ = events.add(RenderEvent {
                    progress: p,
                    report: None,
                });
            }
        },
    )
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
            mastering_applied: report.mastering_applied,
            mastering_gain_db: report.mastering_gain_db,
        }),
    });
    Ok(())
}

// ── reference mastering ─────────────────────────────────────────────────────

/// Mirror of the engine's `ReferenceProfile` (cached as JSON on the Dart
/// side so a reference is analyzed once).
pub struct ApiReferenceProfile {
    pub version: u32,
    pub sample_rate: u32,
    pub fft_size: u32,
    pub piece_seconds: f64,
    pub duration_seconds: f64,
    pub mid_rms: f64,
    pub side_rms: f64,
    pub mid_spectrum: Vec<f32>,
    pub side_spectrum: Vec<f32>,
}

fn to_engine_profile(p: ApiReferenceProfile) -> ReferenceProfile {
    ReferenceProfile {
        version: p.version,
        sample_rate: p.sample_rate,
        fft_size: p.fft_size,
        piece_seconds: p.piece_seconds,
        duration_seconds: p.duration_seconds,
        mid_rms: p.mid_rms,
        side_rms: p.side_rms,
        mid_spectrum: p.mid_spectrum,
        side_spectrum: p.side_spectrum,
    }
}

fn from_engine_profile(p: ReferenceProfile) -> ApiReferenceProfile {
    ApiReferenceProfile {
        version: p.version,
        sample_rate: p.sample_rate,
        fft_size: p.fft_size,
        piece_seconds: p.piece_seconds,
        duration_seconds: p.duration_seconds,
        mid_rms: p.mid_rms,
        side_rms: p.side_rms,
        mid_spectrum: p.mid_spectrum,
        side_spectrum: p.side_spectrum,
    }
}

/// The profile format version currently produced by the engine; the Dart
/// cache keys on it so algorithm changes invalidate stored profiles.
pub fn reference_profile_version() -> u32 {
    PROFILE_VERSION
}

/// Average several reference profiles into one mastering target (one vote
/// per song; spectra merged on the highest sample-rate grid).
pub fn merge_reference_profiles(
    profiles: Vec<ApiReferenceProfile>,
) -> anyhow::Result<ApiReferenceProfile> {
    let engine: Vec<ReferenceProfile> = profiles.into_iter().map(to_engine_profile).collect();
    Ok(from_engine_profile(
        merge_profiles(&engine).context("merge reference profiles")?,
    ))
}

/// Loudest-piece statistics of the current mix (mirror of the engine's
/// `MasteringStats`) — the target half of a mastering-preview plan. Runtime
/// only, never persisted.
pub struct ApiMixStats {
    pub sample_rate: u32,
    pub duration_seconds: f64,
    pub mid_rms: f64,
    pub side_rms: f64,
    pub mid_spectrum: Vec<f64>,
    pub side_spectrum: Vec<f64>,
    pub mid_power: Vec<f64>,
    pub side_power: Vec<f64>,
}

fn to_engine_stats(s: ApiMixStats) -> MasteringStats {
    MasteringStats {
        sample_rate: s.sample_rate,
        duration_seconds: s.duration_seconds,
        mid_rms: s.mid_rms,
        side_rms: s.side_rms,
        mid_spectrum: s.mid_spectrum,
        side_spectrum: s.side_spectrum,
        mid_power: s.mid_power,
        side_power: s.side_power,
    }
}

fn from_engine_stats(s: MasteringStats) -> ApiMixStats {
    ApiMixStats {
        sample_rate: s.sample_rate,
        duration_seconds: s.duration_seconds,
        mid_rms: s.mid_rms,
        side_rms: s.side_rms,
        mid_spectrum: s.mid_spectrum,
        side_spectrum: s.side_spectrum,
        mid_power: s.mid_power,
        side_power: s.side_power,
    }
}

/// Design the preview mastering plan when everything needed is present.
fn preview_plan(
    master: &ApiMaster,
    stats: Option<ApiMixStats>,
    reference: Option<ApiReferenceProfile>,
) -> anyhow::Result<Option<MasteringPlan>> {
    match (master.mastering_enabled, stats, reference) {
        (true, Some(s), Some(r)) => Ok(Some(
            design_mastering(&to_engine_stats(s), &to_engine_profile(r))
                .context("design mastering preview")?,
        )),
        _ => Ok(None),
    }
}

/// One event of the mix-analysis stream: progress ticks, final event
/// (progress == 1.0) carries the stats.
pub struct MixStatsEvent {
    pub progress: f32,
    pub stats: Option<ApiMixStats>,
}

/// Analyze the current mix (same trim/fades as an export) for the mastering
/// preview. Reads the whole recording once; streams progress.
pub fn analyze_mix_mastering(
    path: String,
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
    fd: Option<i32>,
    events: StreamSink<MixStatsEvent>,
) -> anyhow::Result<()> {
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let settings = to_engine_settings(&master);
    let stats =
        render::analyze_mix_mastering(&input_handle(&path, fd), &engine_tracks, &settings, |p| {
            if p < 1.0 {
                let _ = events.add(MixStatsEvent {
                    progress: p,
                    stats: None,
                });
            }
        })
        .with_context(|| format!("analyze mix of {path}"))?;
    let _ = events.add(MixStatsEvent {
        progress: 1.0,
        stats: Some(from_engine_stats(stats)),
    });
    Ok(())
}

/// One event of the reference-analysis stream: progress ticks while
/// decoding, and the final event (progress == 1.0) carries the profile.
pub struct ReferenceEvent {
    pub progress: f32,
    pub profile: Option<ApiReferenceProfile>,
}

/// Decode and analyze a reference track (WAV/FLAC/MP3/OGG) into a profile.
/// Streams progress like `render_mix`.
pub fn analyze_reference(
    path: String,
    fd: Option<i32>,
    events: StreamSink<ReferenceEvent>,
) -> anyhow::Result<()> {
    let profile = reference::analyze_reference(&input_handle(&path, fd), |p| {
        if p < 1.0 {
            let _ = events.add(ReferenceEvent {
                progress: p,
                profile: None,
            });
        }
    })
    .with_context(|| format!("analyze reference {path}"))?;
    let _ = events.add(ReferenceEvent {
        progress: 1.0,
        profile: Some(from_engine_profile(profile)),
    });
    Ok(())
}

// ── waveform analysis ───────────────────────────────────────────────────────

pub struct ApiChannelWaveform {
    pub min: Vec<f32>,
    pub max: Vec<f32>,
    pub peak_dbfs: f32,
}

pub struct ApiAnalysis {
    pub waveforms: Vec<ApiChannelWaveform>,
    /// Detected tempo (whole BPM), `None` when no clear beat.
    pub bpm: Option<f64>,
}

/// Streamed min/max envelope of every channel (`buckets` values per channel)
/// plus BPM detection, in one pass.
pub fn analyze_recording(
    path: String,
    buckets: usize,
    fd: Option<i32>,
) -> anyhow::Result<ApiAnalysis> {
    let analysis = analysis::analyze_input(&input_handle(&path, fd), buckets)
        .with_context(|| format!("analyze {path}"))?;
    Ok(ApiAnalysis {
        waveforms: analysis
            .waveforms
            .into_iter()
            .map(|w| ApiChannelWaveform {
                min: w.min,
                max: w.max,
                peak_dbfs: w.peak_dbfs,
            })
            .collect(),
        bpm: analysis.bpm,
    })
}

fn to_api_analysis(a: analysis::Analysis) -> ApiAnalysis {
    ApiAnalysis {
        waveforms: a
            .waveforms
            .into_iter()
            .map(|w| ApiChannelWaveform {
                min: w.min,
                max: w.max,
                peak_dbfs: w.peak_dbfs,
            })
            .collect(),
        bpm: a.bpm,
    }
}

// ── streamed analysis for platforms without a filesystem (web) ──────────────
//
// The browser cannot hand Rust a file, only byte ranges, so the analyzer
// lives across calls here and Dart pushes the `data` payload block by block
// (docs/PLAN-PWA.md S2b). Keyed by id rather than an FRB opaque type to keep
// the same shape as the player slot above.

static ANALYZERS: OnceLock<Mutex<HashMap<u32, analysis::StreamAnalyzer>>> = OnceLock::new();
static NEXT_ANALYZER_ID: OnceLock<Mutex<u32>> = OnceLock::new();

fn analyzers() -> &'static Mutex<HashMap<u32, analysis::StreamAnalyzer>> {
    ANALYZERS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Start a streamed analysis. `fmt_chunk` and `data_bytes` come from
/// [`scan_wav_chunks`]; the returned id addresses this analyzer until
/// [`stream_analysis_finish`] or [`stream_analysis_cancel`].
pub fn stream_analysis_begin(
    fmt_chunk: Vec<u8>,
    data_bytes: u64,
    buckets: usize,
) -> anyhow::Result<u32> {
    let spec = wav::spec_from_fmt_chunk(&fmt_chunk).context("parse fmt chunk")?;
    let num_frames = data_bytes / spec.bytes_per_frame() as u64;
    let mut counter = NEXT_ANALYZER_ID
        .get_or_init(|| Mutex::new(0))
        .lock()
        .unwrap();
    *counter = counter.wrapping_add(1);
    let id = *counter;
    analyzers()
        .lock()
        .unwrap()
        .insert(id, analysis::StreamAnalyzer::new(spec, num_frames, buckets));
    Ok(id)
}

/// Feed the next slice of the `data` payload, in file order. Slices may end
/// mid-frame; the analyzer carries the remainder.
pub fn stream_analysis_push(id: u32, bytes: Vec<u8>) -> anyhow::Result<()> {
    let mut map = analyzers().lock().unwrap();
    let analyzer = map
        .get_mut(&id)
        .ok_or_else(|| anyhow::anyhow!("no streamed analysis with id {id}"))?;
    analyzer.push_bytes(&bytes).context("push audio block")
}

/// Finish the analysis and drop the analyzer.
pub fn stream_analysis_finish(id: u32) -> anyhow::Result<ApiAnalysis> {
    let analyzer = analyzers()
        .lock()
        .unwrap()
        .remove(&id)
        .ok_or_else(|| anyhow::anyhow!("no streamed analysis with id {id}"))?;
    Ok(to_api_analysis(analyzer.finish()))
}

/// Drop an analyzer without a result (user switched takes mid-scan).
pub fn stream_analysis_cancel(id: u32) {
    analyzers().lock().unwrap().remove(&id);
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
    fd: Option<i32>,
    mastering_stats: Option<ApiMixStats>,
    reference: Option<ApiReferenceProfile>,
) -> anyhow::Result<()> {
    #[cfg(target_family = "wasm")]
    {
        let _ = (
            path,
            tracks,
            master,
            start_frame,
            fd,
            mastering_stats,
            reference,
        );
        anyhow::bail!("live playback is not available in the web build yet (PLAN-PWA S4)");
    }
    #[cfg(not(target_family = "wasm"))]
    {
        let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
        let plan = preview_plan(&master, mastering_stats, reference)?;
        let new_player = Player::start_input(
            &input_handle(&path, fd),
            engine_tracks,
            to_master_params(&master),
            plan,
            start_frame,
        )
        .with_context(|| format!("start playback of {path}"))?;
        let mut slot = player_slot().lock().unwrap();
        if let Some(old) = slot.take() {
            old.stop();
        }
        *slot = Some(new_player);
        Ok(())
    }
}

pub fn player_stop() {
    #[cfg(not(target_family = "wasm"))]
    {
        let mut slot = player_slot().lock().unwrap();
        if let Some(p) = slot.take() {
            p.stop();
        }
    }
}

pub fn player_seek(frame: u64) {
    let _ = frame;
    #[cfg(not(target_family = "wasm"))]
    if let Some(p) = player_slot().lock().unwrap().as_ref() {
        p.seek(frame);
    }
}

/// Push updated mix/master parameters to the running player (~0.2 s).
pub fn player_update_params(
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
    mastering_stats: Option<ApiMixStats>,
    reference: Option<ApiReferenceProfile>,
) -> anyhow::Result<()> {
    let plan = preview_plan(&master, mastering_stats, reference)?;
    #[cfg(target_family = "wasm")]
    let _ = (tracks, plan);
    #[cfg(not(target_family = "wasm"))]
    if let Some(p) = player_slot().lock().unwrap().as_ref() {
        p.update_params(
            tracks.iter().map(to_engine_track).collect(),
            to_master_params(&master),
            plan,
        );
    }
    Ok(())
}

/// Poll playback position and meters (call at UI frame rate).
#[flutter_rust_bridge::frb(sync)]
pub fn player_state() -> ApiPlayerState {
    #[cfg(target_family = "wasm")]
    {
        idle_player_state()
    }
    #[cfg(not(target_family = "wasm"))]
    {
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
            None => idle_player_state(),
        }
    }
}

/// The "nothing is playing" snapshot — shared by the native idle case and
/// the whole wasm build (no playback until PLAN-PWA S4).
fn idle_player_state() -> ApiPlayerState {
    ApiPlayerState {
        playing: false,
        position_frames: 0,
        peak_l: 0.0,
        peak_r: 0.0,
        lufs_momentary: -70.0,
        lufs_integrated: -70.0,
        true_peak: 0.0,
        correlation: 0.0,
    }
}

// ── streamed render (no filesystem) ─────────────────────────────────────────
//
// The browser cannot hand the engine a seekable file, so Dart drives the two
// render passes itself and collects the encoded output block by block
// (docs/PLAN-PWA.md S3). Same registry shape as the analyzers above.

static RENDERERS: OnceLock<Mutex<HashMap<u32, render::StreamRender>>> = OnceLock::new();
static NEXT_RENDERER_ID: OnceLock<Mutex<u32>> = OnceLock::new();

fn renderers() -> &'static Mutex<HashMap<u32, render::StreamRender>> {
    RENDERERS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_renderer<T>(
    id: u32,
    f: impl FnOnce(&mut render::StreamRender) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let mut map = renderers().lock().unwrap();
    let renderer = map
        .get_mut(&id)
        .ok_or_else(|| anyhow::anyhow!("no streamed render with id {id}"))?;
    f(renderer)
}

/// The finished render's fixed parts: `head ++ every block from
/// [`render_stream_pass2_push`] ++ `tail` is the complete file.
pub struct ApiRenderTail {
    pub head: Vec<u8>,
    pub tail: Vec<u8>,
    pub report: ApiRenderReport,
}

/// Begin a streamed render. `fmt_chunk` comes from [`scan_wav_chunks`];
/// `range_frames` is the length of the range Dart will push (trim applied on
/// its side, since it decides which bytes to read).
pub fn render_stream_begin(
    fmt_chunk: Vec<u8>,
    range_frames: u64,
    tracks: Vec<ApiTrack>,
    master: ApiMaster,
    reference: Option<ApiReferenceProfile>,
) -> anyhow::Result<u32> {
    let spec = wav::spec_from_fmt_chunk(&fmt_chunk).context("parse fmt chunk")?;
    let engine_tracks: Vec<TrackParams> = tracks.iter().map(to_engine_track).collect();
    let settings = to_engine_settings(&master);
    let profile = match (&master.mastering_enabled, reference) {
        (true, Some(p)) => Some(to_engine_profile(p)),
        _ => None,
    };
    let renderer = render::StreamRender::new(
        spec,
        range_frames,
        engine_tracks,
        settings,
        profile,
    )?;
    let mut counter = NEXT_RENDERER_ID
        .get_or_init(|| Mutex::new(0))
        .lock()
        .unwrap();
    *counter = counter.wrapping_add(1);
    let id = *counter;
    renderers().lock().unwrap().insert(id, renderer);
    Ok(id)
}

/// Feed the next slice of the `data` payload to pass 1 (measurement).
pub fn render_stream_pass1_push(id: u32, bytes: Vec<u8>) -> anyhow::Result<()> {
    with_renderer(id, |r| r.push_pass1(&bytes).context("render pass 1"))
}

/// Close pass 1 and open the encoder. Dart then replays the same byte range.
pub fn render_stream_start_pass2(id: u32) -> anyhow::Result<()> {
    with_renderer(id, |r| r.start_pass2().context("start render pass 2"))
}

/// Feed the next slice to pass 2 and take the encoded bytes it produced.
pub fn render_stream_pass2_push(id: u32, bytes: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    with_renderer(id, |r| r.push_pass2(&bytes).context("render pass 2"))
}

/// Finish the render and drop it.
pub fn render_stream_finish(id: u32) -> anyhow::Result<ApiRenderTail> {
    let renderer = renderers()
        .lock()
        .unwrap()
        .remove(&id)
        .ok_or_else(|| anyhow::anyhow!("no streamed render with id {id}"))?;
    let out = renderer.finish()?;
    Ok(ApiRenderTail {
        head: out.head,
        tail: out.tail,
        report: ApiRenderReport {
            peak_dbfs_before: out.report.peak_dbfs_before,
            gain_applied_db: out.report.gain_applied_db,
            duration_seconds: out.report.duration_seconds,
            sample_rate: out.report.sample_rate,
            integrated_lufs: out.report.integrated_lufs,
            true_peak_dbtp: out.report.true_peak_dbtp,
            lra_lu: out.report.lra_lu,
            source_integrated_lufs: out.report.source_integrated_lufs,
            mastering_applied: out.report.mastering_applied,
            mastering_gain_db: out.report.mastering_gain_db,
        },
    })
}

/// Drop a render that the user cancelled or that failed mid-way.
pub fn render_stream_cancel(id: u32) {
    renderers().lock().unwrap().remove(&id);
}
