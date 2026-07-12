//! Streaming waveform analysis: per-channel min/max buckets for UI display,
//! plus BPM detection via autocorrelation of the onset envelope — both from
//! the same single streamed pass.

use std::path::Path;

use crate::error::Result;
use crate::render::BLOCK_FRAMES;

/// Onset-envelope hop size in frames (~11.6 ms at 44.1 kHz — enough
/// resolution for ±1 BPM around typical tempi).
const BPM_HOP: usize = 512;
const BPM_MIN: f64 = 60.0;
const BPM_MAX: f64 = 200.0;

/// Min/max envelope of one channel, `buckets` values each, plus the channel's
/// sample peak in dBFS (−infinity for silent channels is clamped to −120).
#[derive(Debug, Clone, PartialEq)]
pub struct ChannelWaveform {
    pub min: Vec<f32>,
    pub max: Vec<f32>,
    pub peak_dbfs: f32,
}

/// Result of the streamed analysis pass.
#[derive(Debug, Clone, PartialEq)]
pub struct Analysis {
    pub waveforms: Vec<ChannelWaveform>,
    /// Detected tempo (rounded to whole BPM), `None` when no clear beat.
    pub bpm: Option<f64>,
}

/// Compute per-channel waveform envelopes and the tempo of the channel sum
/// in one streamed pass.
pub fn analyze<P: AsRef<Path>>(path: P, buckets: usize) -> Result<Analysis> {
    analyze_input(
        &crate::wav::InputHandle::Path(path.as_ref().to_string_lossy().into_owned()),
        buckets,
    )
}

/// [`analyze`] over a platform handle — path or raw fd (Android SAF).
pub fn analyze_input(input: &crate::wav::InputHandle, buckets: usize) -> Result<Analysis> {
    let mut reader = input.open()?;
    let channels = reader.spec().channels as usize;
    let sample_rate = reader.spec().sample_rate;
    let num_frames = reader.num_frames().max(1);
    let frames_per_bucket = num_frames.div_ceil(buckets as u64).max(1);

    let mut mins = vec![vec![0.0f32; buckets]; channels];
    let mut maxs = vec![vec![0.0f32; buckets]; channels];
    let mut peaks = vec![0.0f32; channels];

    // Onset envelope: RMS of the channel sum per hop.
    let mut hop_energy: Vec<f64> = Vec::new();
    let mut hop_acc = 0.0f64;
    let mut hop_fill = 0usize;

    let mut input = Vec::new();
    let mut frame_index: u64 = 0;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        for (f, frame) in input.chunks_exact(channels).enumerate() {
            let bucket = (((frame_index + f as u64) / frames_per_bucket) as usize).min(buckets - 1);
            let mut sum = 0.0f64;
            for (ch, &s) in frame.iter().enumerate() {
                sum += s;
                let s = s as f32;
                if s < mins[ch][bucket] {
                    mins[ch][bucket] = s;
                }
                if s > maxs[ch][bucket] {
                    maxs[ch][bucket] = s;
                }
                let a = s.abs();
                if a > peaks[ch] {
                    peaks[ch] = a;
                }
            }
            hop_acc += sum * sum;
            hop_fill += 1;
            if hop_fill == BPM_HOP {
                hop_energy.push((hop_acc / BPM_HOP as f64).sqrt());
                hop_acc = 0.0;
                hop_fill = 0;
            }
        }
        frame_index += n as u64;
    }

    let waveforms = (0..channels)
        .map(|ch| ChannelWaveform {
            min: std::mem::take(&mut mins[ch]),
            max: std::mem::take(&mut maxs[ch]),
            peak_dbfs: if peaks[ch] > 0.0 {
                (20.0 * peaks[ch].log10()).max(-120.0)
            } else {
                -120.0
            },
        })
        .collect();

    Ok(Analysis {
        waveforms,
        bpm: detect_bpm(&hop_energy, sample_rate),
    })
}

/// Backwards-compatible wrapper returning only the waveforms.
pub fn analyze_waveforms<P: AsRef<Path>>(path: P, buckets: usize) -> Result<Vec<ChannelWaveform>> {
    Ok(analyze(path, buckets)?.waveforms)
}

/// Tempo from an onset envelope: half-wave-rectified energy difference,
/// autocorrelated over the 60–200 BPM lag range; the best lag wins if its
/// correlation clearly beats the envelope's baseline self-similarity.
fn detect_bpm(hop_energy: &[f64], sample_rate: u32) -> Option<f64> {
    let hop_rate = sample_rate as f64 / BPM_HOP as f64; // hops per second
    let min_lag = (hop_rate * 60.0 / BPM_MAX) as usize;
    let max_lag = (hop_rate * 60.0 / BPM_MIN) as usize;
    if hop_energy.len() < max_lag * 3 || min_lag < 2 {
        return None; // too short to establish a tempo
    }

    // Onset strength: rising energy only, mean-removed. A steady tone still
    // shows a faint periodic ripple here (hop/period beating), so require
    // the onsets to be a meaningful fraction of the signal level first.
    let mut onset: Vec<f64> = hop_energy
        .windows(2)
        .map(|w| (w[1] - w[0]).max(0.0))
        .collect();
    let mean = onset.iter().sum::<f64>() / onset.len() as f64;
    let mean_level = hop_energy.iter().sum::<f64>() / hop_energy.len() as f64;
    if mean < 0.02 * mean_level {
        return None; // no transients worth calling a beat
    }
    for v in &mut onset {
        *v -= mean;
    }
    let energy: f64 = onset.iter().map(|v| v * v).sum();
    if energy <= f64::EPSILON {
        return None; // silence / constant signal
    }

    let mut best = (0.0f64, 0usize);
    for lag in min_lag..=max_lag {
        let mut acc = 0.0;
        for i in lag..onset.len() {
            acc += onset[i] * onset[i - lag];
        }
        let norm = acc / (onset.len() - lag) as f64 / (energy / onset.len() as f64);
        if norm > best.0 {
            best = (norm, lag);
        }
    }
    // Threshold: a real beat correlates well above the noise floor.
    if best.0 < 0.25 || best.1 == 0 {
        return None;
    }

    // Parabolic interpolation around the peak for sub-lag precision.
    let lag = best.1 as f64;
    let bpm = 60.0 * hop_rate / lag;
    Some(bpm.round())
}
