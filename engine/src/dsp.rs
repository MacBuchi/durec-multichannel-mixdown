//! Gain and pan primitives.

/// Faders at or below this dB value are treated as silence.
pub const GAIN_FLOOR_DB: f64 = -60.0;

/// Convert a dB value to a linear amplitude multiplier. Values at or below
/// `floor_db` return 0.0 (fader fully down = silence, no noise floor).
pub fn db_to_linear(db: f64, floor_db: f64) -> f64 {
    if db <= floor_db {
        0.0
    } else {
        10f64.powf(db / 20.0)
    }
}

pub fn linear_to_db(gain: f64) -> f64 {
    if gain <= 0.0 {
        f64::NEG_INFINITY
    } else {
        20.0 * gain.log10()
    }
}

/// Constant-power pan law (−3 dB centre).
///
/// `pan` is −1.0 (hard left) .. +1.0 (hard right). Returns `(left, right)`
/// gains. At centre both gains are 1/√2 ≈ 0.7071 so perceived loudness stays
/// constant across the pan range — unlike linear panning, which drops centred
/// signals by 6 dB and gets louder toward the edges.
pub fn pan_gains(pan: f64) -> (f64, f64) {
    let p = pan.clamp(-1.0, 1.0);
    let theta = (p + 1.0) * std::f64::consts::FRAC_PI_4; // 0 .. π/2
    (theta.cos(), theta.sin())
}
