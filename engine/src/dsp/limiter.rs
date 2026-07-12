//! Stereo-linked true-peak lookahead limiter.
//!
//! Detection runs at 4× oversampling (polyphase windowed-sinc interpolator in
//! the spirit of ITU-R BS.1770-4 Annex 2), so inter-sample peaks that would
//! clip DACs and lossy encoders are caught — the whole reason this exists
//! instead of a plain sample-peak clipper.
//!
//! Gain computer: per-frame target gain → exponential release toward unity →
//! sliding-window minimum (monotonic wedge) → boxcar average. The min/boxcar
//! pair produces a linear attack ramp that reaches the required gain exactly
//! when the peak arrives, so the ceiling is never crossed by construction.
//! Audio is delayed by `latency_frames()` to line up with the smoothed gain;
//! `process` swallows that many frames up front and `flush` emits them at the
//! end, so a full render is sample-aligned and length-preserving.

use serde::{Deserialize, Serialize};

use crate::dsp::db_to_linear;

/// Oversampling factor of the true-peak detector. BS.1770 specifies 4×, but
/// a 4× grid can under-read an fs/4 peak by up to 0.17 dB at worst-case
/// phase (the grid lands 22.5° off the crest); 8× tightens that to ~0.04 dB,
/// comfortably inside MARGIN, at negligible cost.
const OVERSAMPLE: usize = 8;
/// Interpolator taps per phase (total FIR length = PHASE_TAPS * OVERSAMPLE).
const PHASE_TAPS: usize = 12;
/// Detector group delay in base-rate frames.
const DETECTOR_DELAY: usize = PHASE_TAPS / 2;
/// Internal headroom so base-rate gain application can never let the
/// reconstructed inter-sample peak cross the ceiling.
const MARGIN: f64 = 0.985;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LimiterParams {
    /// True-peak ceiling in dBTP (−1.0 default).
    pub ceiling_dbtp: f64,
    /// Release time constant in ms.
    pub release_ms: f64,
    /// Lookahead (= attack ramp length) in ms.
    pub lookahead_ms: f64,
}

impl Default for LimiterParams {
    fn default() -> Self {
        Self {
            ceiling_dbtp: -1.0,
            release_ms: 100.0,
            lookahead_ms: 2.5,
        }
    }
}

/// Windowed-sinc 4× interpolator coefficients, Hann window, unity DC gain
/// per phase.
fn interpolator_taps() -> [[f64; PHASE_TAPS]; OVERSAMPLE] {
    let n = PHASE_TAPS * OVERSAMPLE;
    let center = (n - 1) as f64 / 2.0;
    let mut taps = [[0.0; PHASE_TAPS]; OVERSAMPLE];
    for (i, tap) in (0..n).map(|i| {
        let x = (i as f64 - center) / OVERSAMPLE as f64;
        let sinc = if x.abs() < 1e-12 {
            1.0
        } else {
            (std::f64::consts::PI * x).sin() / (std::f64::consts::PI * x)
        };
        let w = 0.5 - 0.5 * (std::f64::consts::TAU * i as f64 / (n - 1) as f64).cos();
        (i, sinc * w)
    }) {
        taps[i % OVERSAMPLE][i / OVERSAMPLE] = tap;
    }
    // Normalise each phase to unity DC gain so a constant signal measures
    // exactly its sample value.
    for phase in &mut taps {
        let sum: f64 = phase.iter().sum();
        for t in phase.iter_mut() {
            *t /= sum;
        }
    }
    taps
}

/// Monotonic sliding-window minimum (wedge) over a fixed window size.
#[derive(Debug)]
struct SlidingMin {
    window: usize,
    /// (index, value), values increasing from front to back.
    deque: std::collections::VecDeque<(u64, f64)>,
    next_index: u64,
}

impl SlidingMin {
    fn new(window: usize) -> Self {
        Self {
            window,
            deque: std::collections::VecDeque::with_capacity(window + 1),
            next_index: 0,
        }
    }

    /// Push a value, get the minimum of the last `window` values.
    fn push(&mut self, value: f64) -> f64 {
        while self.deque.back().is_some_and(|&(_, v)| v >= value) {
            self.deque.pop_back();
        }
        self.deque.push_back((self.next_index, value));
        let expire = self.next_index.saturating_sub(self.window as u64 - 1);
        while self.deque.front().is_some_and(|&(i, _)| i < expire) {
            self.deque.pop_front();
        }
        self.next_index += 1;
        self.deque.front().map(|&(_, v)| v).unwrap_or(1.0)
    }

    fn reset(&mut self) {
        self.deque.clear();
        self.next_index = 0;
    }
}

pub struct TruePeakLimiter {
    ceiling: f64,
    release_coeff: f64,
    lookahead: usize, // N: boxcar length = attack ramp frames
    latency: usize,   // N + DETECTOR_DELAY
    taps: [[f64; PHASE_TAPS]; OVERSAMPLE],

    // detector history: last PHASE_TAPS frames per channel
    hist_l: [f64; PHASE_TAPS],
    hist_r: [f64; PHASE_TAPS],
    hist_pos: usize,

    release_state: f64,
    smin: SlidingMin,
    boxcar: std::collections::VecDeque<f64>,
    boxcar_sum: f64,

    /// Delay line for the audio (interleaved stereo), length = latency frames.
    delay: std::collections::VecDeque<(f64, f64)>,
    max_reduction: f64, // min gain seen (linear)
}

impl TruePeakLimiter {
    pub fn new(params: LimiterParams, sample_rate: u32) -> Self {
        let lookahead =
            ((params.lookahead_ms / 1000.0 * sample_rate as f64).round() as usize).max(1);
        let release_s = (params.release_ms / 1000.0).max(0.001);
        let latency = lookahead + DETECTOR_DELAY;
        Self {
            ceiling: db_to_linear(params.ceiling_dbtp, -120.0) * MARGIN,
            release_coeff: (-1.0 / (release_s * sample_rate as f64)).exp(),
            lookahead,
            latency,
            taps: interpolator_taps(),
            hist_l: [0.0; PHASE_TAPS],
            hist_r: [0.0; PHASE_TAPS],
            hist_pos: 0,
            release_state: 1.0,
            // The wedge window covers the boxcar span plus detector slop so a
            // detected peak is always inside the attack ramp.
            smin: SlidingMin::new(lookahead + DETECTOR_DELAY * 2 + 1),
            boxcar: std::collections::VecDeque::with_capacity(lookahead + 1),
            boxcar_sum: 0.0,
            delay: std::collections::VecDeque::with_capacity(latency + 1),
            max_reduction: 1.0,
        }
    }

    /// Total delay from input to output, in frames.
    pub fn latency_frames(&self) -> usize {
        self.latency
    }

    /// Largest gain reduction applied so far, in dB (≥ 0).
    pub fn max_gain_reduction_db(&self) -> f64 {
        -20.0 * self.max_reduction.log10()
    }

    pub fn reset(&mut self) {
        self.hist_l = [0.0; PHASE_TAPS];
        self.hist_r = [0.0; PHASE_TAPS];
        self.hist_pos = 0;
        self.release_state = 1.0;
        self.smin.reset();
        self.boxcar.clear();
        self.boxcar_sum = 0.0;
        self.delay.clear();
    }

    /// True peak (linear, absolute) of the current frame as seen by the 4×
    /// interpolator, both channels.
    #[inline]
    fn detect(&mut self, l: f64, r: f64) -> f64 {
        self.hist_l[self.hist_pos] = l;
        self.hist_r[self.hist_pos] = r;
        self.hist_pos = (self.hist_pos + 1) % PHASE_TAPS;
        let mut tp = l.abs().max(r.abs());
        for phase in &self.taps {
            let (mut acc_l, mut acc_r) = (0.0, 0.0);
            // hist index 0 = oldest: walk from hist_pos (oldest after insert)
            let mut idx = self.hist_pos;
            for &t in phase.iter().rev() {
                acc_l += self.hist_l[idx] * t;
                acc_r += self.hist_r[idx] * t;
                idx += 1;
                if idx == PHASE_TAPS {
                    idx = 0;
                }
            }
            tp = tp.max(acc_l.abs()).max(acc_r.abs());
        }
        tp
    }

    /// Feed interleaved stereo; appends the limited signal to `out` (delayed
    /// by `latency_frames()`; the first calls emit fewer frames while the
    /// delay line primes).
    pub fn process(&mut self, stereo_in: &[f64], out: &mut Vec<f64>) {
        debug_assert_eq!(stereo_in.len() % 2, 0);
        for fr in stereo_in.chunks_exact(2) {
            self.push_frame(fr[0], fr[1], out);
        }
    }

    #[inline]
    fn push_frame(&mut self, l: f64, r: f64, out: &mut Vec<f64>) {
        let tp = self.detect(l, r);
        let target = if tp > self.ceiling {
            self.ceiling / tp
        } else {
            1.0
        };
        // Exponential recovery toward unity, clamped by the current demand.
        let recovered = 1.0 - (1.0 - self.release_state) * self.release_coeff;
        self.release_state = recovered.min(target);
        let windowed_min = self.smin.push(self.release_state);

        // Boxcar over `lookahead` frames → linear attack ramp. By the time a
        // delayed sample is emitted, every value in the boxcar window is ≤ its
        // target gain (the wedge window spans the boxcar plus detector slop),
        // so the average — and thus the applied gain — never overshoots.
        self.boxcar.push_back(windowed_min);
        self.boxcar_sum += windowed_min;
        if self.boxcar.len() > self.lookahead {
            self.boxcar_sum -= self.boxcar.pop_front().unwrap();
        }
        let gain = self.boxcar_sum / self.boxcar.len() as f64;
        self.max_reduction = self.max_reduction.min(gain);

        self.delay.push_back((l, r));
        if self.delay.len() > self.latency {
            let (dl, dr) = self.delay.pop_front().unwrap();
            out.push(dl * gain);
            out.push(dr * gain);
        }
    }

    /// Drain the real audio still inside the delay line at EOF by pushing
    /// `latency_frames()` of silence through the pipeline (render only).
    /// Output length then equals input length exactly.
    pub fn flush(&mut self, out: &mut Vec<f64>) {
        let pending = self.delay.len().min(self.latency);
        for _ in 0..pending {
            self.push_frame(0.0, 0.0, out);
        }
        self.delay.clear(); // discard the silent padding
    }
}
