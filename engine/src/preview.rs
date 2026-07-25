//! The live-preview signal chain, shared by every player.
//!
//! Mix → mastering FIR → true-peak limiter → f32, plus the meters. Exactly
//! the ordering of render pass 2, minus the normalisation gain: what you
//! hear is what the export will contain, at monitoring level.
//!
//! Two players drive this. Natively, [`playback::Player`](crate::playback)
//! runs a decode thread that pulls from a file and pushes into a ring buffer
//! for cpal. In the browser there is no cpal and no synchronous file read, so
//! [`WebPlayer`] takes source bytes from the outside and hands back mixed
//! frames for an AudioWorklet to consume. Both go through [`PreviewStage`] —
//! a second copy of this chain would drift, and "the preview lies" is the
//! worst bug this app could have.

use crate::chain::{ChainConfig, MasterParams, MixChain};
use crate::dsp::fir::MsFirStage;
use crate::dsp::limiter::{LimiterParams, TruePeakLimiter};
use crate::error::Result;
use crate::mastering::MasteringPlan;
use crate::mix::TrackParams;

/// Everything the meter bridge reports, in linear units (dB conversion is
/// the UI's job).
#[derive(Debug, Clone, Copy, Default)]
pub struct Meters {
    pub peak_l: f32,
    pub peak_r: f32,
    pub lufs_momentary: f32,
    /// Integrated loudness since start or the last seek — what render pass 1
    /// will measure, since playback applies no normalisation gain.
    pub lufs_integrated: f32,
    /// Running true-peak maximum since start/seek, linear.
    pub true_peak: f32,
    pub correlation: f32,
}

/// Mix bus → mastering → limiter → f32, with metering.
pub struct PreviewStage {
    cfg: ChainConfig,
    channels: usize,
    chain: MixChain,
    master: MasterParams,
    mastering: Option<MasteringPlan>,
    limiter: Option<TruePeakLimiter>,
    fir: Option<MsFirStage>,
    ebu: Option<ebur128::EbuR128>,
    stereo: Vec<f64>,
    mastered: Vec<f64>,
    limited: Vec<f64>,
    out: Vec<f32>,
    meters: Meters,
}

fn build_limiter(m: &MasterParams, sample_rate: u32) -> Option<TruePeakLimiter> {
    m.limiter_enabled.then(|| {
        TruePeakLimiter::new(
            LimiterParams {
                ceiling_dbtp: m.ceiling_dbtp,
                ..LimiterParams::default()
            },
            sample_rate,
        )
    })
}

fn build_fir(plan: &Option<MasteringPlan>) -> Option<MsFirStage> {
    plan.as_ref()
        .map(|p| MsFirStage::new(&p.fir_mid, &p.fir_side))
}

/// Meter mode M|I|TRUE_PEAK: momentary for the bar, integrated and running
/// true peak so the user sees what render pass 1 will.
fn make_ebu(sample_rate: u32) -> Option<ebur128::EbuR128> {
    ebur128::EbuR128::new(
        2,
        sample_rate,
        ebur128::Mode::M | ebur128::Mode::I | ebur128::Mode::TRUE_PEAK,
    )
    .ok()
}

impl PreviewStage {
    pub fn new(
        channels: usize,
        sample_rate: u32,
        tracks: &[TrackParams],
        master: MasterParams,
        mastering: Option<MasteringPlan>,
    ) -> PreviewStage {
        let cfg = ChainConfig { sample_rate };
        PreviewStage {
            chain: MixChain::new(tracks, channels, &cfg),
            limiter: build_limiter(&master, sample_rate),
            fir: build_fir(&mastering),
            ebu: make_ebu(sample_rate),
            cfg,
            channels,
            master,
            mastering,
            stereo: Vec::new(),
            mastered: Vec::new(),
            limited: Vec::new(),
            out: Vec::new(),
            meters: Meters::default(),
        }
    }

    pub fn sample_rate(&self) -> u32 {
        self.cfg.sample_rate
    }

    /// Mix one block of interleaved source frames into interleaved stereo
    /// f32, updating the meters.
    pub fn process(&mut self, input: &[f64]) -> &[f32] {
        self.chain.process(input, &mut self.stereo);
        // Same ordering as render pass 2: mix → matching FIRs → true-peak
        // limiter (which catches the mastering gain).
        let block: &[f64] = match &mut self.fir {
            Some(f) => {
                self.mastered.clear();
                f.process(&self.stereo, &mut self.mastered);
                &self.mastered
            }
            None => &self.stereo,
        };
        let block: &[f64] = match &mut self.limiter {
            Some(lim) => {
                self.limited.clear();
                lim.process(block, &mut self.limited);
                &self.limited
            }
            None => block,
        };
        self.out.clear();
        self.out.extend(block.iter().map(|&s| s as f32));
        self.measure();
        &self.out
    }

    fn measure(&mut self) {
        let mut peak_l = 0.0f32;
        let mut peak_r = 0.0f32;
        let mut sum_ll = 0.0f64;
        let mut sum_rr = 0.0f64;
        let mut sum_lr = 0.0f64;
        for fr in self.out.chunks_exact(2) {
            let (l, r) = (fr[0], fr[1]);
            peak_l = peak_l.max(l.abs());
            peak_r = peak_r.max(r.abs());
            sum_ll += (l as f64) * (l as f64);
            sum_rr += (r as f64) * (r as f64);
            sum_lr += (l as f64) * (r as f64);
        }
        self.meters.peak_l = peak_l;
        self.meters.peak_r = peak_r;
        self.meters.correlation = if sum_ll > 0.0 && sum_rr > 0.0 {
            (sum_lr / (sum_ll * sum_rr).sqrt()) as f32
        } else {
            0.0
        };
        if let Some(ebu) = &mut self.ebu {
            if ebu.add_frames_f32(&self.out).is_ok() {
                if let Ok(l) = ebu.loudness_momentary() {
                    self.meters.lufs_momentary = l as f32;
                }
                if let Ok(l) = ebu.loudness_global() {
                    self.meters.lufs_integrated = l as f32;
                }
                if let (Ok(l), Ok(r)) = (ebu.true_peak(0), ebu.true_peak(1)) {
                    self.meters.true_peak = l.max(r) as f32;
                }
            }
        }
    }

    pub fn meters(&self) -> Meters {
        self.meters
    }

    /// Swap in new mix/master parameters without a click: the fresh chain
    /// adopts the old filter state instead of starting from zero.
    pub fn set_params(
        &mut self,
        tracks: &[TrackParams],
        master: MasterParams,
        mastering: Option<MasteringPlan>,
    ) {
        let mut chain = MixChain::new(tracks, self.channels, &self.cfg);
        chain.adopt_state_from(&self.chain);
        self.chain = chain;
        if master != self.master {
            self.master = master;
            self.limiter = build_limiter(&master, self.cfg.sample_rate);
        }
        if mastering != self.mastering {
            self.mastering = mastering;
            self.fir = build_fir(&self.mastering);
        }
    }

    /// Drop all filter state — the signal is about to jump elsewhere.
    /// Integrated loudness restarts too, since it describes one continuous
    /// stretch of programme.
    pub fn reset(&mut self) {
        self.chain.reset();
        if let Some(f) = &mut self.fir {
            f.reset();
        }
        if let Some(lim) = &mut self.limiter {
            lim.reset();
        }
        self.ebu = make_ebu(self.cfg.sample_rate);
        self.meters = Meters::default();
    }
}

/// The browser's player: source bytes in, mixed stereo frames out.
///
/// There is no cpal in wasm and no synchronous read on a `Blob`, so the
/// browser inverts the native arrangement — instead of a decode thread
/// pulling from a file, Dart hands over the bytes it has already sliced and
/// takes back finished frames for an `AudioWorklet` to play. The DSP in
/// between is [`PreviewStage`], the same one the native player uses.
pub struct WebPlayer {
    stage: PreviewStage,
    decoder: crate::wav::FrameDecoder,
    spec: crate::wav::WavSpec,
    frames: Vec<f64>,
    /// Source frames consumed since the last [`seek`](Self::seek), which is
    /// what the playhead is derived from.
    position_frames: u64,
    start_frame: u64,
}

impl WebPlayer {
    pub fn new(
        spec: crate::wav::WavSpec,
        tracks: &[TrackParams],
        master: MasterParams,
        mastering: Option<MasteringPlan>,
        start_frame: u64,
    ) -> WebPlayer {
        WebPlayer {
            stage: PreviewStage::new(
                spec.channels as usize,
                spec.sample_rate,
                tracks,
                master,
                mastering,
            ),
            decoder: crate::wav::FrameDecoder::new(spec),
            spec,
            frames: Vec::new(),
            position_frames: 0,
            start_frame,
        }
    }

    /// Mix the next slice of the `data` chunk. Slices may end mid-frame; the
    /// remainder is carried to the next call.
    pub fn process(&mut self, bytes: &[u8]) -> Result<&[f32]> {
        self.decoder.push(bytes, &mut self.frames)?;
        self.position_frames += (self.frames.len() / self.spec.channels as usize) as u64;
        Ok(self.stage.process(&self.frames))
    }

    /// Playhead in source frames, absolute in the file.
    pub fn position_frames(&self) -> u64 {
        self.start_frame + self.position_frames
    }

    pub fn meters(&self) -> Meters {
        self.stage.meters()
    }

    pub fn set_params(
        &mut self,
        tracks: &[TrackParams],
        master: MasterParams,
        mastering: Option<MasteringPlan>,
    ) {
        self.stage.set_params(tracks, master, mastering);
    }

    /// Jump to `frame`: filter state and the mid-frame remainder both belong
    /// to the old position and must go.
    pub fn seek(&mut self, frame: u64) {
        self.stage.reset();
        self.decoder = crate::wav::FrameDecoder::new(self.spec);
        self.start_frame = frame;
        self.position_frames = 0;
    }
}
