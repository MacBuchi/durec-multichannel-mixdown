//! Streaming waveform analysis: per-channel min/max buckets for UI display.

use std::path::Path;

use crate::error::Result;
use crate::render::BLOCK_FRAMES;
use crate::wav::WavReader;

/// Min/max envelope of one channel, `buckets` values each, plus the channel's
/// sample peak in dBFS (−infinity for silent channels is clamped to −120).
#[derive(Debug, Clone, PartialEq)]
pub struct ChannelWaveform {
    pub min: Vec<f32>,
    pub max: Vec<f32>,
    pub peak_dbfs: f32,
}

/// Compute min/max waveform envelopes for every channel in one streamed pass.
pub fn analyze_waveforms<P: AsRef<Path>>(path: P, buckets: usize) -> Result<Vec<ChannelWaveform>> {
    let mut reader = WavReader::open(path)?;
    let channels = reader.spec().channels as usize;
    let num_frames = reader.num_frames().max(1);
    let frames_per_bucket = num_frames.div_ceil(buckets as u64).max(1);

    let mut mins = vec![vec![0.0f32; buckets]; channels];
    let mut maxs = vec![vec![0.0f32; buckets]; channels];
    let mut peaks = vec![0.0f32; channels];

    let mut input = Vec::new();
    let mut frame_index: u64 = 0;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        for (f, frame) in input.chunks_exact(channels).enumerate() {
            let bucket = (((frame_index + f as u64) / frames_per_bucket) as usize).min(buckets - 1);
            for (ch, &s) in frame.iter().enumerate() {
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
        }
        frame_index += n as u64;
    }

    Ok((0..channels)
        .map(|ch| ChannelWaveform {
            min: std::mem::take(&mut mins[ch]),
            max: std::mem::take(&mut maxs[ch]),
            peak_dbfs: if peaks[ch] > 0.0 {
                (20.0 * peaks[ch].log10()).max(-120.0)
            } else {
                -120.0
            },
        })
        .collect())
}
