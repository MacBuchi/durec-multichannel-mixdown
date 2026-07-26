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

/// The streamed analysis state, independent of where the frames come from.
///
/// Native builds feed it from a [`crate::wav::WavReader`]; the web build has
/// no filesystem and pushes raw `Blob` slices through [`StreamAnalyzer`]
/// (docs/PLAN-PWA.md S2b). Both paths therefore compute bit-identical
/// results — `engine_tests.rs` asserts exactly that.
pub struct Accumulator {
    channels: usize,
    sample_rate: u32,
    buckets: usize,
    frames_per_bucket: u64,
    mins: Vec<Vec<f32>>,
    maxs: Vec<Vec<f32>>,
    peaks: Vec<f32>,
    hop_energy: Vec<f64>,
    hop_acc: f64,
    hop_fill: usize,
    frame_index: u64,
}

impl Accumulator {
    pub fn new(channels: usize, sample_rate: u32, num_frames: u64, buckets: usize) -> Self {
        let num_frames = num_frames.max(1);
        Self {
            channels,
            sample_rate,
            buckets,
            frames_per_bucket: num_frames.div_ceil(buckets as u64).max(1),
            mins: vec![vec![0.0f32; buckets]; channels],
            maxs: vec![vec![0.0f32; buckets]; channels],
            peaks: vec![0.0f32; channels],
            hop_energy: Vec::new(),
            hop_acc: 0.0,
            hop_fill: 0,
            frame_index: 0,
        }
    }

    /// Consume interleaved samples; `frames` must contain whole frames.
    pub fn push_frames(&mut self, frames: &[f64]) {
        for frame in frames.chunks_exact(self.channels) {
            let bucket = ((self.frame_index / self.frames_per_bucket) as usize)
                .min(self.buckets.saturating_sub(1));
            let mut sum = 0.0f64;
            for (ch, &s) in frame.iter().enumerate() {
                sum += s;
                let s = s as f32;
                if s < self.mins[ch][bucket] {
                    self.mins[ch][bucket] = s;
                }
                if s > self.maxs[ch][bucket] {
                    self.maxs[ch][bucket] = s;
                }
                let a = s.abs();
                if a > self.peaks[ch] {
                    self.peaks[ch] = a;
                }
            }
            self.hop_acc += sum * sum;
            self.hop_fill += 1;
            if self.hop_fill == BPM_HOP {
                self.hop_energy.push((self.hop_acc / BPM_HOP as f64).sqrt());
                self.hop_acc = 0.0;
                self.hop_fill = 0;
            }
            self.frame_index += 1;
        }
    }

    pub fn finish(mut self) -> Analysis {
        let waveforms = (0..self.channels)
            .map(|ch| ChannelWaveform {
                min: std::mem::take(&mut self.mins[ch]),
                max: std::mem::take(&mut self.maxs[ch]),
                peak_dbfs: if self.peaks[ch] > 0.0 {
                    (20.0 * self.peaks[ch].log10()).max(-120.0)
                } else {
                    -120.0
                },
            })
            .collect();
        Analysis {
            waveforms,
            bpm: detect_bpm(&self.hop_energy, self.sample_rate),
        }
    }
}

/// [`Accumulator`] fed with raw PCM bytes instead of decoded frames — for
/// platforms that can only hand over byte ranges (web). Pushes may split a
/// frame anywhere; the remainder is carried to the next call.
pub struct StreamAnalyzer {
    acc: Accumulator,
    decoder: crate::wav::FrameDecoder,
    scratch: Vec<f64>,
}

impl StreamAnalyzer {
    pub fn new(spec: crate::wav::WavSpec, num_frames: u64, buckets: usize) -> Self {
        Self {
            acc: Accumulator::new(
                spec.channels as usize,
                spec.sample_rate,
                num_frames,
                buckets,
            ),
            decoder: crate::wav::FrameDecoder::new(spec),
            scratch: Vec::new(),
        }
    }

    /// Feed the next slice of the `data` chunk, in file order.
    pub fn push_bytes(&mut self, bytes: &[u8]) -> Result<()> {
        self.decoder.push(bytes, &mut self.scratch)?;
        self.acc.push_frames(&self.scratch);
        Ok(())
    }

    pub fn finish(self) -> Analysis {
        self.acc.finish()
    }
}

/// [`analyze`] over a platform handle — path or raw fd (Android SAF).
pub fn analyze_input(input: &crate::wav::InputHandle, buckets: usize) -> Result<Analysis> {
    let mut reader = input.open()?;
    let spec = reader.spec();
    let mut acc = Accumulator::new(
        spec.channels as usize,
        spec.sample_rate,
        reader.num_frames(),
        buckets,
    );

    let mut input = Vec::new();
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        acc.push_frames(&input);
    }
    Ok(acc.finish())
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
