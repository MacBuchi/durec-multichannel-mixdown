//! Multichannel → stereo mix bus.

use serde::{Deserialize, Serialize};

use crate::dsp::{db_to_linear, pan_gains, GAIN_FLOOR_DB};

/// Per-track mix parameters. `index` is the 1-based interleave index of the
/// channel inside the source WAV.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackParams {
    pub index: u32,
    pub name: String,
    /// Fader gain in dB (−60 .. +6). At or below −60 dB the track is silent.
    pub gain_db: f64,
    /// Pan position −1.0 (L) .. +1.0 (R); constant-power law.
    pub pan: f64,
    /// Polarity (ø) invert.
    pub polarity_invert: bool,
    pub muted: bool,
    pub solo: bool,
    /// Include this track in the mixdown (parity with the old "Mix" checkbox).
    pub in_mix: bool,
}

impl TrackParams {
    pub fn new(index: u32, name: impl Into<String>, pan: f64) -> Self {
        Self {
            index,
            name: name.into(),
            gain_db: 0.0,
            pan,
            polarity_invert: false,
            muted: false,
            solo: false,
            in_mix: true,
        }
    }
}

/// Pre-resolved stereo coefficients for one source channel.
#[derive(Debug, Clone, Copy)]
struct ChannelCoeff {
    channel: usize, // 0-based interleave position
    left: f64,
    right: f64,
}

/// A fixed snapshot of the mix graph: resolves solo/mute/in-mix logic and
/// per-track gain+pan+polarity into flat per-channel stereo coefficients.
/// Cheap to rebuild whenever a parameter changes.
#[derive(Debug, Clone)]
pub struct MixBus {
    coeffs: Vec<ChannelCoeff>,
    num_channels: usize,
}

impl MixBus {
    pub fn new(tracks: &[TrackParams], num_channels: usize) -> Self {
        let any_solo = tracks.iter().any(|t| t.solo);
        let mut coeffs = Vec::new();
        for t in tracks {
            if !t.in_mix || t.muted || (any_solo && !t.solo) {
                continue;
            }
            let ch = t.index as usize;
            if ch == 0 || ch > num_channels {
                continue;
            }
            let gain = db_to_linear(t.gain_db, GAIN_FLOOR_DB);
            if gain == 0.0 {
                continue;
            }
            let (pl, pr) = pan_gains(t.pan);
            let sign = if t.polarity_invert { -1.0 } else { 1.0 };
            coeffs.push(ChannelCoeff {
                channel: ch - 1,
                left: gain * pl * sign,
                right: gain * pr * sign,
            });
        }
        Self {
            coeffs,
            num_channels,
        }
    }

    pub fn is_silent(&self) -> bool {
        self.coeffs.is_empty()
    }

    /// Mix one block of interleaved multichannel input into interleaved
    /// stereo. `input.len()` must be a multiple of the channel count.
    /// `out` is cleared and refilled with `2 * num_frames` samples.
    pub fn process(&self, input: &[f64], out: &mut Vec<f64>) {
        let n_ch = self.num_channels;
        debug_assert_eq!(input.len() % n_ch, 0);
        let frames = input.len() / n_ch;
        out.clear();
        out.resize(frames * 2, 0.0);
        for c in &self.coeffs {
            for (f, frame) in input.chunks_exact(n_ch).enumerate() {
                let s = frame[c.channel];
                out[2 * f] += s * c.left;
                out[2 * f + 1] += s * c.right;
            }
        }
    }
}
