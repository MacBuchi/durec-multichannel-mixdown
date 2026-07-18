//! Streaming mid/side FIR filter stage (overlap-add fast convolution).
//!
//! Applies one linear-phase FIR to the mid channel and one to the side
//! channel of an interleaved stereo stream. Convolution runs in the frequency
//! domain (overlap-add with a real FFT), so 4k-tap matching filters cost a
//! few FFTs per 12k frames instead of an O(n·taps) time-domain loop.
//!
//! Same contract as `TruePeakLimiter`: feed blocks of any size through
//! `process`, call `flush` at EOF, and the total output is sample-aligned and
//! length-preserving — the (taps−1)/2 group delay of the linear-phase FIRs is
//! swallowed up front and the tail is drained by `flush`. Output is
//! bit-identical regardless of how the input is chunked.

use realfft::num_complex::Complex;
use realfft::{ComplexToReal, RealFftPlanner, RealToComplex};
use std::collections::VecDeque;
use std::sync::Arc;

pub struct MsFirStage {
    taps_len: usize,
    /// Input samples per convolution block (`fft_len - taps_len + 1`).
    seg_len: usize,
    fft_len: usize,
    fwd: Arc<dyn RealToComplex<f64>>,
    inv: Arc<dyn ComplexToReal<f64>>,
    spec_mid: Vec<Complex<f64>>,
    spec_side: Vec<Complex<f64>>,

    // pending input for the current block, one buffer per channel
    mid_in: Vec<f64>,
    side_in: Vec<f64>,
    // overlap-add tails, taps_len − 1 samples each
    mid_tail: Vec<f64>,
    side_tail: Vec<f64>,
    // scratch for FFT round trips
    time_scratch: Vec<f64>,
    freq_scratch: Vec<Complex<f64>>,

    /// Filtered (mid, side) frames ready to emit.
    ready: VecDeque<(f64, f64)>,
    /// Group-delay frames still to be discarded from the head of the output.
    skip_remaining: usize,
    frames_in: u64,
    frames_out: u64,
}

impl MsFirStage {
    /// `fir_mid` and `fir_side` must share one odd length so mid and side
    /// stay time-aligned and the group delay is an integer frame count.
    pub fn new(fir_mid: &[f64], fir_side: &[f64]) -> Self {
        assert_eq!(
            fir_mid.len(),
            fir_side.len(),
            "mid/side FIR length mismatch"
        );
        assert!(!fir_mid.is_empty(), "empty FIR");
        assert_eq!(fir_mid.len() % 2, 1, "FIR length must be odd");
        let taps_len = fir_mid.len();
        // 4× the padded filter length keeps overlap-add efficient:
        // 4095 taps → 16384-point FFTs over 12290-sample segments.
        let fft_len = (taps_len.next_power_of_two() * 4).max(16);
        let seg_len = fft_len - taps_len + 1;

        let mut planner = RealFftPlanner::<f64>::new();
        let fwd = planner.plan_fft_forward(fft_len);
        let inv = planner.plan_fft_inverse(fft_len);

        let mut time_scratch = vec![0.0; fft_len];
        let mut freq_scratch = fwd.make_output_vec();
        let mut transform = |taps: &[f64]| -> Vec<Complex<f64>> {
            time_scratch.fill(0.0);
            time_scratch[..taps.len()].copy_from_slice(taps);
            fwd.process(&mut time_scratch, &mut freq_scratch)
                .expect("FIR spectrum FFT");
            freq_scratch.clone()
        };
        let spec_mid = transform(fir_mid);
        let spec_side = transform(fir_side);

        Self {
            taps_len,
            seg_len,
            fft_len,
            fwd,
            inv,
            spec_mid,
            spec_side,
            mid_in: Vec::with_capacity(seg_len),
            side_in: Vec::with_capacity(seg_len),
            mid_tail: vec![0.0; taps_len - 1],
            side_tail: vec![0.0; taps_len - 1],
            time_scratch,
            freq_scratch,
            ready: VecDeque::with_capacity(seg_len),
            skip_remaining: (taps_len - 1) / 2,
            frames_in: 0,
            frames_out: 0,
        }
    }

    /// Group delay of the linear-phase FIRs in frames ((taps − 1) / 2).
    pub fn latency_frames(&self) -> usize {
        (self.taps_len - 1) / 2
    }

    /// Drop all streaming state (buffers, tails, counters) while keeping the
    /// filters — live playback calls this on seeks, like `Biquad`/limiter
    /// resets, so stale audio never bleeds across a jump.
    pub fn reset(&mut self) {
        self.mid_in.clear();
        self.side_in.clear();
        self.mid_tail.fill(0.0);
        self.side_tail.fill(0.0);
        self.ready.clear();
        self.skip_remaining = (self.taps_len - 1) / 2;
        self.frames_in = 0;
        self.frames_out = 0;
    }

    /// Feed interleaved stereo; appends the filtered signal to `out` (the
    /// first calls emit fewer frames while the group delay primes).
    pub fn process(&mut self, stereo_in: &[f64], out: &mut Vec<f64>) {
        debug_assert_eq!(stereo_in.len() % 2, 0);
        for fr in stereo_in.chunks_exact(2) {
            let (l, r) = (fr[0], fr[1]);
            self.mid_in.push((l + r) * 0.5);
            self.side_in.push((l - r) * 0.5);
            self.frames_in += 1;
            if self.mid_in.len() == self.seg_len {
                self.run_block();
            }
        }
        self.emit_ready(out);
    }

    /// Drain the group-delay tail at EOF by convolving zero padding until
    /// every input frame has been emitted. Output length then equals input
    /// length exactly.
    pub fn flush(&mut self, out: &mut Vec<f64>) {
        while self.frames_out + (self.ready.len() as u64) < self.frames_in {
            self.mid_in.resize(self.seg_len, 0.0);
            self.side_in.resize(self.seg_len, 0.0);
            self.run_block();
        }
        self.emit_ready(out);
        self.ready.clear();
    }

    /// Convolve the pending (full) input block against both filters and queue
    /// the filtered frames, minus any group-delay frames still to skip.
    fn run_block(&mut self) {
        debug_assert_eq!(self.mid_in.len(), self.seg_len);
        let seg = self.seg_len;
        let scale = 1.0 / self.fft_len as f64;
        let mut convolve =
            |input: &mut Vec<f64>, spec: &[Complex<f64>], tail: &mut Vec<f64>| -> Vec<f64> {
                self.time_scratch[..seg].copy_from_slice(input);
                self.time_scratch[seg..].fill(0.0);
                self.fwd
                    .process(&mut self.time_scratch, &mut self.freq_scratch)
                    .expect("FIR block FFT");
                for (bin, h) in self.freq_scratch.iter_mut().zip(spec) {
                    *bin *= h * scale;
                }
                self.inv
                    .process(&mut self.freq_scratch, &mut self.time_scratch)
                    .expect("FIR block IFFT");
                // Overlap-add: of the fft_len result samples, the first
                // seg_len (plus the previous tail) are this block's output;
                // the trailing taps_len − 1 become the next tail.
                let mut block: Vec<f64> = self.time_scratch[..seg].to_vec();
                for (y, t) in block.iter_mut().zip(tail.iter()) {
                    *y += *t;
                }
                tail.clear();
                tail.extend_from_slice(&self.time_scratch[seg..]);
                input.clear();
                block
            };

        let mid_block = convolve(&mut self.mid_in, &self.spec_mid, &mut self.mid_tail);
        let side_block = convolve(&mut self.side_in, &self.spec_side, &mut self.side_tail);

        let skip = self.skip_remaining.min(seg);
        self.skip_remaining -= skip;
        for (m, s) in mid_block[skip..].iter().zip(&side_block[skip..]) {
            self.ready.push_back((*m, *s));
        }
    }

    /// Move ready frames to `out`, never emitting more than went in.
    fn emit_ready(&mut self, out: &mut Vec<f64>) {
        while self.frames_out < self.frames_in {
            let Some((m, s)) = self.ready.pop_front() else {
                break;
            };
            out.push(m + s);
            out.push(m - s);
            self.frames_out += 1;
        }
    }
}
