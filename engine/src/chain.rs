//! The shared mix chain: per-channel EQ → gain/pan/ø → stereo sum.
//!
//! One implementation runs everywhere so preview and export sound identical:
//! render pass 1 (measurement), render pass 2 (delivery) and the playback
//! decode thread. The chain is stateful (biquad state per channel); render
//! passes build a fresh chain each, playback keeps one alive and adopts the
//! old state on parameter changes so live EQ tweaks are click-free.
//!
//! Signal flow per active source channel:
//!
//! ```text
//! sample → HPF (×1..2) → low shelf → mid peak → high shelf → L/R coeffs ─┐
//!                                                             stereo sum ┴→ out
//! ```

use crate::dsp::biquad::{Biquad, BiquadCoeffs, BUTTERWORTH_2ND_Q, BUTTERWORTH_4TH_Q};
use crate::mix::{resolve_channels, HpfSlope, TrackEq, TrackParams};

/// Stateful EQ for one source channel. Fixed slots so state can be adopted
/// role-by-role when parameters change.
#[derive(Debug, Clone, Copy, Default)]
struct EqChain {
    hpf1: Option<Biquad>,
    hpf2: Option<Biquad>,
    low: Option<Biquad>,
    mid: Option<Biquad>,
    high: Option<Biquad>,
}

impl EqChain {
    fn new(eq: &TrackEq, sr: f64) -> Self {
        let mut chain = Self::default();
        if eq.hpf_enabled {
            match eq.hpf_slope {
                HpfSlope::Db12 => {
                    chain.hpf1 = Some(Biquad::new(BiquadCoeffs::highpass(
                        sr,
                        eq.hpf_freq,
                        BUTTERWORTH_2ND_Q,
                    )));
                }
                HpfSlope::Db24 => {
                    chain.hpf1 = Some(Biquad::new(BiquadCoeffs::highpass(
                        sr,
                        eq.hpf_freq,
                        BUTTERWORTH_4TH_Q[0],
                    )));
                    chain.hpf2 = Some(Biquad::new(BiquadCoeffs::highpass(
                        sr,
                        eq.hpf_freq,
                        BUTTERWORTH_4TH_Q[1],
                    )));
                }
            }
        }
        if eq.low.enabled {
            chain.low = Some(Biquad::new(BiquadCoeffs::low_shelf(
                sr,
                eq.low.freq,
                eq.low.gain_db,
                eq.low.q,
            )));
        }
        if eq.mid.enabled {
            chain.mid = Some(Biquad::new(BiquadCoeffs::peaking(
                sr,
                eq.mid.freq,
                eq.mid.gain_db,
                eq.mid.q,
            )));
        }
        if eq.high.enabled {
            chain.high = Some(Biquad::new(BiquadCoeffs::high_shelf(
                sr,
                eq.high.freq,
                eq.high.gain_db,
                eq.high.q,
            )));
        }
        chain
    }

    #[inline]
    fn process(&mut self, mut x: f64) -> f64 {
        if let Some(b) = &mut self.hpf1 {
            x = b.process(x);
        }
        if let Some(b) = &mut self.hpf2 {
            x = b.process(x);
        }
        if let Some(b) = &mut self.low {
            x = b.process(x);
        }
        if let Some(b) = &mut self.mid {
            x = b.process(x);
        }
        if let Some(b) = &mut self.high {
            x = b.process(x);
        }
        x
    }

    fn reset(&mut self) {
        for b in [
            &mut self.hpf1,
            &mut self.hpf2,
            &mut self.low,
            &mut self.mid,
            &mut self.high,
        ]
        .into_iter()
        .flatten()
        {
            b.reset();
        }
    }

    /// Keep the old filter state under the new coefficients (click-free live
    /// tweaking). Slots that were previously bypassed start from silence.
    fn adopt_state_from(&mut self, old: &EqChain) {
        for (new, prev) in [
            (&mut self.hpf1, &old.hpf1),
            (&mut self.hpf2, &old.hpf2),
            (&mut self.low, &old.low),
            (&mut self.mid, &old.mid),
            (&mut self.high, &old.high),
        ] {
            if let (Some(n), Some(p)) = (new, prev) {
                n.adopt_state(p);
            }
        }
    }
}

/// One active source channel: EQ plus resolved stereo coefficients.
#[derive(Debug, Clone)]
struct ChannelStrip {
    channel: usize, // 0-based interleave position
    left: f64,
    right: f64,
    eq: EqChain,
    has_eq: bool,
}

/// Master-stage configuration for a [`MixChain`].
#[derive(Debug, Clone, Copy)]
pub struct ChainConfig {
    pub sample_rate: u32,
}

/// The stateful mix chain shared by render and playback.
#[derive(Debug, Clone)]
pub struct MixChain {
    strips: Vec<ChannelStrip>,
    num_channels: usize,
}

impl MixChain {
    pub fn new(tracks: &[TrackParams], num_channels: usize, cfg: &ChainConfig) -> Self {
        let sr = cfg.sample_rate as f64;
        let strips = resolve_channels(tracks, num_channels)
            .into_iter()
            .map(|c| {
                let eq = &tracks[c.track_pos].eq;
                ChannelStrip {
                    channel: c.channel,
                    left: c.left,
                    right: c.right,
                    eq: EqChain::new(eq, sr),
                    has_eq: eq.is_active(),
                }
            })
            .collect();
        Self {
            strips,
            num_channels,
        }
    }

    pub fn is_silent(&self) -> bool {
        self.strips.is_empty()
    }

    /// Clear all filter state (after a seek).
    pub fn reset(&mut self) {
        for s in &mut self.strips {
            s.eq.reset();
        }
    }

    /// Carry filter state over from the previous chain when only parameters
    /// changed (matched by source channel), so live tweaks don't click.
    pub fn adopt_state_from(&mut self, old: &MixChain) {
        for s in &mut self.strips {
            if let Some(prev) = old.strips.iter().find(|p| p.channel == s.channel) {
                s.eq.adopt_state_from(&prev.eq);
            }
        }
    }

    /// Mix one block of interleaved multichannel input into interleaved
    /// stereo. `input.len()` must be a multiple of the channel count.
    /// `out` is cleared and refilled with `2 * num_frames` samples.
    pub fn process(&mut self, input: &[f64], out: &mut Vec<f64>) {
        let n_ch = self.num_channels;
        debug_assert_eq!(input.len() % n_ch, 0);
        let frames = input.len() / n_ch;
        out.clear();
        out.resize(frames * 2, 0.0);
        for strip in &mut self.strips {
            if strip.has_eq {
                for (f, frame) in input.chunks_exact(n_ch).enumerate() {
                    let s = strip.eq.process(frame[strip.channel]);
                    out[2 * f] += s * strip.left;
                    out[2 * f + 1] += s * strip.right;
                }
            } else {
                for (f, frame) in input.chunks_exact(n_ch).enumerate() {
                    let s = frame[strip.channel];
                    out[2 * f] += s * strip.left;
                    out[2 * f + 1] += s * strip.right;
                }
            }
        }
    }
}
