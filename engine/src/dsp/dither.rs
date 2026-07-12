//! TPDF dither for word-length reduction.
//!
//! Triangular-PDF noise of ±1 LSB decorrelates the quantization error from
//! the signal, replacing truncation distortion with a benign constant noise
//! floor — the standard choice for 16-bit delivery. Deterministic xorshift64*
//! generator, no external RNG dependency.

#[derive(Debug, Clone)]
pub struct TpdfDither {
    state: u64,
}

impl Default for TpdfDither {
    fn default() -> Self {
        Self::new(0x9E37_79B9_7F4A_7C15)
    }
}

impl TpdfDither {
    pub fn new(seed: u64) -> Self {
        Self {
            state: seed.max(1), // xorshift state must be non-zero
        }
    }

    #[inline]
    fn uniform(&mut self) -> f64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;
        // 53 significant bits → uniform in [0, 1)
        (self.state.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Next triangular-PDF noise value in (−1, 1), in LSB units — add it to
    /// the scaled sample before rounding.
    #[inline]
    pub fn next(&mut self) -> f64 {
        self.uniform() - self.uniform()
    }
}
