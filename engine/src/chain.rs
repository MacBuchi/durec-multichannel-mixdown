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

/// Master-bus parameters shared by playback and (via `RenderSettings`)
/// export, so preview and delivery run the same processing.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MasterParams {
    pub limiter_enabled: bool,
    pub ceiling_dbtp: f64,
}

impl Default for MasterParams {
    fn default() -> Self {
        Self {
            limiter_enabled: true,
            ceiling_dbtp: -1.0,
        }
    }
}

/// The stateful mix chain shared by render and playback.
#[derive(Debug, Clone)]
pub struct MixChain {
    strips: Vec<ChannelStrip>,
    num_channels: usize,
    /// Peak of each source channel in the block just processed, linear —
    /// **post-EQ and pre-fader**, which is what a console's pre-fader meter
    /// shows. The post-fader value follows exactly by multiplying with the
    /// track's gain, so only one measurement is ever taken (#115).
    ///
    /// Empty unless [`enable_metering`](Self::enable_metering) was called: the
    /// render has no meters and must not pay for them.
    peaks: Vec<f32>,
    metering: bool,
    /// Source channels with no strip at all. `resolve_channels` drops muted,
    /// soloed-away, out-of-mix and zero-gain tracks, so they are never
    /// processed — yet their meter has to keep showing signal (dimmed), which
    /// is the whole point of metering a muted track. These are read straight
    /// from the input, and therefore *without* their EQ.
    unstripped: Vec<usize>,
}

impl MixChain {
    pub fn new(tracks: &[TrackParams], num_channels: usize, cfg: &ChainConfig) -> Self {
        let sr = cfg.sample_rate as f64;
        let strips: Vec<ChannelStrip> = resolve_channels(tracks, num_channels)
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
        // Marked, not searched: `any()` per channel is O(channels × strips),
        // which at a 200-track multisample take is 40 000 comparisons on every
        // fader move. Channel counts come from the interface — 34 is this
        // user's recordings, not a limit.
        let mut has_strip = vec![false; num_channels];
        for s in &strips {
            if s.channel < num_channels {
                has_strip[s.channel] = true;
            }
        }
        let unstripped = (0..num_channels).filter(|ch| !has_strip[*ch]).collect();
        Self {
            strips,
            num_channels,
            peaks: Vec::new(),
            metering: false,
            unstripped,
        }
    }

    /// Start filling [`block_peaks`](Self::block_peaks). Playback calls this;
    /// the render never does.
    pub fn enable_metering(&mut self) {
        self.metering = true;
        self.peaks = vec![0.0; self.num_channels];
    }

    /// Per-source-channel peaks of the most recent [`process`](Self::process)
    /// call. One block only — the ballistics live in the caller, which knows
    /// how long a block lasts.
    pub fn block_peaks(&self) -> &[f32] {
        &self.peaks
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
        // Indexed rather than searched, for the same reason as `unstripped`
        // above: a linear find per strip is quadratic in the track count, and
        // this runs on every parameter change while a fader is being dragged.
        let mut by_channel = vec![usize::MAX; old.num_channels];
        for (i, p) in old.strips.iter().enumerate() {
            if p.channel < by_channel.len() {
                by_channel[p.channel] = i;
            }
        }
        for s in &mut self.strips {
            let Some(&i) = by_channel.get(s.channel) else {
                continue;
            };
            if i != usize::MAX {
                s.eq.adopt_state_from(&old.strips[i].eq);
            }
        }
    }

    /// Mix one block of interleaved multichannel input into interleaved
    /// stereo. `input.len()` must be a multiple of the channel count.
    /// `out` is cleared and refilled with `2 * num_frames` samples.
    pub fn process(&mut self, input: &[f64], out: &mut Vec<f64>) {
        // Destructured so the per-strip loop can touch `peaks` — iterating
        // `self.strips` mutably would otherwise hold all of `self`.
        let Self {
            strips,
            num_channels,
            peaks,
            metering,
            unstripped,
        } = self;
        let n_ch = *num_channels;
        let metering = *metering;
        debug_assert_eq!(input.len() % n_ch, 0);
        let frames = input.len() / n_ch;
        out.clear();
        out.resize(frames * 2, 0.0);
        if metering {
            peaks.fill(0.0);
        }
        for strip in strips.iter_mut() {
            // Accumulated locally and merged once: a `&mut peaks[i]` held
            // across the sample loop would cost a bounds check per sample.
            let mut pk = 0.0f32;
            if strip.has_eq {
                for (f, frame) in input.chunks_exact(n_ch).enumerate() {
                    let s = strip.eq.process(frame[strip.channel]);
                    if metering {
                        pk = pk.max(s.abs() as f32);
                    }
                    out[2 * f] += s * strip.left;
                    out[2 * f + 1] += s * strip.right;
                }
            } else {
                for (f, frame) in input.chunks_exact(n_ch).enumerate() {
                    let s = frame[strip.channel];
                    if metering {
                        pk = pk.max(s.abs() as f32);
                    }
                    out[2 * f] += s * strip.left;
                    out[2 * f + 1] += s * strip.right;
                }
            }
            if metering {
                // Two tracks may point at one channel; the louder wins.
                let slot = &mut peaks[strip.channel];
                *slot = slot.max(pk);
            }
        }
        if metering {
            // One pass over the block, not one per channel. A frame is
            // contiguous, so reading it once and updating every silent
            // channel's maximum costs one cache line; the other way round —
            // a full strided walk per channel — is a cache miss per sample,
            // and a 200-track take where most tracks are muted would pay it
            // 150 times over.
            for &ch in unstripped.iter() {
                peaks[ch] = 0.0;
            }
            for frame in input.chunks_exact(n_ch) {
                for &ch in unstripped.iter() {
                    let v = frame[ch].abs() as f32;
                    if v > peaks[ch] {
                        peaks[ch] = v;
                    }
                }
            }
        }
    }
}
