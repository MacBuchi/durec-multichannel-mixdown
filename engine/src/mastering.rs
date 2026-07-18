//! Reference mastering: piecewise mid/side analysis, matching-EQ design and
//! level matching against a reference track.
//!
//! Clean-room implementation of the reference-mastering idea popularised by
//! Matchering 2.0: measure the loud sections of both the target mix and a
//! reference track (RMS + average spectrum, mid and side separately), then
//! EQ and gain the target so it lands on the reference's tonality, loudness
//! and stereo width. Only the publicly documented algorithm outline was used;
//! no Matchering (GPL-3.0) source code was consulted, ported or copied — the
//! smoothing, clamping, FIR design and the analytic level correction below
//! are original to this engine.
//!
//! Pipeline (all streaming-friendly):
//! 1. [`MasteringAnalyzer`] — one pass over stereo audio, split into
//!    [`PIECE_SECONDS`] pieces; per piece: mid/side RMS plus averaged
//!    magnitude and power spectra (Hann STFT, [`ANALYSIS_FFT`], 50 %
//!    overlap). "Loudest pieces" (mid RMS ≥ mean) are aggregated so silence
//!    and fades don't skew the match.
//! 2. [`ReferenceProfile`] — the reference's aggregate, serializable so a
//!    reference only needs analyzing once.
//! 3. [`design_mastering`] — matching curve = ref/target spectrum per bin
//!    (RMS-neutralised, clamped to ±[`MAX_MATCH_DB`], smoothed over
//!    1/6…1/3-octave log-frequency windows), rendered into linear-phase
//!    [`FIR_TAPS`]-tap FIRs for mid and side. Output level is matched
//!    analytically via Parseval (predicted post-EQ RMS from the target power
//!    spectrum × the actual FIR response), so no extra render pass is needed.
//!
//! The FIRs are applied by `dsp::fir::MsFirStage` during render pass 2.

use std::sync::Arc;

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};
use serde::{Deserialize, Serialize};

use crate::error::{EngineError, Result};

/// Analysis piece length. Long enough that a piece spans full bars of a
/// song, short enough that quiet intros/outros are isolated and excluded.
pub const PIECE_SECONDS: f64 = 15.0;
/// STFT size for spectrum analysis (and the matching-curve grid).
pub const ANALYSIS_FFT: usize = 4096;
const ANALYSIS_HOP: usize = ANALYSIS_FFT / 2;
const BINS: usize = ANALYSIS_FFT / 2 + 1;
/// Length of the designed matching FIRs (odd → integer group delay).
pub const FIR_TAPS: usize = 4095;
/// Matching curve clamp: a band is never boosted/cut by more than this.
/// Guards against runaway boosts where the target has next to no energy
/// (hiss, band-limited references).
pub const MAX_MATCH_DB: f64 = 18.0;
/// Bump when analysis or design changes so cached profiles are invalidated.
pub const PROFILE_VERSION: u32 = 1;
/// A side channel below this fraction of the mid RMS counts as mono.
const MONO_SIDE_RATIO: f64 = 1e-4;

// ── analysis ────────────────────────────────────────────────────────────────

struct PieceAccum {
    frames: u64,
    sum_sq_mid: f64,
    sum_sq_side: f64,
    fft_frames: u32,
    mag_mid: Vec<f32>,
    mag_side: Vec<f32>,
    pow_mid: Vec<f32>,
    pow_side: Vec<f32>,
}

impl PieceAccum {
    fn new() -> Self {
        Self {
            frames: 0,
            sum_sq_mid: 0.0,
            sum_sq_side: 0.0,
            fft_frames: 0,
            mag_mid: vec![0.0; BINS],
            mag_side: vec![0.0; BINS],
            pow_mid: vec![0.0; BINS],
            pow_side: vec![0.0; BINS],
        }
    }
}

/// Aggregate loudest-piece statistics of one signal.
pub struct MasteringStats {
    pub sample_rate: u32,
    pub duration_seconds: f64,
    /// RMS over the loudest pieces, mid channel.
    pub mid_rms: f64,
    pub side_rms: f64,
    /// Mean STFT magnitude per bin over the loudest pieces.
    pub mid_spectrum: Vec<f64>,
    pub side_spectrum: Vec<f64>,
    /// Mean STFT power (magnitude²) per bin — used for the Parseval-based
    /// post-EQ level prediction.
    pub mid_power: Vec<f64>,
    pub side_power: Vec<f64>,
}

/// Streaming piecewise mid/side analyzer. Feed interleaved stereo blocks of
/// any size via [`push`](Self::push), then [`finish`](Self::finish).
pub struct MasteringAnalyzer {
    sample_rate: u32,
    piece_frames: u64,
    fft: Arc<dyn RealToComplex<f64>>,
    window: Vec<f64>,
    time_scratch: Vec<f64>,
    freq_scratch: Vec<Complex<f64>>,

    // rolling mono buffers; `buf_start` is the absolute frame index of
    // element 0, `next_fft_pos` the absolute start of the next STFT window
    mid_buf: Vec<f64>,
    side_buf: Vec<f64>,
    buf_start: u64,
    next_fft_pos: u64,
    total_frames: u64,
    pieces: Vec<PieceAccum>,
}

impl MasteringAnalyzer {
    pub fn new(sample_rate: u32) -> Self {
        let mut planner = RealFftPlanner::<f64>::new();
        let fft = planner.plan_fft_forward(ANALYSIS_FFT);
        let freq_scratch = fft.make_output_vec();
        // Periodic Hann for the STFT.
        let window: Vec<f64> = (0..ANALYSIS_FFT)
            .map(|i| 0.5 - 0.5 * (std::f64::consts::TAU * i as f64 / ANALYSIS_FFT as f64).cos())
            .collect();
        Self {
            sample_rate,
            piece_frames: ((PIECE_SECONDS * sample_rate as f64) as u64).max(1),
            fft,
            window,
            time_scratch: vec![0.0; ANALYSIS_FFT],
            freq_scratch,
            mid_buf: Vec::with_capacity(ANALYSIS_FFT * 16),
            side_buf: Vec::with_capacity(ANALYSIS_FFT * 16),
            buf_start: 0,
            next_fft_pos: 0,
            total_frames: 0,
            pieces: Vec::new(),
        }
    }

    pub fn push(&mut self, stereo: &[f64]) {
        debug_assert_eq!(stereo.len() % 2, 0);
        for fr in stereo.chunks_exact(2) {
            let m = (fr[0] + fr[1]) * 0.5;
            let s = (fr[0] - fr[1]) * 0.5;
            let piece = (self.total_frames / self.piece_frames) as usize;
            self.ensure_piece(piece);
            let p = &mut self.pieces[piece];
            p.frames += 1;
            p.sum_sq_mid += m * m;
            p.sum_sq_side += s * s;
            self.mid_buf.push(m);
            self.side_buf.push(s);
            self.total_frames += 1;
        }
        self.drain_stft();
    }

    fn ensure_piece(&mut self, idx: usize) {
        while self.pieces.len() <= idx {
            self.pieces.push(PieceAccum::new());
        }
    }

    /// Run every STFT window that is fully buffered; a window is attributed
    /// to the piece containing its start frame.
    fn drain_stft(&mut self) {
        while self.next_fft_pos + ANALYSIS_FFT as u64 <= self.buf_start + self.mid_buf.len() as u64
        {
            let off = (self.next_fft_pos - self.buf_start) as usize;
            let piece = (self.next_fft_pos / self.piece_frames) as usize;
            self.ensure_piece(piece);

            for i in 0..ANALYSIS_FFT {
                self.time_scratch[i] = self.mid_buf[off + i] * self.window[i];
            }
            self.fft
                .process(&mut self.time_scratch, &mut self.freq_scratch)
                .expect("mastering STFT");
            let p = &mut self.pieces[piece];
            for (k, x) in self.freq_scratch.iter().enumerate() {
                let pow = x.norm_sqr();
                p.mag_mid[k] += pow.sqrt() as f32;
                p.pow_mid[k] += pow as f32;
            }

            for i in 0..ANALYSIS_FFT {
                self.time_scratch[i] = self.side_buf[off + i] * self.window[i];
            }
            self.fft
                .process(&mut self.time_scratch, &mut self.freq_scratch)
                .expect("mastering STFT");
            let p = &mut self.pieces[piece];
            for (k, x) in self.freq_scratch.iter().enumerate() {
                let pow = x.norm_sqr();
                p.mag_side[k] += pow.sqrt() as f32;
                p.pow_side[k] += pow as f32;
            }
            p.fft_frames += 1;

            self.next_fft_pos += ANALYSIS_HOP as u64;
        }
        // Drop buffered audio no STFT window will read again.
        let consumed =
            (self.next_fft_pos.saturating_sub(self.buf_start) as usize).min(self.mid_buf.len());
        if consumed >= ANALYSIS_FFT * 8 {
            self.mid_buf.drain(..consumed);
            self.side_buf.drain(..consumed);
            self.buf_start += consumed as u64;
        }
    }

    /// Aggregate the loudest pieces (mid RMS ≥ mean over pieces).
    pub fn finish(mut self) -> MasteringStats {
        // A trailing fragment under half a piece would skew the mean; drop it
        // unless it is all we have.
        if self.pieces.len() > 1
            && self
                .pieces
                .last()
                .is_some_and(|p| p.frames < self.piece_frames / 2)
        {
            self.pieces.pop();
        }

        let rms: Vec<f64> = self
            .pieces
            .iter()
            .map(|p| {
                if p.frames > 0 {
                    (p.sum_sq_mid / p.frames as f64).sqrt()
                } else {
                    0.0
                }
            })
            .collect();
        let mean = if rms.is_empty() {
            0.0
        } else {
            rms.iter().sum::<f64>() / rms.len() as f64
        };
        // Tiny tolerance so equally-loud pieces are never excluded by float
        // noise in the mean.
        let threshold = mean * (1.0 - 1e-9);

        let mut frames = 0u64;
        let mut sum_sq_mid = 0.0;
        let mut sum_sq_side = 0.0;
        let mut fft_frames = 0u64;
        let mut mid_spectrum = vec![0.0f64; BINS];
        let mut side_spectrum = vec![0.0f64; BINS];
        let mut mid_power = vec![0.0f64; BINS];
        let mut side_power = vec![0.0f64; BINS];
        for (p, r) in self.pieces.iter().zip(&rms) {
            if *r < threshold {
                continue;
            }
            frames += p.frames;
            sum_sq_mid += p.sum_sq_mid;
            sum_sq_side += p.sum_sq_side;
            fft_frames += p.fft_frames as u64;
            for k in 0..BINS {
                mid_spectrum[k] += p.mag_mid[k] as f64;
                side_spectrum[k] += p.mag_side[k] as f64;
                mid_power[k] += p.pow_mid[k] as f64;
                side_power[k] += p.pow_side[k] as f64;
            }
        }
        if fft_frames > 0 {
            let inv = 1.0 / fft_frames as f64;
            for k in 0..BINS {
                mid_spectrum[k] *= inv;
                side_spectrum[k] *= inv;
                mid_power[k] *= inv;
                side_power[k] *= inv;
            }
        }

        MasteringStats {
            sample_rate: self.sample_rate,
            duration_seconds: self.total_frames as f64 / self.sample_rate as f64,
            mid_rms: if frames > 0 {
                (sum_sq_mid / frames as f64).sqrt()
            } else {
                0.0
            },
            side_rms: if frames > 0 {
                (sum_sq_side / frames as f64).sqrt()
            } else {
                0.0
            },
            mid_spectrum,
            side_spectrum,
            mid_power,
            side_power,
        }
    }
}

// ── reference profile ───────────────────────────────────────────────────────

/// Serializable fingerprint of a reference track. Sample-rate independent in
/// use: the spectra are interpolated onto the target's bin grid in Hz at
/// design time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ReferenceProfile {
    pub version: u32,
    pub sample_rate: u32,
    pub fft_size: u32,
    pub piece_seconds: f64,
    pub duration_seconds: f64,
    pub mid_rms: f64,
    pub side_rms: f64,
    pub mid_spectrum: Vec<f32>,
    pub side_spectrum: Vec<f32>,
}

impl ReferenceProfile {
    pub fn from_stats(stats: &MasteringStats) -> Self {
        Self {
            version: PROFILE_VERSION,
            sample_rate: stats.sample_rate,
            fft_size: ANALYSIS_FFT as u32,
            piece_seconds: PIECE_SECONDS,
            duration_seconds: stats.duration_seconds,
            mid_rms: stats.mid_rms,
            side_rms: stats.side_rms,
            mid_spectrum: stats.mid_spectrum.iter().map(|&v| v as f32).collect(),
            side_spectrum: stats.side_spectrum.iter().map(|&v| v as f32).collect(),
        }
    }

    fn validate(&self) -> Result<()> {
        if self.version != PROFILE_VERSION {
            return Err(EngineError::Mastering(format!(
                "reference profile version {} not supported (expected {PROFILE_VERSION})",
                self.version
            )));
        }
        if self.fft_size as usize != ANALYSIS_FFT
            || self.mid_spectrum.len() != BINS
            || self.side_spectrum.len() != BINS
        {
            return Err(EngineError::Mastering(
                "reference profile has an unexpected spectrum grid".into(),
            ));
        }
        if self.sample_rate == 0
            || !(self.mid_rms.is_finite() && self.mid_rms > 0.0)
            || self.mid_spectrum.iter().any(|v| !v.is_finite())
            || self.side_spectrum.iter().any(|v| !v.is_finite())
            || self.mid_spectrum.iter().map(|&v| v as f64).sum::<f64>() <= 0.0
        {
            return Err(EngineError::Mastering(
                "reference is too short or silent for mastering".into(),
            ));
        }
        Ok(())
    }
}

// ── matching design ─────────────────────────────────────────────────────────

/// The designed mastering filters, ready for `dsp::fir::MsFirStage`. All
/// gain (RMS match + Parseval correction) is folded into the taps.
pub struct MasteringPlan {
    pub fir_mid: Vec<f64>,
    pub fir_side: Vec<f64>,
    /// Overall mid-channel level change in dB (for the render report).
    pub gain_db: f64,
}

/// Design the matching FIRs that move `target` onto `reference`.
pub fn design_mastering(
    target: &MasteringStats,
    reference: &ReferenceProfile,
) -> Result<MasteringPlan> {
    reference.validate()?;
    if !(target.mid_rms.is_finite() && target.mid_rms > 0.0)
        || target.mid_spectrum.len() != BINS
        || target.mid_spectrum.iter().sum::<f64>() <= 0.0
        || target.mid_power.iter().sum::<f64>() <= 0.0
    {
        return Err(EngineError::Mastering(
            "mix is too short or silent for mastering".into(),
        ));
    }

    let sr = target.sample_rate as f64;
    let ref_mid = resample_spectrum(&reference.mid_spectrum, reference.sample_rate as f64, sr);
    let ref_side = resample_spectrum(&reference.side_spectrum, reference.sample_rate as f64, sr);

    // Mid: shape, then level so the loudest-piece mid RMS lands exactly on
    // the reference's.
    let curve_mid = matching_curve(&target.mid_spectrum, &ref_mid, &target.mid_power, sr);
    let mut fir_mid = design_fir(&curve_mid);
    let a = pow_ratio(&target.mid_power, &fir_response(&fir_mid)).sqrt();
    if !(a.is_finite() && a > 0.0) {
        return Err(EngineError::Mastering(
            "mastering curve design failed on the mid channel".into(),
        ));
    }
    let gain_mid = reference.mid_rms / (target.mid_rms * a);

    // Side: same treatment targeting the reference's absolute side RMS —
    // matching side level and spectrum against the (already matched) mid is
    // exactly the stereo-width match. Mono edge cases fall back to "keep the
    // target's width": identity shape at the mid gain.
    let ref_mono = reference.side_rms < MONO_SIDE_RATIO * reference.mid_rms
        || ref_side.iter().sum::<f64>() <= 0.0;
    let target_mono = target.side_rms < MONO_SIDE_RATIO * target.mid_rms
        || target.side_spectrum.iter().sum::<f64>() <= 0.0
        || target.side_power.iter().sum::<f64>() <= 0.0;
    let fir_side = if ref_mono || target_mono {
        let mut fir = vec![0.0; FIR_TAPS];
        fir[FIR_TAPS / 2] = 1.0;
        for t in fir.iter_mut() {
            *t *= gain_mid;
        }
        fir
    } else {
        let curve_side = matching_curve(&target.side_spectrum, &ref_side, &target.side_power, sr);
        let mut fir = design_fir(&curve_side);
        let b = pow_ratio(&target.side_power, &fir_response(&fir)).sqrt();
        if !(b.is_finite() && b > 0.0) {
            return Err(EngineError::Mastering(
                "mastering curve design failed on the side channel".into(),
            ));
        }
        // Clamp the width change relative to the mid gain like any band.
        let max = 10f64.powf(MAX_MATCH_DB / 20.0);
        let gain_side =
            (reference.side_rms / (target.side_rms * b)).clamp(gain_mid / max, gain_mid * max);
        for t in fir.iter_mut() {
            *t *= gain_side;
        }
        fir
    };
    for t in fir_mid.iter_mut() {
        *t *= gain_mid;
    }
    debug_assert_eq!(fir_mid.len(), fir_side.len());
    if fir_mid
        .iter()
        .chain(fir_side.iter())
        .any(|t| !t.is_finite())
    {
        return Err(EngineError::Mastering(
            "mastering produced a non-finite filter".into(),
        ));
    }

    Ok(MasteringPlan {
        gain_db: 20.0 * gain_mid.log10(),
        fir_mid,
        fir_side,
    })
}

/// Interpolate a reference spectrum (bins in Hz of `src_sr`) onto the target
/// bin grid. Above the reference Nyquist the last value is held, which can
/// only ever cut there — a band-limited reference must not cause a boost.
fn resample_spectrum(src: &[f32], src_sr: f64, dst_sr: f64) -> Vec<f64> {
    let last = src.len() - 1;
    (0..src.len())
        .map(|k| {
            let pos = k as f64 * dst_sr / src_sr;
            if pos >= last as f64 {
                src[last] as f64
            } else {
                let lo = pos.floor() as usize;
                let frac = pos - lo as f64;
                src[lo] as f64 * (1.0 - frac) + src[lo + 1] as f64 * frac
            }
        })
        .collect()
}

/// Raw per-bin ratio → RMS-neutral, clamped, log-frequency smoothed curve.
fn matching_curve(target: &[f64], reference: &[f64], target_power: &[f64], sr: f64) -> Vec<f64> {
    let eps_t = target.iter().cloned().fold(0.0f64, f64::max) * 1e-6;
    let eps_r = reference.iter().cloned().fold(0.0f64, f64::max) * 1e-6;
    let mut curve: Vec<f64> = target
        .iter()
        .zip(reference)
        .map(|(&t, &r)| r.max(eps_r) / t.max(eps_t))
        .collect();
    // Neutralise the curve's own RMS effect so it carries pure shape (this
    // also cancels any absolute-scale mismatch between the two analyses);
    // level is applied afterwards from time-domain RMS.
    let norm = pow_ratio(target_power, &curve).sqrt();
    if norm.is_finite() && norm > 0.0 {
        for c in curve.iter_mut() {
            *c /= norm;
        }
    }
    let mut db: Vec<f64> = curve
        .iter()
        .map(|&c| (20.0 * c.max(1e-12).log10()).clamp(-MAX_MATCH_DB, MAX_MATCH_DB))
        .collect();
    db = smooth_log_db(&db, sr);
    db = smooth_log_db(&db, sr);
    db.iter().map(|&d| 10f64.powf(d / 20.0)).collect()
}

/// Predicted output/input power ratio of filtering a signal with per-bin
/// power `power` through a filter with magnitude response `resp` (Parseval;
/// real-FFT bin weights: DC and Nyquist count once, everything else twice).
fn pow_ratio(power: &[f64], resp: &[f64]) -> f64 {
    let mut num = 0.0;
    let mut den = 0.0;
    for (k, (&p, &h)) in power.iter().zip(resp).enumerate() {
        let w = if k == 0 || k == power.len() - 1 {
            1.0
        } else {
            2.0
        };
        num += p * w * h * h;
        den += p * w;
    }
    num / den
}

/// Moving average of a dB curve over a log-frequency window that widens from
/// ±1/12 octave (≤ 1 kHz) to ±1/6 octave (≥ 8 kHz): tight where matching
/// needs resolution, forgiving where narrow-band ratios are just noise.
fn smooth_log_db(db: &[f64], sr: f64) -> Vec<f64> {
    let n = db.len();
    let bin_hz = sr / ANALYSIS_FFT as f64;
    let mut out = vec![0.0; n];
    for (k, o) in out.iter_mut().enumerate() {
        let f = (k as f64).max(0.5) * bin_hz;
        let half_oct = if f <= 1000.0 {
            1.0 / 12.0
        } else if f >= 8000.0 {
            1.0 / 6.0
        } else {
            let t = (f / 1000.0).ln() / 8f64.ln();
            1.0 / 12.0 + t * (1.0 / 6.0 - 1.0 / 12.0)
        };
        let lo = (((f * 2f64.powf(-half_oct)) / bin_hz).floor() as usize).min(k);
        let hi = (((f * 2f64.powf(half_oct)) / bin_hz).ceil() as usize).clamp(k, n - 1);
        let sum: f64 = db[lo..=hi].iter().sum();
        *o = sum / (hi - lo + 1) as f64;
    }
    out
}

/// Frequency-sampling design: zero-phase spectrum → inverse real FFT →
/// rotate to linear phase → Hann-window to [`FIR_TAPS`] taps.
fn design_fir(curve: &[f64]) -> Vec<f64> {
    debug_assert_eq!(curve.len(), BINS);
    let mut planner = RealFftPlanner::<f64>::new();
    let inv = planner.plan_fft_inverse(ANALYSIS_FFT);
    let mut spec: Vec<Complex<f64>> = curve.iter().map(|&c| Complex::new(c, 0.0)).collect();
    let mut time = inv.make_output_vec();
    inv.process(&mut spec, &mut time).expect("FIR design IFFT");
    let scale = 1.0 / ANALYSIS_FFT as f64;
    let center = FIR_TAPS / 2;
    (0..FIR_TAPS)
        .map(|i| {
            let src = (i + ANALYSIS_FFT - center) % ANALYSIS_FFT;
            let w = 0.5 - 0.5 * (std::f64::consts::TAU * i as f64 / (FIR_TAPS - 1) as f64).cos();
            time[src] * scale * w
        })
        .collect()
}

/// Magnitude response of a FIR on the analysis bin grid.
fn fir_response(taps: &[f64]) -> Vec<f64> {
    let mut planner = RealFftPlanner::<f64>::new();
    let fwd = planner.plan_fft_forward(ANALYSIS_FFT);
    let mut time = vec![0.0; ANALYSIS_FFT];
    time[..taps.len()].copy_from_slice(taps);
    let mut freq = fwd.make_output_vec();
    fwd.process(&mut time, &mut freq).expect("FIR response FFT");
    freq.iter().map(|x| x.norm()).collect()
}
