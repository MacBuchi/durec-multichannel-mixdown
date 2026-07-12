//! Two-pass offline render: analysis pass (peak measurement) followed by a
//! streamed render pass. Files are never loaded into memory, so multi-GB
//! DUREC recordings work on mobile devices.
//!
//! M1 scope: peak normalisation + WAV output. LUFS targets, true-peak
//! limiting, dither and FLAC/MP3 arrive in M3.

use std::io::{Read, Seek};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::chain::{ChainConfig, MixChain};
use crate::dsp::linear_to_db;
use crate::error::{EngineError, Result};
use crate::mix::{MixBus, TrackParams};
use crate::wav::WavReader;

/// Frames per streamed block (~1.4 s at 48 kHz, ~16 MB for 32 channels f64).
pub const BLOCK_FRAMES: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum LoudnessMode {
    /// No normalisation; gain is only reduced if the mix would clip.
    None,
    /// Normalise the mix so its sample peak hits the given dBFS value.
    PeakDbfs(f64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OutputFormat {
    Wav16,
    Wav24,
    Wav32Float,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RenderSettings {
    pub loudness: LoudnessMode,
    pub format: OutputFormat,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderReport {
    /// Sample peak of the raw (pre-normalisation) mix, in dBFS.
    pub peak_dbfs_before: f64,
    /// Gain applied by the normalisation stage, in dB.
    pub gain_applied_db: f64,
    pub duration_seconds: f64,
    pub sample_rate: u32,
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

/// Render the mix of `input_path` to a stereo WAV at `out_path`.
///
/// `progress` receives values in 0.0..=1.0 across both passes.
pub fn render_to_wav<P: AsRef<Path>>(
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

    // Pass 1: measure the raw mix peak. Fresh chain — filter state must not
    // leak into pass 2.
    let mut chain = MixChain::new(tracks, spec.channels as usize, &cfg);
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
        progress((reader.pos_frames() as f64 / total_frames * 0.5) as f32);
    }

    let norm_gain = match settings.loudness {
        LoudnessMode::PeakDbfs(target_db) => {
            if peak > 0.0 {
                10f64.powf(target_db / 20.0) / peak
            } else {
                1.0
            }
        }
        LoudnessMode::None => {
            // Still protect against clipping.
            if peak > 1.0 {
                1.0 / peak
            } else {
                1.0
            }
        }
    };

    // Pass 2: render.
    let hound_spec = hound::WavSpec {
        channels: 2,
        sample_rate: spec.sample_rate,
        bits_per_sample: match settings.format {
            OutputFormat::Wav16 => 16,
            OutputFormat::Wav24 => 24,
            OutputFormat::Wav32Float => 32,
        },
        sample_format: match settings.format {
            OutputFormat::Wav32Float => hound::SampleFormat::Float,
            _ => hound::SampleFormat::Int,
        },
    };
    let mut writer = hound::WavWriter::create(&out_path, hound_spec)
        .map_err(|e| EngineError::Encode(e.to_string()))?;

    let mut chain = MixChain::new(tracks, spec.channels as usize, &cfg);
    reader.seek_to_frame(0)?;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        chain.process(&input, &mut stereo);
        write_block(&mut writer, &stereo, norm_gain, settings.format)?;
        progress((0.5 + reader.pos_frames() as f64 / total_frames * 0.5) as f32);
    }
    writer
        .finalize()
        .map_err(|e| EngineError::Encode(e.to_string()))?;
    progress(1.0);

    Ok(RenderReport {
        peak_dbfs_before: linear_to_db(peak),
        gain_applied_db: linear_to_db(norm_gain),
        duration_seconds: total_frames / spec.sample_rate as f64,
        sample_rate: spec.sample_rate,
    })
}

fn write_block<W: std::io::Write + Seek>(
    writer: &mut hound::WavWriter<W>,
    stereo: &[f64],
    gain: f64,
    format: OutputFormat,
) -> Result<()> {
    let enc = |e: hound::Error| EngineError::Encode(e.to_string());
    match format {
        OutputFormat::Wav16 => {
            for &s in stereo {
                let v = (s * gain).clamp(-1.0, 1.0);
                let q = (v * 32767.0).round() as i16;
                writer.write_sample(q).map_err(enc)?;
            }
        }
        OutputFormat::Wav24 => {
            for &s in stereo {
                let v = (s * gain).clamp(-1.0, 1.0);
                let q = (v * 8_388_607.0).round() as i32;
                writer.write_sample(q).map_err(enc)?;
            }
        }
        OutputFormat::Wav32Float => {
            for &s in stereo {
                writer.write_sample((s * gain) as f32).map_err(enc)?;
            }
        }
    }
    Ok(())
}
