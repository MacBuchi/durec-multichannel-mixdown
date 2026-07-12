//! RBJ cookbook biquad filters (Audio EQ Cookbook, Robert Bristow-Johnson).
//!
//! Hand-rolled rather than a crate dependency: the engine stays
//! dependency-light, the responses have closed-form checks for tests, and
//! transposed direct form II in f64 is numerically well behaved for audio.
//!
//! All constructors clamp their inputs so a corrupt session file can never
//! produce an unstable filter.

use std::f64::consts::PI;

/// 4th-order Butterworth section Q values (for 24 dB/oct HPF cascades).
pub const BUTTERWORTH_4TH_Q: [f64; 2] = [0.541_196_100_146_197, 1.306_562_964_876_377];
/// 2nd-order Butterworth Q (12 dB/oct).
pub const BUTTERWORTH_2ND_Q: f64 = std::f64::consts::FRAC_1_SQRT_2;

fn clamp_params(sr: f64, freq: f64, q: f64, gain_db: f64) -> (f64, f64, f64) {
    (
        freq.clamp(10.0, 0.45 * sr),
        q.clamp(0.1, 18.0),
        gain_db.clamp(-24.0, 24.0),
    )
}

/// Normalized biquad coefficients (a0 divided out).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BiquadCoeffs {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl Default for BiquadCoeffs {
    fn default() -> Self {
        Self::identity()
    }
}

impl BiquadCoeffs {
    /// Pass-through (unity) filter.
    pub fn identity() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
        }
    }

    /// 2nd-order highpass. −3 dB at `freq` for Q = 1/√2.
    pub fn highpass(sr: f64, freq: f64, q: f64) -> Self {
        let (freq, q, _) = clamp_params(sr, freq, q, 0.0);
        let w0 = 2.0 * PI * freq / sr;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * q);
        let a0 = 1.0 + alpha;
        Self {
            b0: (1.0 + cos) / 2.0 / a0,
            b1: -(1.0 + cos) / a0,
            b2: (1.0 + cos) / 2.0 / a0,
            a1: -2.0 * cos / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    /// Peaking EQ: boost/cut of `gain_db` centred at `freq`.
    pub fn peaking(sr: f64, freq: f64, gain_db: f64, q: f64) -> Self {
        let (freq, q, gain_db) = clamp_params(sr, freq, q, gain_db);
        let a = 10f64.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * freq / sr;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * q);
        let a0 = 1.0 + alpha / a;
        Self {
            b0: (1.0 + alpha * a) / a0,
            b1: -2.0 * cos / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: -2.0 * cos / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }

    /// Low shelf: `gain_db` applied below `freq`.
    pub fn low_shelf(sr: f64, freq: f64, gain_db: f64, q: f64) -> Self {
        let (freq, q, gain_db) = clamp_params(sr, freq, q, gain_db);
        let a = 10f64.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * freq / sr;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let a0 = (a + 1.0) + (a - 1.0) * cos + two_sqrt_a_alpha;
        Self {
            b0: a * ((a + 1.0) - (a - 1.0) * cos + two_sqrt_a_alpha) / a0,
            b1: 2.0 * a * ((a - 1.0) - (a + 1.0) * cos) / a0,
            b2: a * ((a + 1.0) - (a - 1.0) * cos - two_sqrt_a_alpha) / a0,
            a1: -2.0 * ((a - 1.0) + (a + 1.0) * cos) / a0,
            a2: ((a + 1.0) + (a - 1.0) * cos - two_sqrt_a_alpha) / a0,
        }
    }

    /// High shelf: `gain_db` applied above `freq`.
    pub fn high_shelf(sr: f64, freq: f64, gain_db: f64, q: f64) -> Self {
        let (freq, q, gain_db) = clamp_params(sr, freq, q, gain_db);
        let a = 10f64.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * freq / sr;
        let (sin, cos) = w0.sin_cos();
        let alpha = sin / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;
        let a0 = (a + 1.0) - (a - 1.0) * cos + two_sqrt_a_alpha;
        Self {
            b0: a * ((a + 1.0) + (a - 1.0) * cos + two_sqrt_a_alpha) / a0,
            b1: -2.0 * a * ((a - 1.0) + (a + 1.0) * cos) / a0,
            b2: a * ((a + 1.0) + (a - 1.0) * cos - two_sqrt_a_alpha) / a0,
            a1: 2.0 * ((a - 1.0) - (a + 1.0) * cos) / a0,
            a2: ((a + 1.0) - (a - 1.0) * cos - two_sqrt_a_alpha) / a0,
        }
    }

    /// Magnitude response |H| at `freq` — used by tests and UI curve displays.
    pub fn magnitude_at(&self, sr: f64, freq: f64) -> f64 {
        let w = 2.0 * PI * freq / sr;
        // |H(e^jw)|² = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²) at z = e^jw
        let num = mag2(self.b0, self.b1, self.b2, w);
        let den = mag2(1.0, self.a1, self.a2, w);
        (num / den).sqrt()
    }
}

/// |c0 + c1·e^{−jw} + c2·e^{−2jw}|²
fn mag2(c0: f64, c1: f64, c2: f64, w: f64) -> f64 {
    let re = c0 + c1 * w.cos() + c2 * (2.0 * w).cos();
    let im = -(c1 * w.sin() + c2 * (2.0 * w).sin());
    re * re + im * im
}

/// One stateful biquad section, transposed direct form II.
#[derive(Debug, Clone, Copy, Default)]
pub struct Biquad {
    pub coeffs: BiquadCoeffs,
    z1: f64,
    z2: f64,
}

impl Biquad {
    pub fn new(coeffs: BiquadCoeffs) -> Self {
        Self {
            coeffs,
            z1: 0.0,
            z2: 0.0,
        }
    }

    #[inline]
    pub fn process(&mut self, x: f64) -> f64 {
        let c = &self.coeffs;
        let y = c.b0 * x + self.z1;
        self.z1 = c.b1 * x - c.a1 * y + self.z2;
        self.z2 = c.b2 * x - c.a2 * y;
        y
    }

    pub fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }

    /// Carry filter state over from another section (click-free live
    /// parameter updates: new coefficients, old state).
    pub fn adopt_state(&mut self, other: &Biquad) {
        self.z1 = other.z1;
        self.z2 = other.z2;
    }
}
