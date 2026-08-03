//! Live preview playback.
//!
//! Architecture (no allocation or blocking locks on the audio callback):
//!
//! ```text
//! decode thread                     audio callback (cpal)
//! ─────────────                     ─────────────────────
//! WavReader → MixChain → f32 ──rtrb──→ pop → device
//!   ▲ params via Mutex (rebuilt        position/meters via atomics
//!     on epoch bump, read per block)
//! ```
//!
//! Fader/pan/solo/EQ changes bump an epoch counter; the decode thread
//! rebuilds its `MixChain` on the next block (adopting the old filter state,
//! so tweaks are click-free), and changes are audible within the ring-buffer
//! latency (~0.2 s). Meters (peak L/R, momentary LUFS, correlation) are
//! computed on the decode thread and published as atomics.
//! The cpal stream is `!Send`, so it lives on a dedicated thread that parks
//! until stop is requested.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::chain::MasterParams;
use crate::error::{EngineError, Result};
use crate::mastering::MasteringPlan;
use crate::mix::TrackParams;
use crate::preview::PreviewStage;
use crate::wav::WavReader;

const RING_FRAMES: usize = 8192; // ~0.19 s at 44.1 kHz
const DECODE_BLOCK: usize = 2048;
const SEEK_NONE: u64 = u64::MAX;

#[derive(Debug, Default)]
struct SharedState {
    stop: AtomicBool,
    eof: AtomicBool,
    finished: AtomicBool,
    position_frames: AtomicU64,
    seek_to: AtomicU64,
    params_epoch: AtomicU64,
    peak_l: AtomicU32,
    peak_r: AtomicU32,
    lufs_momentary: AtomicU32,
    lufs_integrated: AtomicU32,
    true_peak: AtomicU32,
    correlation: AtomicU32,
    /// Held per-track peaks, one atomic per source channel (#115).
    ///
    /// Meters travel through atomics rather than the params mutex so the
    /// decode thread never blocks; a Vec of them keeps that property for 34
    /// values. Allocated once at start, then only stored into and loaded.
    track_peaks: Vec<AtomicU32>,
}

/// Snapshot of playback state for UI polling.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlayerSnapshot {
    pub playing: bool,
    pub position_frames: u64,
    pub peak_l: f32,
    pub peak_r: f32,
    pub lufs_momentary: f32,
    /// Integrated loudness since start/last seek — what render pass 1 will
    /// measure (playback applies no normalisation gain).
    pub lufs_integrated: f32,
    /// Running true-peak maximum since start/last seek, dBTP-linear.
    pub true_peak: f32,
    pub correlation: f32,
}

/// Live parameters swapped in atomically via epoch bump.
#[derive(Debug, Clone)]
pub struct LiveParams {
    pub tracks: Vec<TrackParams>,
    pub master: MasterParams,
    /// Mastering-preview filters (designed from current mix stats + the
    /// reference profile); `None` plays the plain mix.
    pub mastering: Option<MasteringPlan>,
    /// The export's normalisation gain, so the preview plays at the level
    /// the file will have (#113). 1.0 until the mix has been measured;
    /// mastering supersedes it inside the stage.
    pub norm_gain: f64,
}

pub struct Player {
    shared: Arc<SharedState>,
    params: Arc<Mutex<LiveParams>>,
    sample_rate: u32,
}

impl Player {
    /// Open `path` and start playing at `start_frame` with the given mix,
    /// unnormalised (`norm_gain` 1.0).
    pub fn start(
        path: &str,
        tracks: Vec<TrackParams>,
        master: MasterParams,
        start_frame: u64,
    ) -> Result<Player> {
        Self::start_input(
            &crate::wav::InputHandle::Path(path.into()),
            tracks,
            master,
            None,
            start_frame,
            1.0,
        )
    }

    /// [`Player::start`] over a platform handle — path or raw fd (Android SAF).
    /// `norm_gain` is the export's normalisation gain for this mix (#113):
    /// it belongs to the start call rather than a setter, because the first
    /// decoded block is already audible — adopting the gain afterwards would
    /// play the raw, far louder mix for that block.
    pub fn start_input(
        input: &crate::wav::InputHandle,
        tracks: Vec<TrackParams>,
        master: MasterParams,
        mastering: Option<MasteringPlan>,
        start_frame: u64,
        norm_gain: f64,
    ) -> Result<Player> {
        let mut reader = input.open()?;
        let spec = reader.spec();
        let channels = spec.channels as usize;
        let sample_rate = spec.sample_rate;
        reader.seek_to_frame(start_frame)?;

        let shared = Arc::new(SharedState {
            seek_to: AtomicU64::new(SEEK_NONE),
            position_frames: AtomicU64::new(start_frame),
            lufs_momentary: AtomicU32::new((-70.0f32).to_bits()),
            lufs_integrated: AtomicU32::new((-70.0f32).to_bits()),
            track_peaks: (0..channels).map(|_| AtomicU32::new(0)).collect(),
            ..SharedState::default()
        });
        let params = Arc::new(Mutex::new(LiveParams {
            tracks,
            master,
            mastering,
            norm_gain,
        }));

        let (producer, consumer) = rtrb::RingBuffer::<f32>::new(RING_FRAMES * 2);

        spawn_decode_thread(
            reader,
            channels,
            sample_rate,
            producer,
            Arc::clone(&shared),
            Arc::clone(&params),
        )?;

        // The cpal stream is !Send: build and park it on its own thread.
        let a_shared = Arc::clone(&shared);
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<()>>();
        std::thread::Builder::new()
            .name("durecmix-audio".into())
            .spawn(
                move || match build_stream(sample_rate, &a_shared, consumer) {
                    Ok(stream) => {
                        if let Err(e) = stream.play() {
                            let _ = ready_tx.send(Err(EngineError::Encode(e.to_string())));
                            return;
                        }
                        let _ = ready_tx.send(Ok(()));
                        while !a_shared.stop.load(Ordering::Acquire) {
                            std::thread::sleep(Duration::from_millis(50));
                        }
                        drop(stream);
                    }
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                    }
                },
            )
            .map_err(EngineError::Io)?;

        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Player {
                shared,
                params,
                sample_rate,
            }),
            Ok(Err(e)) => {
                shared.stop.store(true, Ordering::Release);
                Err(e)
            }
            Err(_) => {
                shared.stop.store(true, Ordering::Release);
                Err(EngineError::Encode("audio device did not start".into()))
            }
        }
    }

    pub fn stop(&self) {
        self.shared.stop.store(true, Ordering::Release);
    }

    pub fn seek(&self, frame: u64) {
        self.shared.seek_to.store(frame, Ordering::Release);
    }

    /// Swap in new track/master parameters; audible within ring latency.
    pub fn update_params(
        &self,
        tracks: Vec<TrackParams>,
        master: MasterParams,
        mastering: Option<MasteringPlan>,
        norm_gain: f64,
    ) {
        *self.params.lock().unwrap() = LiveParams {
            tracks,
            master,
            mastering,
            norm_gain,
        };
        self.shared.params_epoch.fetch_add(1, Ordering::AcqRel);
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn snapshot(&self) -> PlayerSnapshot {
        let s = &self.shared;
        PlayerSnapshot {
            playing: !s.finished.load(Ordering::Acquire) && !s.stop.load(Ordering::Acquire),
            position_frames: s.position_frames.load(Ordering::Acquire),
            peak_l: f32::from_bits(s.peak_l.load(Ordering::Acquire)),
            peak_r: f32::from_bits(s.peak_r.load(Ordering::Acquire)),
            lufs_momentary: f32::from_bits(s.lufs_momentary.load(Ordering::Acquire)),
            lufs_integrated: f32::from_bits(s.lufs_integrated.load(Ordering::Acquire)),
            true_peak: f32::from_bits(s.true_peak.load(Ordering::Acquire)),
            correlation: f32::from_bits(s.correlation.load(Ordering::Acquire)),
        }
    }

    /// Held per-track peaks, linear, indexed by source channel (#115).
    ///
    /// Separate from [`snapshot`](Self::snapshot) so that stays `Copy` — the
    /// only per-poll allocation is this Vec, at 34 floats and 30 Hz.
    pub fn track_peaks(&self) -> Vec<f32> {
        self.shared
            .track_peaks
            .iter()
            .map(|a| f32::from_bits(a.load(Ordering::Acquire)))
            .collect()
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.stop();
    }
}

fn spawn_decode_thread(
    mut reader: WavReader<std::io::BufReader<std::fs::File>>,
    channels: usize,
    sample_rate: u32,
    mut producer: rtrb::Producer<f32>,
    shared: Arc<SharedState>,
    params: Arc<Mutex<LiveParams>>,
) -> Result<()> {
    std::thread::Builder::new()
        .name("durecmix-decode".into())
        .spawn(move || {
            let mut stage = {
                let p = params.lock().unwrap();
                let mut s = PreviewStage::new(
                    channels,
                    sample_rate,
                    &p.tracks,
                    p.master,
                    p.mastering.clone(),
                );
                s.set_norm_gain(p.norm_gain);
                s
            };
            let mut seen_epoch = shared.params_epoch.load(Ordering::Acquire);
            let mut input: Vec<f64> = Vec::new();
            let mut stereo_f32: Vec<f32> = Vec::new();

            loop {
                if shared.stop.load(Ordering::Acquire) {
                    return;
                }
                let seek = shared.seek_to.swap(SEEK_NONE, Ordering::AcqRel);
                if seek != SEEK_NONE {
                    let _ = reader.seek_to_frame(seek);
                    shared.position_frames.store(seek, Ordering::Release);
                    shared.eof.store(false, Ordering::Release);
                    shared.finished.store(false, Ordering::Release);
                    // Filter state and integrated loudness belong to the
                    // old position.
                    stage.reset();
                }
                let epoch = shared.params_epoch.load(Ordering::Acquire);
                if epoch != seen_epoch {
                    seen_epoch = epoch;
                    let p = params.lock().unwrap();
                    stage.set_params(&p.tracks, p.master, p.mastering.clone());
                    stage.set_norm_gain(p.norm_gain);
                }

                let n = reader.read_frames(&mut input, DECODE_BLOCK).unwrap_or(0);
                if n == 0 {
                    shared.eof.store(true, Ordering::Release);
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }

                stereo_f32.clear();
                stereo_f32.extend_from_slice(stage.process(&input));
                publish_meters(&shared, stage.meters());
                publish_track_peaks(&shared, stage.track_peaks());

                // Push into the ring, waiting while it is full.
                let mut offset = 0;
                while offset < stereo_f32.len() {
                    if shared.stop.load(Ordering::Acquire) {
                        return;
                    }
                    if shared.seek_to.load(Ordering::Acquire) != SEEK_NONE {
                        break; // abandon this block, handle the seek promptly
                    }
                    let want = (stereo_f32.len() - offset).min(producer.slots());
                    if want > 0 {
                        if let Ok(chunk) = producer.write_chunk_uninit(want) {
                            offset += chunk.fill_from_iter(stereo_f32[offset..].iter().copied());
                        }
                    }
                    if offset < stereo_f32.len() {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                }
            }
        })
        .map_err(EngineError::Io)?;
    Ok(())
}

fn build_stream(
    sample_rate: u32,
    shared: &Arc<SharedState>,
    mut consumer: rtrb::Consumer<f32>,
) -> Result<cpal::Stream> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or_else(|| EngineError::Encode("no audio output device".into()))?;
    let config = cpal::StreamConfig {
        channels: 2,
        // cpal 0.18: SampleRate is a plain u32 alias, no longer a newtype.
        sample_rate,
        buffer_size: cpal::BufferSize::Default,
    };
    let cb = Arc::clone(shared);
    device
        .build_output_stream(
            // cpal 0.18 takes the config by value.
            config,
            move |data: &mut [f32], _| {
                let mut n = 0;
                while n < data.len() {
                    match consumer.pop() {
                        Ok(v) => {
                            data[n] = v;
                            n += 1;
                        }
                        Err(_) => break,
                    }
                }
                data[n..].fill(0.0);
                cb.position_frames
                    .fetch_add((n / 2) as u64, Ordering::AcqRel);
                if n == 0 && cb.eof.load(Ordering::Acquire) {
                    cb.finished.store(true, Ordering::Release);
                }
            },
            |_err| {},
            None,
        )
        .map_err(|e| EngineError::Encode(format!("audio stream: {e}")))
}

/// Store the held per-track peaks. The ballistics already happened in the
/// stage, so this is a plain copy — the UI reads whatever was last written and
/// never has to reset anything, which is what keeps a single writer enough.
fn publish_track_peaks(shared: &SharedState, peaks: &[f32]) {
    for (slot, &pk) in shared.track_peaks.iter().zip(peaks) {
        slot.store(pk.to_bits(), Ordering::Release);
    }
}

fn publish_meters(shared: &SharedState, m: crate::preview::Meters) {
    shared.peak_l.store(m.peak_l.to_bits(), Ordering::Release);
    shared.peak_r.store(m.peak_r.to_bits(), Ordering::Release);
    shared
        .correlation
        .store(m.correlation.to_bits(), Ordering::Release);
    shared
        .lufs_momentary
        .store(m.lufs_momentary.to_bits(), Ordering::Release);
    shared
        .lufs_integrated
        .store(m.lufs_integrated.to_bits(), Ordering::Release);
    shared
        .true_peak
        .store(m.true_peak.to_bits(), Ordering::Release);
}
