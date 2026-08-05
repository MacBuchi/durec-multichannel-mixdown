//! The streaming MP3 writer — one type, two encoders.
//!
//! Native targets encode with LAME (`mp3lame-encoder`), CBR 320 kbps at best
//! quality, for parity with the Python tool's exports. LAME is C with an
//! autotools build and cannot be cross-compiled to `wasm32-unknown-unknown`,
//! which has no libc, so the browser build encodes with Shine
//! (`shine-rs`) — a pure-Rust MPEG Layer III encoder that needs no C at all.
//!
//! **They do not sound the same.** Shine has no psychoacoustic model; it was
//! written for simplicity and fixed-point machines, not for fidelity. At
//! 320 kbps the gap is at its smallest, but it is there, and the UI says so
//! (`mp3EncoderNote` in the Dart platform shim). Which is also why LAME wins
//! wherever LAME builds: the `cfg` below prefers it even if both features
//! are somehow enabled at once, so a native build can never silently ship
//! the lesser encoder.
//!
//! [`sink::StereoSink`](crate::sink::StereoSink) knows only `Mp3Writer` and
//! never learns which encoder is behind it.

use std::io::Write;

use crate::error::Result;
use crate::sink::enc_err;

/// Whether this build's encoder can take `sample_rate`, without building one.
///
/// LAME resamples internally and accepts what it is given; Shine validates
/// against the MPEG rate table and refuses the rest, so this is one of the
/// few places where the two builds genuinely differ in behaviour rather than
/// in sound.
pub(crate) fn validate(sample_rate: u32) -> Result<()> {
    #[cfg(feature = "mp3")]
    {
        let _ = sample_rate;
        Ok(())
    }
    #[cfg(all(feature = "mp3-shine", not(feature = "mp3")))]
    {
        shine_rs::mp3_encoder::Mp3EncoderConfig::new()
            .sample_rate(sample_rate)
            .bitrate(320)
            .channels(2)
            .validate()
            .map_err(|_| {
                crate::error::EngineError::Encode(format!(
                    "this build encodes MP3 with Shine, which has no {sample_rate} Hz mode \
                     (32, 44.1 and 48 kHz work) — export FLAC or WAV for this take"
                ))
            })
    }
}

/// Streaming MP3 writer (LAME, CBR 320 kbps, best quality). LAME takes the
/// float samples directly, so quantisation/dither do not apply here.
#[cfg(feature = "mp3")]
pub struct Mp3Writer<W: Write> {
    file: W,
    encoder: mp3lame_encoder::Encoder,
    left: Vec<f64>,
    right: Vec<f64>,
    out: Vec<u8>,
}

#[cfg(feature = "mp3")]
impl<W: Write> Mp3Writer<W> {
    pub(crate) fn create(file: W, sample_rate: u32) -> Result<Mp3Writer<W>> {
        let mut builder = mp3lame_encoder::Builder::new()
            .ok_or_else(|| crate::error::EngineError::Encode("lame init failed".into()))?;
        builder.set_num_channels(2).map_err(enc_err)?;
        builder.set_sample_rate(sample_rate).map_err(enc_err)?;
        builder
            .set_brate(mp3lame_encoder::Bitrate::Kbps320)
            .map_err(enc_err)?;
        builder
            .set_quality(mp3lame_encoder::Quality::Best)
            .map_err(enc_err)?;
        let encoder = builder.build().map_err(enc_err)?;
        Ok(Mp3Writer {
            file,
            encoder,
            left: Vec::new(),
            right: Vec::new(),
            out: Vec::new(),
        })
    }

    pub(crate) fn write_block(&mut self, stereo: &[f64]) -> Result<()> {
        self.left.clear();
        self.right.clear();
        for fr in stereo.chunks_exact(2) {
            self.left.push(fr[0].clamp(-1.0, 1.0));
            self.right.push(fr[1].clamp(-1.0, 1.0));
        }
        let input = mp3lame_encoder::DualPcm {
            left: self.left.as_slice(),
            right: self.right.as_slice(),
        };
        self.out.clear();
        // LAME writes unchecked when the buffer is empty — reserving the
        // documented worst case is mandatory, not an optimisation.
        self.out
            .reserve(mp3lame_encoder::max_required_buffer_size(self.left.len()));
        self.encoder
            .encode_to_vec(input, &mut self.out)
            .map_err(enc_err)?;
        self.file.write_all(&self.out)?;
        Ok(())
    }

    pub(crate) fn finalize(mut self) -> Result<()> {
        self.out.clear();
        self.out.reserve(7200); // documented minimum for the final flush
        self.encoder
            .flush_to_vec::<mp3lame_encoder::FlushNoGap>(&mut self.out)
            .map_err(enc_err)?;
        self.file.write_all(&self.out)?;
        self.file.flush()?;
        Ok(())
    }
}

/// Streaming MP3 writer for the browser (Shine, CBR 320 kbps).
///
/// Shine takes 16-bit samples, so unlike the LAME path this one quantises.
/// Deliberately without dither: the quantisation noise sits around −96 dBFS,
/// far below anything a lossy encoder at 320 kbps preserves, and dithering
/// into a lossy encoder only spends bits on noise.
#[cfg(all(feature = "mp3-shine", not(feature = "mp3")))]
pub struct Mp3Writer<W: Write> {
    file: W,
    encoder: shine_rs::mp3_encoder::Mp3Encoder,
    pcm: Vec<i16>,
}

/// SAFETY: `Mp3Encoder` is not `Send` because Shine's config struct keeps
/// raw `*mut i16`/`*mut i32` fields — a faithful port of the C original.
/// Those pointers are not owned state: `shine_encode_buffer_interleaved`
/// overwrites them with the caller's PCM pointer on entry and, per its own
/// safety contract, dereferences them only "for the duration of the function
/// call". Between calls they dangle, which is sound as long as nothing reads
/// them — and nothing does, because every entry point reassigns them first.
/// Moving the encoder to another thread is therefore safe under exclusive
/// access, which is how it is held: the bridge keeps every running render in
/// a `Mutex` (`RENDERERS` in `rust/src/api/mixer.rs`), and the writer is
/// never shared, only moved. `Sync` is deliberately NOT claimed.
#[cfg(all(feature = "mp3-shine", not(feature = "mp3")))]
unsafe impl<W: Write + Send> Send for Mp3Writer<W> {}

#[cfg(all(feature = "mp3-shine", not(feature = "mp3")))]
impl<W: Write> Mp3Writer<W> {
    pub(crate) fn create(file: W, sample_rate: u32) -> Result<Mp3Writer<W>> {
        use shine_rs::mp3_encoder::{Mp3Encoder, Mp3EncoderConfig, StereoMode};
        // Plain stereo, and not because joint stereo was weighed and lost:
        // Shine has no M/S transform at all (`mode_ext` is hard-coded to 0),
        // so its "joint stereo" would set a header flag the data does not
        // honour. Naming what actually happens is the safer lie-free option.
        //
        // The cost is measurable and worth knowing: encoding L and R
        // independently means a mono-summed mix does not come back perfectly
        // mono. On a real 34-track take, LAME's output measured −∞ dB of side
        // signal where Shine measured −34 dB. Inaudible in normal listening,
        // but it is why a master belongs in LAME's hands.
        let config = Mp3EncoderConfig::new()
            .sample_rate(sample_rate)
            .bitrate(320)
            .channels(2)
            .stereo_mode(StereoMode::Stereo);
        Ok(Mp3Writer {
            file,
            encoder: Mp3Encoder::new(config).map_err(enc_err)?,
            pcm: Vec::new(),
        })
    }

    pub(crate) fn write_block(&mut self, stereo: &[f64]) -> Result<()> {
        // Shine rejects an empty slice outright, and a render's last block
        // can legitimately be empty.
        if stereo.is_empty() {
            return Ok(());
        }
        self.pcm.clear();
        self.pcm.extend(stereo.iter().map(|&s| {
            (s.clamp(-1.0, 1.0) * 32767.0)
                .round()
                .clamp(-32768.0, 32767.0) as i16
        }));
        // Blocks arrive in whatever size the render pass produces; the
        // encoder buffers the remainder of a frame internally and hands it
        // back on the next call, so nothing has to be carried here.
        for frame in self
            .encoder
            .encode_interleaved(&self.pcm)
            .map_err(enc_err)?
        {
            self.file.write_all(&frame)?;
        }
        Ok(())
    }

    pub(crate) fn finalize(mut self) -> Result<()> {
        // Zero-pads the last partial frame and flushes the bit reservoir.
        let tail = self.encoder.finish().map_err(enc_err)?;
        self.file.write_all(&tail)?;
        self.file.flush()?;
        Ok(())
    }
}
