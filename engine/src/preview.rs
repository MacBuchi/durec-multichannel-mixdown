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
    /// The export's normalisation gain, so what you hear is what you get.
    ///
    /// Without it the preview hands the limiter the raw mix. A DUREC take
    /// sums to roughly +16 dBFS at unity (the recorder also captured monitor
    /// buses), so the limiter would pull ~17 dB continuously while the export
    /// — which lowers the level *before* the limiter — barely engages it.
    /// Same chain, completely different sound. 1.0 until a caller measures
    /// the mix; see [`set_norm_gain`](Self::set_norm_gain).
    norm_gain: f64,
    limiter: Option<TruePeakLimiter>,
    fir: Option<MsFirStage>,
    ebu: Option<ebur128::EbuR128>,
    stereo: Vec<f64>,
    mastered: Vec<f64>,
    limited: Vec<f64>,
    out: Vec<f32>,
    meters: Meters,
    /// Held per-track peaks with meter ballistics (#115), linear, indexed by
    /// source channel. Post-EQ and pre-fader — see [`MixChain::block_peaks`];
    /// the UI multiplies by the fader to get the post-fader reading, so this
    /// serves both modes from one measurement.
    track_peaks: Vec<f32>,
    /// Frames of the start ramp already played; ramping while `< ramp_len`.
    /// Re-armed by [`reset`](Self::reset), i.e. on every start and seek.
    ramp_pos: u64,
    ramp_len: u64,
}

/// Peak-meter release, in dB per second.
///
/// Fast attack (a peak shows immediately), slow release, because a bar that
/// falls as fast as the signal is unreadable — the eye needs the peak to stay
/// long enough to be seen. Chosen at the lively end of the IEC range: at 34
/// bars the alternative is a wall of flicker.
const TRACK_METER_RELEASE_DB_PER_S: f64 = 20.0;

/// Length of the start ramp (#131), in milliseconds.
///
/// Starting or seeking drops the needle mid-waveform, and that first sample
/// is a step — audible as a click even when the mix itself is clean. A short
/// S-ramp (raised cosine) takes it out: zero slope at both ends, so neither
/// the level nor its derivative jumps. 10 ms is long enough to kill the
/// click yet far too short to be heard as a fade-in.
pub const START_RAMP_MS: f64 = 10.0;

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
        let mut chain = MixChain::new(tracks, channels, &cfg);
        chain.enable_metering();
        PreviewStage {
            chain,
            limiter: build_limiter(&master, sample_rate),
            fir: build_fir(&mastering),
            ebu: make_ebu(sample_rate),
            cfg,
            channels,
            master,
            mastering,
            norm_gain: 1.0,
            stereo: Vec::new(),
            mastered: Vec::new(),
            limited: Vec::new(),
            out: Vec::new(),
            meters: Meters::default(),
            track_peaks: vec![0.0; channels],
            ramp_pos: 0,
            ramp_len: (sample_rate as f64 * START_RAMP_MS / 1000.0) as u64,
        }
    }

    pub fn sample_rate(&self) -> u32 {
        self.cfg.sample_rate
    }

    /// Set the normalisation gain the export would apply.
    ///
    /// Deliberately a linear factor and not a loudness target: computing it
    /// needs a measurement over the whole file (render pass 1), which the
    /// caller owns — the preview only ever sees one block at a time.
    /// Mastering supersedes it exactly as in the render, where `norm_gain`
    /// stays 1.0 whenever a mastering plan is active.
    pub fn set_norm_gain(&mut self, gain: f64) {
        self.norm_gain = gain;
    }

    /// What [`process`](Self::process) actually multiplies by.
    ///
    /// Mastering supersedes the normalisation exactly as in the render,
    /// where `norm_gain` stays 1.0 whenever a plan is active. Derived rather
    /// than stored, so switching mastering on and off again restores the
    /// gain instead of losing it.
    pub fn effective_norm_gain(&self) -> f64 {
        if self.mastering.is_some() {
            1.0
        } else {
            self.norm_gain
        }
    }

    /// Mix one block of interleaved source frames into interleaved stereo f32,
    /// updating the bus meters and the per-track meters.
    pub fn process(&mut self, input: &[f64]) -> &[f32] {
        self.chain.process(input, &mut self.stereo);
        // Same ordering as render pass 2: mix → normalisation gain → matching
        // FIRs → true-peak limiter (which catches the mastering gain). The
        // render's fade sits between mix and gain; the preview's only
        // envelope is the start ramp at the very end of this function.
        let gain = self.effective_norm_gain();
        if gain != 1.0 {
            for s in &mut self.stereo {
                *s *= gain;
            }
        }
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
        if self.ramp_pos < self.ramp_len {
            // Start ramp (#131), applied to the finished stream rather than
            // the limiter's input: filters and limiter carry memory, so a
            // ramp upstream would leave the output differing from an
            // un-ramped chain long after the ramp itself. Multiplied in
            // here, the stream is bit-identical to the un-ramped chain from
            // the ramp's last sample on — the preview-equals-render
            // invariant stays checkable — and a gain that only attenuates
            // cannot lift anything over the limiter's ceiling.
            for fr in block.chunks_exact(2) {
                let g = if self.ramp_pos < self.ramp_len {
                    let x = self.ramp_pos as f64 / self.ramp_len as f64;
                    0.5 - 0.5 * (std::f64::consts::PI * x).cos()
                } else {
                    1.0
                };
                self.ramp_pos += 1;
                self.out.push((fr[0] * g) as f32);
                self.out.push((fr[1] * g) as f32);
            }
        } else {
            self.out.extend(block.iter().map(|&s| s as f32));
        }
        self.measure();
        self.hold_track_peaks(input.len() / self.channels.max(1));
        &self.out
    }

    /// Fold this block's per-channel peaks into the held values.
    ///
    /// The release is applied here rather than in the UI because only the
    /// engine knows how much time a block covers — the UI polls on a timer
    /// that says nothing about how far playback advanced.
    fn hold_track_peaks(&mut self, frames: usize) {
        let block = self.chain.block_peaks();
        if block.len() != self.track_peaks.len() {
            // Channel count changed under us (a fresh take): start over
            // rather than read a stale array at the wrong length.
            self.track_peaks = vec![0.0; block.len()];
        }
        let seconds = frames as f64 / self.cfg.sample_rate.max(1) as f64;
        let release = 10f64.powf(-TRACK_METER_RELEASE_DB_PER_S * seconds / 20.0) as f32;
        for (held, &now) in self.track_peaks.iter_mut().zip(block) {
            *held = now.max(*held * release);
        }
    }

    /// Held per-track peaks, linear, indexed by source channel (post-EQ,
    /// pre-fader).
    pub fn track_peaks(&self) -> &[f32] {
        &self.track_peaks
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
        // The fresh chain meters too, or moving one fader would freeze all 34
        // bars — the held values would simply stop being fed.
        chain.enable_metering();
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
        // Held peaks describe the stretch just left behind; after a seek they
        // would sit there as bars for signal that is no longer playing.
        self.track_peaks.fill(0.0);
        // The signal jumps: ramp back in (#131). rewind_to() deliberately
        // stays un-ramped — it re-mixes a continuous stretch, and a dip in
        // the middle of it would be its own artefact.
        self.ramp_pos = 0;
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

    /// Held per-track peaks (#115), linear, by source channel.
    pub fn track_peaks(&self) -> &[f32] {
        self.stage.track_peaks()
    }

    pub fn set_params(
        &mut self,
        tracks: &[TrackParams],
        master: MasterParams,
        mastering: Option<MasteringPlan>,
    ) {
        self.stage.set_params(tracks, master, mastering);
    }

    /// See [`PreviewStage::set_norm_gain`] — the export's gain, so the
    /// preview plays at the level the file will have.
    pub fn set_norm_gain(&mut self, gain: f64) {
        self.stage.set_norm_gain(gain);
    }

    /// Jump to `frame`: filter state and the mid-frame remainder both belong
    /// to the old position and must go.
    pub fn seek(&mut self, frame: u64) {
        self.stage.reset();
        self.decoder = crate::wav::FrameDecoder::new(self.spec);
        self.start_frame = frame;
        self.position_frames = 0;
    }

    /// Produce again from `frame`, **keeping** the chain's filter state.
    ///
    /// The browser mixes ahead into a ring buffer, so changed parameters are
    /// only heard once that buffer drains. The caller drops the stale part
    /// and rewinds here to re-mix it with the new settings — a fraction of a
    /// second back, not a jump.
    ///
    /// [`seek`](Self::seek) would be wrong for that: resetting the biquads
    /// and the limiter is audible, and avoiding exactly that click is the
    /// point of live parameter updates. The filter state kept here belongs
    /// to material a few hundred milliseconds away, which for filters whose
    /// memory is measured in milliseconds is no difference at all.
    ///
    /// The decoder is rebuilt because the caller resumes on a frame
    /// boundary; a carried mid-frame remainder would belong to the dropped
    /// audio.
    pub fn rewind_to(&mut self, frame: u64) {
        self.decoder = crate::wav::FrameDecoder::new(self.spec);
        self.start_frame = frame;
        self.position_frames = 0;
    }
}
