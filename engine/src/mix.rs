//! Multichannel → stereo mix bus.

use serde::{Deserialize, Serialize};

use crate::dsp::{db_to_linear, pan_gains, GAIN_FLOOR_DB};

/// HPF slope: one or two cascaded 2nd-order Butterworth sections.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum HpfSlope {
    #[default]
    Db12,
    Db24,
}

/// One parametric EQ band (peak or shelf depending on its slot).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct EqBand {
    pub enabled: bool,
    pub freq: f64,
    pub gain_db: f64,
    pub q: f64,
}

impl EqBand {
    fn off(freq: f64, q: f64) -> Self {
        Self {
            enabled: false,
            freq,
            gain_db: 0.0,
            q,
        }
    }
}

/// Per-track high-pass filter + 3-band EQ (low shelf, mid peak, high shelf).
/// Everything defaults to bypassed, so pre-M3 sessions load unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackEq {
    pub hpf_enabled: bool,
    pub hpf_freq: f64,
    pub hpf_slope: HpfSlope,
    pub low: EqBand,
    pub mid: EqBand,
    pub high: EqBand,
}

impl Default for TrackEq {
    fn default() -> Self {
        Self {
            hpf_enabled: false,
            hpf_freq: 80.0,
            hpf_slope: HpfSlope::Db12,
            low: EqBand::off(120.0, std::f64::consts::FRAC_1_SQRT_2),
            mid: EqBand::off(1000.0, 1.0),
            high: EqBand::off(8000.0, std::f64::consts::FRAC_1_SQRT_2),
        }
    }
}

impl TrackEq {
    /// True when any stage would touch the signal.
    pub fn is_active(&self) -> bool {
        self.hpf_enabled || self.low.enabled || self.mid.enabled || self.high.enabled
    }
}

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
    /// HPF + 3-band EQ; defaults to bypassed (absent in v1 session files).
    #[serde(default)]
    pub eq: TrackEq,
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
            eq: TrackEq::default(),
        }
    }
}

/// Pre-resolved stereo coefficients for one source channel.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ChannelCoeff {
    /// 0-based interleave position in the source file.
    pub(crate) channel: usize,
    pub(crate) left: f64,
    pub(crate) right: f64,
    /// Position of the originating track in the `tracks` slice.
    pub(crate) track_pos: usize,
}

/// Resolve solo/mute/in-mix plus gain/pan/polarity into flat per-channel
/// stereo coefficients — the single source of truth for which channels are
/// audible, shared by [`MixBus`] and [`crate::chain::MixChain`].
pub(crate) fn resolve_channels(tracks: &[TrackParams], num_channels: usize) -> Vec<ChannelCoeff> {
    let any_solo = tracks.iter().any(|t| t.solo);
    let mut coeffs = Vec::new();
    for (track_pos, t) in tracks.iter().enumerate() {
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
            track_pos,
        });
    }
    coeffs
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
        Self {
            coeffs: resolve_channels(tracks, num_channels),
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
