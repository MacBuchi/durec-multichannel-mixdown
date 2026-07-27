//! Two-pass offline render: analysis pass (peak + loudness measurement)
//! followed by a streamed render pass through gain → true-peak limiter →
//! quantise (+ TPDF dither on 16-bit). Files are never loaded into memory,
//! so multi-GB DUREC recordings work on mobile devices.

use std::io::{Read, Seek};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::chain::{ChainConfig, MixChain};
use crate::dsp::dither::TpdfDither;
use crate::dsp::fir::MsFirStage;
use crate::dsp::limiter::{LimiterParams, TruePeakLimiter};
use crate::dsp::linear_to_db;
use crate::error::{EngineError, Result};
use crate::mastering::{design_mastering, MasteringAnalyzer, ReferenceProfile};
use crate::mix::{MixBus, TrackParams};
use crate::sink::{OutputHandle, StereoSink};
use crate::wav::{InputHandle, WavReader};

/// Frames per streamed block (~1.4 s at 48 kHz, ~16 MB for 32 channels f64).
pub const BLOCK_FRAMES: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum LoudnessMode {
    /// No normalisation. If the limiter is also disabled, gain is still
    /// reduced when the mix would clip; with the limiter on, overs are its job.
    None,
    /// Normalise the mix so its sample peak hits the given dBFS value.
    PeakDbfs(f64),
    /// Normalise integrated loudness (EBU R128) to the given LUFS value;
    /// the true-peak limiter catches whatever the gain pushes over the top.
    LufsIntegrated(f64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OutputFormat {
    Wav16,
    Wav24,
    Wav32Float,
    Flac16,
    Flac24,
    /// MP3, CBR 320 kbps (LAME) — parity with the Python tool's exports.
    Mp3,
}

impl OutputFormat {
    pub fn extension(&self) -> &'static str {
        match self {
            OutputFormat::Flac16 | OutputFormat::Flac24 => "flac",
            OutputFormat::Mp3 => "mp3",
            _ => "wav",
        }
    }

    /// Whether TPDF dither applies (16-bit integer quantisation).
    pub fn is_16_bit_int(&self) -> bool {
        matches!(self, OutputFormat::Wav16 | OutputFormat::Flac16)
    }
}

fn default_limiter_enabled() -> bool {
    true
}
fn default_ceiling_dbtp() -> f64 {
    -1.0
}
fn default_dither() -> bool {
    true
}

/// One chosen reference track (path + display name for the UI).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct MasteringReference {
    pub path: String,
    pub name: String,
}

/// Reference-mastering session state. Only `enabled` influences the engine
/// (via the `reference` argument of [`render_io`]); paths and display names
/// are persisted so the UI can restore and re-analyze the chosen
/// references. v3 sessions stored a single `reference_path`/`reference_name`
/// pair; v4 stores the `references` list (multi-reference genre curves) and
/// keeps the legacy fields mirrored to the first entry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct MasteringSettings {
    pub enabled: bool,
    #[serde(default)]
    pub reference_path: String,
    #[serde(default)]
    pub reference_name: String,
    #[serde(default)]
    pub references: Vec<MasteringReference>,
}

impl MasteringSettings {
    /// The reference list with the v3 single-reference fallback applied.
    pub fn normalized_references(&self) -> Vec<MasteringReference> {
        if !self.references.is_empty() {
            self.references.clone()
        } else if !self.reference_path.is_empty() {
            vec![MasteringReference {
                path: self.reference_path.clone(),
                name: self.reference_name.clone(),
            }]
        } else {
            Vec::new()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderSettings {
    pub loudness: LoudnessMode,
    pub format: OutputFormat,
    /// Master true-peak limiter (defaults on; serde defaults keep v1
    /// sessions loadable).
    #[serde(default = "default_limiter_enabled")]
    pub limiter_enabled: bool,
    /// Limiter ceiling in dBTP.
    #[serde(default = "default_ceiling_dbtp")]
    pub ceiling_dbtp: f64,
    /// TPDF dither on word-length reduction (only acts on 16-bit output).
    #[serde(default = "default_dither")]
    pub dither: bool,
    /// First source frame to render (trim-in).
    #[serde(default)]
    pub trim_start_frame: u64,
    /// One-past-last source frame to render (trim-out); `None` = EOF.
    #[serde(default)]
    pub trim_end_frame: Option<u64>,
    /// Linear fade-in length at the trim-in point, in ms.
    #[serde(default)]
    pub fade_in_ms: f64,
    /// Linear fade-out length up to the trim-out point, in ms.
    #[serde(default)]
    pub fade_out_ms: f64,
    /// Reference mastering (v3 sessions; absent in older files).
    #[serde(default)]
    pub mastering: Option<MasteringSettings>,
}

impl Default for RenderSettings {
    fn default() -> Self {
        Self {
            loudness: LoudnessMode::PeakDbfs(-1.0),
            format: OutputFormat::Wav24,
            limiter_enabled: default_limiter_enabled(),
            ceiling_dbtp: default_ceiling_dbtp(),
            dither: default_dither(),
            trim_start_frame: 0,
            trim_end_frame: None,
            fade_in_ms: 0.0,
            fade_out_ms: 0.0,
            mastering: None,
        }
    }
}

/// Linear fade envelope over a trimmed range, applied position-aware to
/// streamed stereo blocks (post-chain, pre-limiter).
struct FadeEnvelope {
    fade_in_frames: u64,
    fade_out_frames: u64,
    total_frames: u64,
}

impl FadeEnvelope {
    fn new(sample_rate: u32, total_frames: u64, fade_in_ms: f64, fade_out_ms: f64) -> Self {
        let to_frames = |ms: f64| ((ms / 1000.0 * sample_rate as f64) as u64).min(total_frames);
        Self {
            fade_in_frames: to_frames(fade_in_ms.max(0.0)),
            fade_out_frames: to_frames(fade_out_ms.max(0.0)),
            total_frames,
        }
    }

    fn is_active(&self) -> bool {
        self.fade_in_frames > 0 || self.fade_out_frames > 0
    }

    /// Applies the envelope to `stereo` given the block's first frame index
    /// relative to the trimmed range.
    fn apply(&self, stereo: &mut [f64], block_start: u64) {
        if !self.is_active() {
            return;
        }
        for (i, fr) in stereo.chunks_exact_mut(2).enumerate() {
            let pos = block_start + i as u64;
            let mut g = 1.0;
            if pos < self.fade_in_frames {
                g *= pos as f64 / self.fade_in_frames as f64;
            }
            let remaining = self.total_frames.saturating_sub(pos);
            if remaining <= self.fade_out_frames {
                g *= remaining.saturating_sub(1) as f64 / self.fade_out_frames as f64;
            }
            fr[0] *= g;
            fr[1] *= g;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderReport {
    /// Sample peak of the raw (pre-normalisation) mix, in dBFS.
    pub peak_dbfs_before: f64,
    /// Gain applied by the normalisation stage, in dB.
    pub gain_applied_db: f64,
    pub duration_seconds: f64,
    pub sample_rate: u32,
    /// Integrated loudness of the delivered file (post-limiter), LUFS.
    pub integrated_lufs: f64,
    /// True peak of the delivered file (post-limiter), dBTP.
    pub true_peak_dbtp: f64,
    /// Loudness range of the delivered file, LU.
    pub lra_lu: f64,
    /// Integrated loudness of the source mix (pre-gain), LUFS.
    pub source_integrated_lufs: f64,
    /// Whether reference mastering was applied to this render.
    #[serde(default)]
    pub mastering_applied: bool,
    /// Overall mid-channel level change of the mastering stage, in dB.
    #[serde(default)]
    pub mastering_gain_db: f64,
}

/// Measure the current mix for reference mastering — render pass 1 without
/// peak/loudness/sink. Same trim/fades as an export, so the stats (and the
/// FIRs designed from them) match what `render_io` would produce. Feeds the
/// live mastering preview.
pub fn analyze_mix_mastering(
    input: &InputHandle,
    tracks: &[TrackParams],
    settings: &RenderSettings,
    progress: impl FnMut(f32),
) -> Result<crate::mastering::MasteringStats> {
    scan_pass1(input, tracks, settings, true, progress)?
        .stats
        .ok_or_else(|| EngineError::Encode("mastering analyzer missing".into()))
}

/// What the export's first pass measures about the level of the mix.
///
/// This is everything the preview needs to play at export level (#113): the
/// normalisation gain is a function of these two numbers and the loudness
/// setting, see [`normalisation_gain`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MixLevel {
    /// Sample peak of the mixed stereo bus, linear.
    pub peak: f64,
    /// Integrated loudness of the mix (EBU R128), in LUFS. `-inf` for
    /// silence, which the gain formula treats as "no gain".
    pub integrated_lufs: f64,
}

/// Measure the mix without producing it — pass 1 with neither the mastering
/// analyzer nor an encoder behind it.
///
/// Costs one read of the trimmed range, the same as the mastering analysis
/// and cheaper by the spectral work it skips.
pub fn analyze_mix_level(
    input: &InputHandle,
    tracks: &[TrackParams],
    settings: &RenderSettings,
    progress: impl FnMut(f32),
) -> Result<MixLevel> {
    let pass1 = scan_pass1(input, tracks, settings, false, progress)?;
    Ok(MixLevel {
        peak: pass1.peak,
        integrated_lufs: pass1.source_lufs,
    })
}

/// Run render pass 1 over the trimmed range and hand back its measurements.
///
/// Shared by the two things that need pass 1 without a render: the mastering
/// analysis and the level scan. `want_analyzer` decides whether the spectral
/// work runs at all.
fn scan_pass1(
    input: &InputHandle,
    tracks: &[TrackParams],
    settings: &RenderSettings,
    want_analyzer: bool,
    mut progress: impl FnMut(f32),
) -> Result<Pass1> {
    let mut reader = input.open()?;
    let spec = reader.spec();
    let num_frames = reader.num_frames();
    let start = settings.trim_start_frame.min(num_frames);
    let end = settings
        .trim_end_frame
        .unwrap_or(num_frames)
        .clamp(start, num_frames);
    let range = end - start;
    let scale = range.max(1) as f64;

    // Exactly render pass 1 — sharing the stage is what keeps the preview's
    // FIRs and gain identical to the export's.
    let mut p1 = RenderPass1::new(
        &RenderSource {
            channels: spec.channels as usize,
            sample_rate: spec.sample_rate,
            tracks,
            range_frames: range,
        },
        settings,
        want_analyzer,
    )?;
    reader.seek_to_frame(start)?;
    let mut buf = Vec::new();
    loop {
        let want = BLOCK_FRAMES.min((range - p1.frames_done()) as usize);
        if want == 0 {
            break;
        }
        if reader.read_frames(&mut buf, want)? == 0 {
            break;
        }
        p1.push_frames(&buf);
        progress((p1.frames_done() as f64 / scale) as f32);
    }
    progress(1.0);
    Ok(p1.finish())
}

/// The two render passes as pushable stages, so the same DSP serves both
/// drivers.
///
/// Natively the driver is [`render_io`], which owns a seekable file and runs
/// both loops itself. In the browser there is no synchronous seek on a
/// `Blob`, so Dart pushes the source blocks instead (mirroring
/// [`analysis::StreamAnalyzer`](crate::analysis::StreamAnalyzer)). Both go
/// through the code below — a second implementation would drift, and the
/// output has to stay bit-identical.
pub struct RenderSource<'a> {
    /// Channel count of the source WAV.
    pub channels: usize,
    pub sample_rate: u32,
    pub tracks: &'a [TrackParams],
    /// Length of the trimmed range — the fade envelope is relative to it.
    pub range_frames: u64,
}

pub struct RenderPass1 {
    chain: MixChain,
    fade: FadeEnvelope,
    ebu_src: ebur128::EbuR128,
    analyzer: Option<MasteringAnalyzer>,
    stereo: Vec<f64>,
    peak: f64,
    done: u64,
}

/// What pass 1 measured; decides the gain and the mastering FIRs.
pub struct Pass1 {
    pub peak: f64,
    pub source_lufs: f64,
    pub stats: Option<crate::mastering::MasteringStats>,
    pub frames: u64,
}

impl RenderPass1 {
    pub fn new(
        src: &RenderSource,
        settings: &RenderSettings,
        with_mastering: bool,
    ) -> Result<RenderPass1> {
        let sample_rate = src.sample_rate;
        Ok(RenderPass1 {
            chain: MixChain::new(src.tracks, src.channels, &ChainConfig { sample_rate }),
            fade: FadeEnvelope::new(
                sample_rate,
                src.range_frames,
                settings.fade_in_ms,
                settings.fade_out_ms,
            ),
            ebu_src: ebur128::EbuR128::new(2, sample_rate, ebur128::Mode::I)
                .map_err(|e| EngineError::Encode(format!("ebur128: {e}")))?,
            analyzer: with_mastering.then(|| MasteringAnalyzer::new(sample_rate)),
            stereo: Vec::new(),
            peak: 0.0,
            done: 0,
        })
    }

    /// Push interleaved source frames (`channels` samples per frame).
    pub fn push_frames(&mut self, input: &[f64]) {
        self.chain.process(input, &mut self.stereo);
        self.fade.apply(&mut self.stereo, self.done);
        for &s in &self.stereo {
            self.peak = self.peak.max(s.abs());
        }
        let _ = self.ebu_src.add_frames_f64(&self.stereo);
        if let Some(an) = &mut self.analyzer {
            an.push(&self.stereo);
        }
        self.done += (self.stereo.len() / 2) as u64;
    }

    pub fn frames_done(&self) -> u64 {
        self.done
    }

    pub fn finish(self) -> Pass1 {
        Pass1 {
            peak: self.peak,
            source_lufs: self.ebu_src.loudness_global().unwrap_or(f64::NEG_INFINITY),
            stats: self.analyzer.map(|a| a.finish()),
            frames: self.done,
        }
    }
}

/// What is decided between the passes: the mastering FIRs (if any) and the
/// normalisation gain.
pub struct RenderPlan {
    pub norm_gain: f64,
    pub mastering: Option<crate::mastering::MasteringPlan>,
}

/// Turn pass 1's measurements into the gain and FIRs pass 2 applies.
///
/// Reference mastering owns the output level — the matching FIRs carry the
/// full gain, so the normalisation stage is bypassed.
pub fn plan_from_pass1(
    settings: &RenderSettings,
    pass1: &Pass1,
    reference: Option<&ReferenceProfile>,
) -> Result<RenderPlan> {
    let mastering = match (&pass1.stats, reference) {
        (Some(stats), Some(profile)) => Some(design_mastering(stats, profile)?),
        _ => None,
    };
    let norm_gain = if mastering.is_some() {
        1.0
    } else {
        normalisation_gain(
            settings,
            MixLevel {
                peak: pass1.peak,
                integrated_lufs: pass1.source_lufs,
            },
        )
    };
    Ok(RenderPlan {
        norm_gain,
        mastering,
    })
}

/// The gain the export puts in front of the limiter, from a measurement of
/// the mix.
///
/// Factored out of [`plan_from_pass1`] so the preview can apply the *same*
/// number (#113): a second implementation of this formula would be a silent
/// way for "what you hear" and "what you get" to drift apart. Mastering is
/// not handled here — it supersedes normalisation, and both call sites decide
/// that above this function.
pub fn normalisation_gain(settings: &RenderSettings, level: MixLevel) -> f64 {
    match settings.loudness {
        LoudnessMode::PeakDbfs(target_db) => {
            if level.peak > 0.0 {
                10f64.powf(target_db / 20.0) / level.peak
            } else {
                1.0
            }
        }
        LoudnessMode::LufsIntegrated(target_lufs) => {
            if level.integrated_lufs.is_finite() {
                10f64.powf((target_lufs - level.integrated_lufs) / 20.0)
            } else {
                1.0
            }
        }
        LoudnessMode::None => {
            // Clip protection is the limiter's job when it is enabled.
            if !settings.limiter_enabled && level.peak > 1.0 {
                1.0 / level.peak
            } else {
                1.0
            }
        }
    }
}

/// Pass 2: mix → normalisation gain → mastering FIR → limiter → measure →
/// encode.
pub struct RenderPass2<W: std::io::Write + Seek> {
    chain: MixChain,
    fade: FadeEnvelope,
    limiter: Option<TruePeakLimiter>,
    ebu_out: ebur128::EbuR128,
    dither: Option<TpdfDither>,
    fir: Option<MsFirStage>,
    sink: StereoSink<W>,
    stereo: Vec<f64>,
    mastered: Vec<f64>,
    limited: Vec<f64>,
    plan: RenderPlan,
    peak_before: f64,
    source_lufs: f64,
    sample_rate: u32,
    done: u64,
}

impl<W: std::io::Write + Seek> RenderPass2<W> {
    pub fn new(
        src: &RenderSource,
        settings: &RenderSettings,
        pass1: &Pass1,
        plan: RenderPlan,
        sink: StereoSink<W>,
    ) -> Result<RenderPass2<W>> {
        let sample_rate = src.sample_rate;
        Ok(RenderPass2 {
            chain: MixChain::new(src.tracks, src.channels, &ChainConfig { sample_rate }),
            fade: FadeEnvelope::new(
                sample_rate,
                src.range_frames,
                settings.fade_in_ms,
                settings.fade_out_ms,
            ),
            limiter: settings.limiter_enabled.then(|| {
                TruePeakLimiter::new(
                    LimiterParams {
                        ceiling_dbtp: settings.ceiling_dbtp,
                        ..LimiterParams::default()
                    },
                    sample_rate,
                )
            }),
            ebu_out: ebur128::EbuR128::new(
                2,
                sample_rate,
                ebur128::Mode::I | ebur128::Mode::LRA | ebur128::Mode::TRUE_PEAK,
            )
            .map_err(|e| EngineError::Encode(format!("ebur128: {e}")))?,
            dither: (settings.dither && settings.format.is_16_bit_int()).then(TpdfDither::default),
            fir: plan
                .mastering
                .as_ref()
                .map(|p| MsFirStage::new(&p.fir_mid, &p.fir_side)),
            sink,
            stereo: Vec::new(),
            mastered: Vec::new(),
            limited: Vec::new(),
            plan,
            peak_before: pass1.peak,
            source_lufs: pass1.source_lufs,
            sample_rate,
            done: 0,
        })
    }

    /// Push interleaved source frames (`channels` samples per frame).
    pub fn push_frames(&mut self, input: &[f64]) -> Result<()> {
        self.chain.process(input, &mut self.stereo);
        self.fade.apply(&mut self.stereo, self.done);
        for s in &mut self.stereo {
            *s *= self.plan.norm_gain;
        }
        self.done += (self.stereo.len() / 2) as u64;
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
        let _ = self.ebu_out.add_frames_f64(block);
        self.sink.write_block(block, self.dither.as_mut())
    }

    pub fn frames_done(&self) -> u64 {
        self.done
    }

    /// Drain the filter tails, close the encoder and report.
    pub fn finish(mut self) -> Result<RenderReport> {
        // Flush order mirrors the chain: the FIR tail still passes through
        // the limiter, then the limiter drains its own delay line.
        if let Some(f) = &mut self.fir {
            self.mastered.clear();
            f.flush(&mut self.mastered);
            let block: &[f64] = match &mut self.limiter {
                Some(lim) => {
                    self.limited.clear();
                    lim.process(&self.mastered, &mut self.limited);
                    &self.limited
                }
                None => &self.mastered,
            };
            let _ = self.ebu_out.add_frames_f64(block);
            self.sink.write_block(block, self.dither.as_mut())?;
        }
        if let Some(lim) = &mut self.limiter {
            self.limited.clear();
            lim.flush(&mut self.limited);
            let _ = self.ebu_out.add_frames_f64(&self.limited);
            self.sink.write_block(&self.limited, self.dither.as_mut())?;
        }
        self.sink.finalize()?;

        let true_peak = self
            .ebu_out
            .true_peak(0)
            .and_then(|l| self.ebu_out.true_peak(1).map(|r| l.max(r)))
            .unwrap_or(0.0);
        Ok(RenderReport {
            peak_dbfs_before: linear_to_db(self.peak_before),
            gain_applied_db: linear_to_db(self.plan.norm_gain),
            duration_seconds: self.done as f64 / self.sample_rate as f64,
            sample_rate: self.sample_rate,
            integrated_lufs: self.ebu_out.loudness_global().unwrap_or(f64::NEG_INFINITY),
            true_peak_dbtp: linear_to_db(true_peak),
            lra_lu: self.ebu_out.loudness_range().unwrap_or(0.0),
            source_integrated_lufs: self.source_lufs,
            mastering_applied: self.plan.mastering.is_some(),
            mastering_gain_db: self.plan.mastering.as_ref().map_or(0.0, |p| p.gain_db),
        })
    }
}

/// Measure the sample peak of the mixed output without writing anything.
pub fn measure_mix_peak<R: Read + Seek>(reader: &mut WavReader<R>, bus: &MixBus) -> Result<f64> {
    reader.seek_to_frame(0)?;
    let mut input = Vec::new();
    let mut stereo = Vec::new();
    let mut peak = 0.0f64;
    loop {
        let n = reader.read_frames(&mut input, BLOCK_FRAMES)?;
        if n == 0 {
            break;
        }
        bus.process(&input, &mut stereo);
        for &s in &stereo {
            peak = peak.max(s.abs());
        }
    }
    Ok(peak)
}

/// Render the mix of `input_path` to a stereo file at `out_path` in the
/// format given by `settings.format` (WAV, FLAC or MP3).
///
/// `progress` receives values in 0.0..=1.0 across both passes.
pub fn render_to_file<P: AsRef<Path>>(
    input_path: P,
    tracks: &[TrackParams],
    settings: &RenderSettings,
    out_path: P,
    progress: impl FnMut(f32),
) -> Result<RenderReport> {
    render_io(
        &InputHandle::Path(input_path.as_ref().to_string_lossy().into_owned()),
        tracks,
        settings,
        None,
        &OutputHandle::Path(out_path.as_ref().to_string_lossy().into_owned()),
        progress,
    )
}

/// [`render_to_file`] over platform handles — paths or raw fds (Android SAF).
///
/// With a `reference` profile, reference mastering replaces the loudness
/// normalisation: pass 1 additionally analyzes the mix, the matching FIRs
/// are designed in between, and pass 2 filters through them before the
/// limiter. Costs no extra pass over the (multi-GB) source.
pub fn render_io(
    input: &InputHandle,
    tracks: &[TrackParams],
    settings: &RenderSettings,
    reference: Option<&ReferenceProfile>,
    output: &OutputHandle,
    mut progress: impl FnMut(f32),
) -> Result<RenderReport> {
    let mut reader = input.open()?;
    let spec = reader.spec();
    let channels = spec.channels as usize;
    let num_frames = reader.num_frames();
    let start = settings.trim_start_frame.min(num_frames);
    let end = settings
        .trim_end_frame
        .unwrap_or(num_frames)
        .clamp(start, num_frames);
    let range = end - start;
    let scale = range.max(1) as f64;
    let mut buf = Vec::new();

    // Pass 1: measure raw mix peak and integrated loudness (with fades, so
    // the measurement describes the delivered signal).
    let src = RenderSource {
        channels,
        sample_rate: spec.sample_rate,
        tracks,
        range_frames: range,
    };
    let mut p1 = RenderPass1::new(&src, settings, reference.is_some())?;
    reader.seek_to_frame(start)?;
    loop {
        let want = BLOCK_FRAMES.min((range - p1.frames_done()) as usize);
        if want == 0 {
            break;
        }
        if reader.read_frames(&mut buf, want)? == 0 {
            break;
        }
        p1.push_frames(&buf);
        progress((p1.frames_done() as f64 / scale * 0.5) as f32);
    }
    let pass1 = p1.finish();

    // With a `reference` profile, reference mastering replaces the loudness
    // normalisation: the FIRs are designed from pass 1's stats, which costs
    // no extra pass over the (multi-GB) source.
    let plan = plan_from_pass1(settings, &pass1, reference)?;

    // Pass 2: mix → gain → mastering → limiter → measure → encode. A fresh
    // chain — filter state must not leak from pass 1.
    let sink = StereoSink::create(output, settings.format, spec.sample_rate)?;
    let mut p2 = RenderPass2::new(&src, settings, &pass1, plan, sink)?;
    reader.seek_to_frame(start)?;
    loop {
        let want = BLOCK_FRAMES.min((range - p2.frames_done()) as usize);
        if want == 0 {
            break;
        }
        if reader.read_frames(&mut buf, want)? == 0 {
            break;
        }
        p2.push_frames(&buf)?;
        progress((0.5 + p2.frames_done() as f64 / scale * 0.5) as f32);
    }
    let report = p2.finish()?;
    progress(1.0);
    Ok(report)
}

/// The whole render driven from outside, byte block by byte block.
///
/// This is what the browser runs: Dart slices the `data` chunk off the
/// `Blob` and pushes it — twice, once per pass, because there is no
/// synchronous seek to rewind with. Everything below is the same
/// [`RenderPass1`]/[`RenderPass2`] the native file loop uses; only the
/// source of the bytes differs.
///
/// The encoded output is not kept: [`push_pass2`](Self::push_pass2) returns
/// each block as it is produced, and the patched header follows from
/// [`finish`](Self::finish). The caller writes `head ++ blocks…`.
/// [`analyze_mix_level`] for the browser: Dart pushes the source blocks
/// because a `Blob` has no synchronous seek.
///
/// The byte-range twin every engine entry point needs on the web — and it is
/// the same [`RenderPass1`] the file-based scan runs, so the two cannot
/// measure different things.
pub struct MixLevelScan {
    decoder: crate::wav::FrameDecoder,
    scratch: Vec<f64>,
    pass: RenderPass1,
}

impl MixLevelScan {
    pub fn new(
        spec: crate::wav::WavSpec,
        range_frames: u64,
        tracks: &[TrackParams],
        settings: &RenderSettings,
    ) -> Result<MixLevelScan> {
        let pass = RenderPass1::new(
            &RenderSource {
                channels: spec.channels as usize,
                sample_rate: spec.sample_rate,
                tracks,
                range_frames,
            },
            settings,
            false,
        )?;
        Ok(MixLevelScan {
            decoder: crate::wav::FrameDecoder::new(spec),
            scratch: Vec::new(),
            pass,
        })
    }

    /// Feed the next slice of the `data` chunk, in file order.
    pub fn push(&mut self, bytes: &[u8]) -> Result<()> {
        self.decoder.push(bytes, &mut self.scratch)?;
        self.pass.push_frames(&self.scratch);
        Ok(())
    }

    /// Frames measured so far — for a progress bar over the pushed range.
    pub fn frames_done(&self) -> u64 {
        self.pass.frames_done()
    }

    pub fn finish(self) -> MixLevel {
        let pass1 = self.pass.finish();
        MixLevel {
            peak: pass1.peak,
            integrated_lufs: pass1.source_lufs,
        }
    }
}

pub struct StreamRender {
    channels: usize,
    sample_rate: u32,
    tracks: Vec<TrackParams>,
    settings: RenderSettings,
    reference: Option<ReferenceProfile>,
    range_frames: u64,
    decoder: crate::wav::FrameDecoder,
    spec: crate::wav::WavSpec,
    scratch: Vec<f64>,
    sink: crate::sink::ChunkSink,
    stage: Stage,
}

enum Stage {
    Pass1(Box<RenderPass1>),
    Pass2(Box<RenderPass2<crate::sink::ChunkSink>>),
    Spent,
}

/// The finished render: `head ++ every block returned by `push_pass2` ++
/// `tail` is the complete file.
pub struct StreamRenderOutput {
    pub head: Vec<u8>,
    pub tail: Vec<u8>,
    pub report: RenderReport,
}

impl StreamRender {
    pub fn new(
        spec: crate::wav::WavSpec,
        range_frames: u64,
        tracks: Vec<TrackParams>,
        settings: RenderSettings,
        reference: Option<ReferenceProfile>,
    ) -> Result<StreamRender> {
        let channels = spec.channels as usize;
        let sample_rate = spec.sample_rate;
        let pass1 = RenderPass1::new(
            &RenderSource {
                channels,
                sample_rate,
                tracks: &tracks,
                range_frames,
            },
            &settings,
            reference.is_some(),
        )?;
        Ok(StreamRender {
            channels,
            sample_rate,
            tracks,
            settings,
            reference,
            range_frames,
            decoder: crate::wav::FrameDecoder::new(spec),
            spec,
            scratch: Vec::new(),
            sink: crate::sink::ChunkSink::new(),
            stage: Stage::Pass1(Box::new(pass1)),
        })
    }

    /// Feed the next slice of the `data` chunk to pass 1, in file order.
    pub fn push_pass1(&mut self, bytes: &[u8]) -> Result<()> {
        let Stage::Pass1(pass) = &mut self.stage else {
            return Err(EngineError::Encode("push_pass1 after pass 1 ended".into()));
        };
        self.decoder.push(bytes, &mut self.scratch)?;
        pass.push_frames(&self.scratch);
        Ok(())
    }

    /// Close pass 1, design the mastering FIRs and gain, open the encoder.
    /// The caller then replays the same byte range through
    /// [`push_pass2`](Self::push_pass2).
    pub fn start_pass2(&mut self) -> Result<()> {
        let stage = std::mem::replace(&mut self.stage, Stage::Spent);
        let Stage::Pass1(pass) = stage else {
            return Err(EngineError::Encode("start_pass2 out of order".into()));
        };
        let measured = pass.finish();
        let plan = plan_from_pass1(&self.settings, &measured, self.reference.as_ref())?;
        let sink = StereoSink::new(self.sink.clone(), self.settings.format, self.sample_rate)?;
        let pass2 = RenderPass2::new(
            &RenderSource {
                channels: self.channels,
                sample_rate: self.sample_rate,
                tracks: &self.tracks,
                range_frames: self.range_frames,
            },
            &self.settings,
            &measured,
            plan,
            sink,
        )?;
        // The byte stream restarts, so the mid-frame remainder must not.
        self.decoder = crate::wav::FrameDecoder::new(self.spec);
        self.stage = Stage::Pass2(Box::new(pass2));
        Ok(())
    }

    /// Feed the next slice to pass 2 and take whatever the encoder produced.
    pub fn push_pass2(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        let Stage::Pass2(pass) = &mut self.stage else {
            return Err(EngineError::Encode("push_pass2 out of order".into()));
        };
        self.decoder.push(bytes, &mut self.scratch)?;
        pass.push_frames(&self.scratch)?;
        Ok(self.sink.take_tail())
    }

    pub fn finish(mut self) -> Result<StreamRenderOutput> {
        let stage = std::mem::replace(&mut self.stage, Stage::Spent);
        let Stage::Pass2(pass) = stage else {
            return Err(EngineError::Encode("finish before pass 2".into()));
        };
        let report = pass.finish()?;
        // finalize() flushed the encoder and patched the header, so both are
        // final only now.
        let tail = self.sink.take_tail();
        Ok(StreamRenderOutput {
            head: self.sink.head(),
            tail,
            report,
        })
    }
}
