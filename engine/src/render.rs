//! Two-pass offline render: analysis pass (peak + loudness measurement)
//! followed by a streamed render pass through gain → true-peak limiter →
//! quantise (+ TPDF dither on 16-bit). Files are never loaded into memory,
//! so multi-GB DUREC recordings work on mobile devices.

use std::io::{Read, Seek};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::chain::{ChainConfig, MixChain};
use crate::dsp::dither::TpdfDither;
use crate::dsp::limiter::{LimiterParams, TruePeakLimiter};
use crate::dsp::linear_to_db;
use crate::error::{EngineError, Result};
use crate::mix::{MixBus, TrackParams};
use crate::sink::StereoSink;
use crate::wav::WavReader;

/// Frames per streamed block (~1.4 s at 48 kHz, ~16 MB for 32 channels f64).
pub const BLOCK_FRAMES: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum LoudnessMode {
    /// No normalisation. If the limiter is also disabled, gain is still
    /// reduced when the mix would clip; with the limiter on, overs are its job.
    None,
    /// Normalise the mix so its sample peak hits the given dBFS value.
    PeakDbfs(f64),
    /// Normalise integrated loudness (EBU R128) to the given LUFS value;
    /// the true-peak limiter catches whatever the gain pushes over the top.
    LufsIntegrated(f64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OutputFormat {
    Wav16,
    Wav24,
    Wav32Float,
    Flac16,
    Flac24,
    /// MP3, CBR 320 kbps (LAME) — parity with the Python tool's exports.
    Mp3,
}

impl OutputFormat {
    pub fn extension(&self) -> &'static str {
        match self {
            OutputFormat::Flac16 | OutputFormat::Flac24 => "flac",
            OutputFormat::Mp3 => "mp3",
            _ => "wav",
        }
    }

    /// Whether TPDF dither applies (16-bit integer quantisation).
    pub fn is_16_bit_int(&self) -> bool {
        matches!(self, OutputFormat::Wav16 | OutputFormat::Flac16)
    }
}

fn default_limiter_enabled() -> bool {
    true
}
fn default_ceiling_dbtp() -> f64 {
    -1.0
}
fn default_dither() -> bool {
    true
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RenderSettings {
    pub loudness: LoudnessMode,
    pub format: OutputFormat,
    /// Master true-peak limiter (defaults on; serde defaults keep v1
    /// sessions loadable).
    #[serde(default = "default_limiter_enabled")]
    pub limiter_enabled: bool,
    /// Limiter ceiling in dBTP.
    #[serde(default = "default_ceiling_dbtp")]
    pub ceiling_dbtp: f64,
    /// TPDF dither on word-length reduction (only acts on 16-bit output).
    #[serde(default = "default_dither")]
    pub dither: bool,
}

impl Default for RenderSettings {
    fn default() -> Self {
        Self {
            loudness: LoudnessMode::PeakDbfs(-1.0),
            format: OutputFormat::Wav24,
            limiter_enabled: default_limiter_enabled(),
            ceiling_dbtp: default_ceiling_dbtp(),
            dither: default_dither(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderReport {
    /// Sample peak of the raw (pre-normalisation) mix, in dBFS.
    pub peak_dbfs_before: f64,
    /// Gain applied by the normalisation stage, in dB.
    pub gain_applied_db: f64,
    pub duration_seconds: f64,
    pub sample_rate: u32,
    /// Integrated loudness of the delivered file (post-limiter), LUFS.
    pub integrated_lufs: f64,
    /// True peak of the delivered file (post-limiter), dBTP.
    pub true_peak_dbtp: f64,
    /// Loudness range of the delivered file, LU.
    pub lra_lu: f64,
    /// Integrated loudness of the source mix (pre-gain), LUFS.
    pub source_integrated_lufs: f64,
}

/// Measure the sample peak of the mixed output without writing anything.
pub fn measure_mix_peak<R: Read + Seek>(reader: &mut WavReader<R>, bus: &MixBus) -> Result<f64> {
    reader.seek_to_frame(0)?;
    let mut input = Vec::new();
    let mut stereo = Vec::new();
    let mut peak = 0.0f64;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        bus.process(&input, &mut stereo);
        for &s in &stereo {
            peak = peak.max(s.abs());
        }
    }
    Ok(peak)
}

/// Render the mix of `input_path` to a stereo file at `out_path` in the
/// format given by `settings.format` (WAV, FLAC or MP3).
///
/// `progress` receives values in 0.0..=1.0 across both passes.
pub fn render_to_file<P: AsRef<Path>>(
    input_path: P,
    tracks: &[TrackParams],
    settings: &RenderSettings,
    out_path: P,
    mut progress: impl FnMut(f32),
) -> Result<RenderReport> {
    let mut reader = WavReader::open(&input_path)?;
    let spec = reader.spec();
    let cfg = ChainConfig {
        sample_rate: spec.sample_rate,
    };
    let total_frames = reader.num_frames().max(1) as f64;

    // Pass 1: measure raw mix peak and integrated loudness. Fresh chain —
    // filter state must not leak into pass 2.
    let mut chain = MixChain::new(tracks, spec.channels as usize, &cfg);
    let mut ebu_src = ebur128::EbuR128::new(2, spec.sample_rate, ebur128::Mode::I)
        .map_err(|e| EngineError::Encode(format!("ebur128: {e}")))?;
    reader.seek_to_frame(0)?;
    let mut input = Vec::new();
    let mut stereo = Vec::new();
    let mut peak = 0.0f64;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        chain.process(&input, &mut stereo);
        for &s in &stereo {
            peak = peak.max(s.abs());
        }
        let _ = ebu_src.add_frames_f64(&stereo);
        progress((reader.pos_frames() as f64 / total_frames * 0.5) as f32);
    }
    let source_lufs = ebu_src.loudness_global().unwrap_or(f64::NEG_INFINITY);

    let norm_gain = match settings.loudness {
        LoudnessMode::PeakDbfs(target_db) => {
            if peak > 0.0 {
                10f64.powf(target_db / 20.0) / peak
            } else {
                1.0
            }
        }
        LoudnessMode::LufsIntegrated(target_lufs) => {
            if source_lufs.is_finite() {
                10f64.powf((target_lufs - source_lufs) / 20.0)
            } else {
                1.0
            }
        }
        LoudnessMode::None => {
            // Clip protection is the limiter's job when it is enabled.
            if !settings.limiter_enabled && peak > 1.0 {
                1.0 / peak
            } else {
                1.0
            }
        }
    };

    // Pass 2: mix → normalisation gain → limiter → measure → encode.
    let mut sink = StereoSink::create(out_path.as_ref(), settings.format, spec.sample_rate)?;
    let mut chain = MixChain::new(tracks, spec.channels as usize, &cfg);
    let mut limiter = settings.limiter_enabled.then(|| {
        TruePeakLimiter::new(
            LimiterParams {
                ceiling_dbtp: settings.ceiling_dbtp,
                ..LimiterParams::default()
            },
            spec.sample_rate,
        )
    });
    let mut ebu_out = ebur128::EbuR128::new(
        2,
        spec.sample_rate,
        ebur128::Mode::I | ebur128::Mode::LRA | ebur128::Mode::TRUE_PEAK,
    )
    .map_err(|e| EngineError::Encode(format!("ebur128: {e}")))?;
    let mut dither = (settings.dither && settings.format.is_16_bit_int()).then(TpdfDither::default);
    let mut limited = Vec::new();
    reader.seek_to_frame(0)?;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        chain.process(&input, &mut stereo);
        for s in &mut stereo {
            *s *= norm_gain;
        }
        let block: &[f64] = match &mut limiter {
            Some(lim) => {
                limited.clear();
                lim.process(&stereo, &mut limited);
                &limited
            }
            None => &stereo,
        };
        let _ = ebu_out.add_frames_f64(block);
        sink.write_block(block, dither.as_mut())?;
        progress((0.5 + reader.pos_frames() as f64 / total_frames * 0.5) as f32);
    }
    if let Some(lim) = &mut limiter {
        limited.clear();
        lim.flush(&mut limited);
        let _ = ebu_out.add_frames_f64(&limited);
        sink.write_block(&limited, dither.as_mut())?;
    }
    sink.finalize()?;
    progress(1.0);

    let true_peak = ebu_out
        .true_peak(0)
        .and_then(|l| ebu_out.true_peak(1).map(|r| l.max(r)))
        .unwrap_or(0.0);
    Ok(RenderReport {
        peak_dbfs_before: linear_to_db(peak),
        gain_applied_db: linear_to_db(norm_gain),
        duration_seconds: total_frames / spec.sample_rate as f64,
        sample_rate: spec.sample_rate,
        integrated_lufs: ebu_out.loudness_global().unwrap_or(f64::NEG_INFINITY),
        true_peak_dbtp: linear_to_db(true_peak),
        lra_lu: ebu_out.loudness_range().unwrap_or(0.0),
        source_integrated_lufs: source_lufs,
    })
}
