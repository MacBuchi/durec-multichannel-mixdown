//! Live preview playback.
//!
//! Architecture (no allocation or blocking locks on the audio callback):
//!
//! ```text
//! decode thread                     audio callback (cpal)
//! ─────────────                     ─────────────────────
//! WavReader → MixBus → f32 ──rtrb──→ pop → device
//!   ▲ params via Mutex (rebuilt      position/meters via atomics
//!     on epoch bump, read per block)
//! ```
//!
//! Fader/pan/solo changes bump an epoch counter; the decode thread rebuilds
//! its `MixBus` snapshot on the next block, so changes are audible within the
//! ring-buffer latency (~0.2 s). Meters (peak L/R, momentary LUFS,
//! correlation) are computed on the decode thread and published as atomics.
//! The cpal stream is `!Send`, so it lives on a dedicated thread that parks
//! until stop is requested.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::error::{EngineError, Result};
use crate::mix::{MixBus, TrackParams};
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
    correlation: AtomicU32,
}

/// Snapshot of playback state for UI polling.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlayerSnapshot {
    pub playing: bool,
    pub position_frames: u64,
    pub peak_l: f32,
    pub peak_r: f32,
    pub lufs_momentary: f32,
    pub correlation: f32,
}

pub struct Player {
    shared: Arc<SharedState>,
    params: Arc<Mutex<Vec<TrackParams>>>,
    sample_rate: u32,
}

impl Player {
    /// Open `path` and start playing at `start_frame` with the given mix.
    pub fn start(path: &str, tracks: Vec<TrackParams>, start_frame: u64) -> Result<Player> {
        let mut reader = WavReader::open(path)?;
        let spec = reader.spec();
        let channels = spec.channels as usize;
        let sample_rate = spec.sample_rate;
        reader.seek_to_frame(start_frame)?;

        let shared = Arc::new(SharedState {
            seek_to: AtomicU64::new(SEEK_NONE),
            position_frames: AtomicU64::new(start_frame),
            lufs_momentary: AtomicU32::new((-70.0f32).to_bits()),
            ..SharedState::default()
        });
        let params = Arc::new(Mutex::new(tracks));

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

    /// Swap in new track parameters; audible within ring latency.
    pub fn update_tracks(&self, tracks: Vec<TrackParams>) {
        *self.params.lock().unwrap() = tracks;
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
            correlation: f32::from_bits(s.correlation.load(Ordering::Acquire)),
        }
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
    params: Arc<Mutex<Vec<TrackParams>>>,
) -> Result<()> {
    std::thread::Builder::new()
        .name("durecmix-decode".into())
        .spawn(move || {
            let mut bus = MixBus::new(&params.lock().unwrap(), channels);
            let mut seen_epoch = shared.params_epoch.load(Ordering::Acquire);
            let mut ebu = ebur128::EbuR128::new(2, sample_rate, ebur128::Mode::M).ok();
            let mut input: Vec<f64> = Vec::new();
            let mut stereo: Vec<f64> = Vec::new();
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
                }
                let epoch = shared.params_epoch.load(Ordering::Acquire);
                if epoch != seen_epoch {
                    seen_epoch = epoch;
                    bus = MixBus::new(&params.lock().unwrap(), channels);
                }

                let n = reader.read_frames(&mut input, DECODE_BLOCK).unwrap_or(0);
                if n == 0 {
                    shared.eof.store(true, Ordering::Release);
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }

                bus.process(&input, &mut stereo);
                stereo_f32.clear();
                stereo_f32.extend(stereo.iter().map(|&s| s as f32));
                publish_meters(&shared, &stereo_f32, ebu.as_mut());

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
        sample_rate: cpal::SampleRate(sample_rate),
        buffer_size: cpal::BufferSize::Default,
    };
    let cb = Arc::clone(shared);
    device
        .build_output_stream(
            &config,
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

fn publish_meters(shared: &SharedState, stereo: &[f32], ebu: Option<&mut ebur128::EbuR128>) {
    let mut peak_l = 0.0f32;
    let mut peak_r = 0.0f32;
    let mut sum_ll = 0.0f64;
    let mut sum_rr = 0.0f64;
    let mut sum_lr = 0.0f64;
    for fr in stereo.chunks_exact(2) {
        let (l, r) = (fr[0], fr[1]);
        peak_l = peak_l.max(l.abs());
        peak_r = peak_r.max(r.abs());
        sum_ll += (l as f64) * (l as f64);
        sum_rr += (r as f64) * (r as f64);
        sum_lr += (l as f64) * (r as f64);
    }
    let corr = if sum_ll > 0.0 && sum_rr > 0.0 {
        (sum_lr / (sum_ll * sum_rr).sqrt()) as f32
    } else {
        0.0
    };
    shared.peak_l.store(peak_l.to_bits(), Ordering::Release);
    shared.peak_r.store(peak_r.to_bits(), Ordering::Release);
    shared.correlation.store(corr.to_bits(), Ordering::Release);
    if let Some(ebu) = ebu {
        if ebu.add_frames_f32(stereo).is_ok() {
            if let Ok(l) = ebu.loudness_momentary() {
                shared
                    .lufs_momentary
                    .store((l as f32).to_bits(), Ordering::Release);
            }
        }
    }
}
