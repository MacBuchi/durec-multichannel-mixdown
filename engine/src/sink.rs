//! Output sinks for the render pass: WAV (hound), FLAC (flacenc,
//! frame-by-frame so multi-hour takes never buffer in RAM), MP3 (CBR
//! 320 kbps — parity with the Python tool's exports; which encoder does the
//! work is [`mp3`](crate::mp3)'s business, not this module's).
//!
//! All sinks consume interleaved stereo f64 blocks in [−1, 1] and own the
//! final quantisation; TPDF dither is applied by the caller's `TpdfDither`
//! on 16-bit integer targets only (FLAC/WAV — the MP3 path does its own).

use std::io::{Seek, SeekFrom, Write};
use std::sync::{Arc, Mutex};

use flacenc::bitsink::ByteSink;
use flacenc::component::BitRepr;
use flacenc::error::Verify;
use flacenc::source::Fill;

use crate::dsp::dither::TpdfDither;
use crate::error::{EngineError, Result};
#[cfg(feature = "mp3-any")]
use crate::mp3::Mp3Writer;
use crate::render::OutputFormat;

/// FLAC frame size (samples per channel per frame).
const FLAC_BLOCK: usize = 4096;
/// FLAC spec minimum block size (short final blocks are zero-padded up to it).
const FLAC_MIN_BLOCK: usize = 32;

pub(crate) fn enc_err<E: std::fmt::Debug>(e: E) -> EngineError {
    EngineError::Encode(format!("{e:?}"))
}

/// Where to write the rendered file: a filesystem path, or (on Unix) a raw
/// writable+seekable file descriptor from the platform (Android SAF
/// `CREATE_DOCUMENT`). One fd per render; ownership transfers here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OutputHandle {
    Path(String),
    Fd(i32),
}

impl OutputHandle {
    fn create_file(&self) -> Result<std::fs::File> {
        match self {
            OutputHandle::Path(p) => Ok(std::fs::File::create(p)?),
            #[cfg(unix)]
            OutputHandle::Fd(fd) => {
                use std::os::fd::FromRawFd;
                // Safety: the platform layer hands us exclusive ownership of
                // a freshly opened descriptor.
                Ok(unsafe { std::fs::File::from_raw_fd(*fd) })
            }
            #[cfg(not(unix))]
            OutputHandle::Fd(_) => Err(EngineError::Encode(
                "fd output is only supported on unix platforms".into(),
            )),
        }
    }
}

/// How many leading bytes stay patchable in a [`ChunkSink`]. Both encoders
/// seek back only into their header (RIFF sizes at 4/40, FLAC STREAMINFO at
/// 8), so a generous fixed window covers them with room to spare.
const CHUNK_HEAD_BYTES: usize = 64 * 1024;

struct ChunkBuffers {
    /// Bytes `[0, CHUNK_HEAD_BYTES)` — kept until the end so the encoder can
    /// seek back and patch its header.
    head: Vec<u8>,
    /// Bytes past the head that have not been taken yet.
    tail: Vec<u8>,
    /// Logical offset of `tail[0]`; grows with every [`ChunkSink::take_tail`].
    tail_start: u64,
    pos: u64,
}

impl Default for ChunkBuffers {
    fn default() -> Self {
        ChunkBuffers {
            head: Vec::new(),
            tail: Vec::new(),
            tail_start: CHUNK_HEAD_BYTES as u64,
            pos: 0,
        }
    }
}

/// A seekable sink that never holds the whole output.
///
/// Targets without a filesystem (the browser) cannot give the encoders the
/// `Write + Seek` file they expect, and buffering a render in memory is out
/// of the question — a 90-minute stereo WAV is ~1.5 GB. This keeps only the
/// patchable header plus the bytes produced since the last
/// [`take_tail`](Self::take_tail); the caller drains it block by block and
/// concatenates `head ++ tail₀ ++ tail₁ ++ …`.
///
/// Seeking backwards is allowed **only inside the header window**; the
/// encoders never do more than that, and a violation is an error rather
/// than silent corruption.
#[derive(Clone, Default)]
pub struct ChunkSink(Arc<Mutex<ChunkBuffers>>);

impl ChunkSink {
    pub fn new() -> ChunkSink {
        ChunkSink::default()
    }

    /// Takes the bytes produced since the previous call.
    ///
    /// Buffering upstream (a `BufWriter`) may hold some back; that is fine,
    /// order is preserved and the remainder arrives with a later call or on
    /// finalize.
    pub fn take_tail(&self) -> Vec<u8> {
        let mut b = self.0.lock().unwrap();
        b.tail_start += b.tail.len() as u64;
        std::mem::take(&mut b.tail)
    }

    /// The header, final only after the sink has been finalized.
    pub fn head(&self) -> Vec<u8> {
        self.0.lock().unwrap().head.clone()
    }
}

impl Write for ChunkSink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut b = self.0.lock().unwrap();
        let mut done = 0usize;

        // The part that still falls inside the patchable header window.
        if b.pos < CHUNK_HEAD_BYTES as u64 {
            let at = b.pos as usize;
            let n = buf.len().min(CHUNK_HEAD_BYTES - at);
            if b.head.len() < at + n {
                b.head.resize(at + n, 0);
            }
            b.head[at..at + n].copy_from_slice(&buf[..n]);
            b.pos += n as u64;
            done = n;
        }
        if done == buf.len() {
            return Ok(done);
        }

        // The rest goes into the drainable tail.
        if b.pos < b.tail_start {
            return Err(std::io::Error::other(
                "ChunkSink: write into already-taken output",
            ));
        }
        let at = (b.pos - b.tail_start) as usize;
        if at > b.tail.len() {
            return Err(std::io::Error::other("ChunkSink: write past the end"));
        }
        let rest = &buf[done..];
        let overlap = rest.len().min(b.tail.len() - at);
        b.tail[at..at + overlap].copy_from_slice(&rest[..overlap]);
        b.tail.extend_from_slice(&rest[overlap..]);
        b.pos += rest.len() as u64;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Seek for ChunkSink {
    fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
        let mut b = self.0.lock().unwrap();
        let end = b.tail_start + b.tail.len() as u64;
        let target = match from {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => b.pos as i64 + n,
            SeekFrom::End(n) => end as i64 + n,
        };
        if target < 0 {
            return Err(std::io::Error::other("ChunkSink: seek before start"));
        }
        let target = target as u64;
        if target < b.tail_start && target >= CHUNK_HEAD_BYTES as u64 {
            return Err(std::io::Error::other(
                "ChunkSink: seek into already-taken output",
            ));
        }
        b.pos = target;
        Ok(target)
    }
}

pub enum StereoSink<W: Write + Seek> {
    Wav {
        writer: hound::WavWriter<W>,
        format: OutputFormat,
    },
    Flac(FlacWriter<W>),
    #[cfg(feature = "mp3-any")]
    Mp3(Mp3Writer<W>),
}

impl StereoSink<std::io::BufWriter<std::fs::File>> {
    /// Render target on a real filesystem (path or SAF fd).
    pub fn create(
        out: &OutputHandle,
        format: OutputFormat,
        sample_rate: u32,
    ) -> Result<StereoSink<std::io::BufWriter<std::fs::File>>> {
        StereoSink::new(
            std::io::BufWriter::new(out.create_file()?),
            format,
            sample_rate,
        )
    }
}

/// Can this build write `format` at `sample_rate`?
///
/// Worth asking before a render starts, because the sink is built at the
/// *end* of pass 1 — in the browser that is a full scan of the source, and
/// finding out afterwards that the target was impossible wastes all of it.
///
/// The answer is not the same everywhere: LAME resamples rates it does not
/// encode natively, Shine refuses them, so a 96 kHz take can export to MP3
/// from the app but not from the browser.
pub fn validate_format(format: OutputFormat, sample_rate: u32) -> Result<()> {
    if format != OutputFormat::Mp3 {
        return Ok(());
    }
    #[cfg(not(feature = "mp3-any"))]
    {
        let _ = sample_rate;
        return Err(EngineError::Encode(
            "MP3 export is not built into this target (no mp3 feature enabled)".into(),
        ));
    }
    #[cfg(feature = "mp3-any")]
    crate::mp3::validate(sample_rate)
}

impl<W: Write + Seek> StereoSink<W> {
    /// Render target over any seekable writer — a file natively, a
    /// [`ChunkSink`] where there is no filesystem.
    pub fn new(file: W, format: OutputFormat, sample_rate: u32) -> Result<StereoSink<W>> {
        match format {
            OutputFormat::Wav16 | OutputFormat::Wav24 | OutputFormat::Wav32Float => {
                let spec = hound::WavSpec {
                    channels: 2,
                    sample_rate,
                    bits_per_sample: match format {
                        OutputFormat::Wav16 => 16,
                        OutputFormat::Wav24 => 24,
                        _ => 32,
                    },
                    sample_format: match format {
                        OutputFormat::Wav32Float => hound::SampleFormat::Float,
                        _ => hound::SampleFormat::Int,
                    },
                };
                Ok(StereoSink::Wav {
                    writer: hound::WavWriter::new(file, spec).map_err(enc_err)?,
                    format,
                })
            }
            OutputFormat::Flac16 | OutputFormat::Flac24 => {
                let bits = if format == OutputFormat::Flac16 {
                    16
                } else {
                    24
                };
                Ok(StereoSink::Flac(FlacWriter::create(
                    file,
                    sample_rate,
                    bits,
                )?))
            }
            #[cfg(feature = "mp3-any")]
            OutputFormat::Mp3 => Ok(StereoSink::Mp3(Mp3Writer::create(file, sample_rate)?)),
            #[cfg(not(feature = "mp3-any"))]
            OutputFormat::Mp3 => Err(EngineError::Encode(
                "MP3 export is not built into this target (no mp3 feature enabled)".into(),
            )),
        }
    }

    /// Append one interleaved stereo block.
    pub fn write_block(
        &mut self,
        stereo: &[f64],
        mut dither: Option<&mut TpdfDither>,
    ) -> Result<()> {
        match self {
            StereoSink::Wav { writer, format } => {
                match format {
                    OutputFormat::Wav16 => {
                        for &s in stereo {
                            let v = s.clamp(-1.0, 1.0) * 32767.0;
                            let v = match &mut dither {
                                Some(d) => v + d.sample(),
                                None => v,
                            };
                            let q = v.round().clamp(-32768.0, 32767.0) as i16;
                            writer.write_sample(q).map_err(enc_err)?;
                        }
                    }
                    OutputFormat::Wav24 => {
                        for &s in stereo {
                            let q = (s.clamp(-1.0, 1.0) * 8_388_607.0).round() as i32;
                            writer.write_sample(q).map_err(enc_err)?;
                        }
                    }
                    _ => {
                        for &s in stereo {
                            writer.write_sample(s as f32).map_err(enc_err)?;
                        }
                    }
                }
                Ok(())
            }
            StereoSink::Flac(f) => f.write_block(stereo, dither),
            #[cfg(feature = "mp3-any")]
            StereoSink::Mp3(m) => m.write_block(stereo),
        }
    }

    pub fn finalize(self) -> Result<()> {
        match self {
            StereoSink::Wav { writer, .. } => writer.finalize().map_err(enc_err),
            StereoSink::Flac(f) => f.finalize(),
            #[cfg(feature = "mp3-any")]
            StereoSink::Mp3(m) => m.finalize(),
        }
    }
}

/// Streaming FLAC writer: a placeholder STREAMINFO header is written first,
/// frames are encoded and appended one by one, and the header is patched
/// with the final block/frame statistics on finalize. The MD5 field stays
/// zeroed (= "verification disabled" per spec).
pub struct FlacWriter<W: Write + Seek> {
    file: W,
    config: flacenc::error::Verified<flacenc::config::Encoder>,
    stream_info: flacenc::component::StreamInfo,
    pending: Vec<i32>, // interleaved, quantised
    frame_number: usize,
    bits: usize,
    wrote_full_block: bool,
}

impl<W: Write + Seek> FlacWriter<W> {
    fn create(file: W, sample_rate: u32, bits: usize) -> Result<FlacWriter<W>> {
        let config = flacenc::config::Encoder::default()
            .into_verified()
            .map_err(|(_, e)| enc_err(e))?;
        let stream_info =
            flacenc::component::StreamInfo::new(sample_rate as usize, 2, bits).map_err(enc_err)?;
        let mut file = file;
        write_flac_header(&mut file, &stream_info)?;
        Ok(FlacWriter {
            file,
            config,
            stream_info,
            pending: Vec::with_capacity(FLAC_BLOCK * 4),
            frame_number: 0,
            bits,
            wrote_full_block: false,
        })
    }

    fn write_block(&mut self, stereo: &[f64], mut dither: Option<&mut TpdfDither>) -> Result<()> {
        let full = if self.bits == 16 {
            32767.0
        } else {
            8_388_607.0
        };
        for &s in stereo {
            let v = s.clamp(-1.0, 1.0) * full;
            let v = match (&mut dither, self.bits) {
                (Some(d), 16) => v + d.sample(),
                _ => v,
            };
            self.pending.push(v.round().clamp(-full - 1.0, full) as i32);
        }
        while self.pending.len() >= FLAC_BLOCK * 2 {
            let rest = self.pending.split_off(FLAC_BLOCK * 2);
            let chunk = std::mem::replace(&mut self.pending, rest);
            self.encode_frame(&chunk, FLAC_BLOCK)?;
            self.wrote_full_block = true;
        }
        Ok(())
    }

    fn encode_frame(&mut self, interleaved: &[i32], frames: usize) -> Result<()> {
        let mut fb = flacenc::source::FrameBuf::with_size(2, frames).map_err(enc_err)?;
        fb.fill_interleaved(interleaved).map_err(enc_err)?;
        let frame = flacenc::encode_fixed_size_frame(
            &self.config,
            &fb,
            self.frame_number,
            &self.stream_info,
        )
        .map_err(enc_err)?;
        self.stream_info.update_frame_info(&frame);
        let mut sink = ByteSink::new();
        frame.write(&mut sink).map_err(enc_err)?;
        self.file.write_all(sink.as_slice())?;
        self.frame_number += 1;
        Ok(())
    }

    fn finalize(mut self) -> Result<()> {
        if !self.pending.is_empty() {
            let mut tail = std::mem::take(&mut self.pending);
            // The FLAC spec forbids blocks shorter than 32 samples; pad the
            // rare sub-32-sample tail with silence.
            while tail.len() < FLAC_MIN_BLOCK * 2 {
                tail.push(0);
            }
            let frames = tail.len() / 2;
            self.encode_frame(&tail, frames)?;
        }
        // Patch the STREAMINFO written at offset 8 with the final statistics.
        self.file.seek(SeekFrom::Start(8))?;
        let mut sink = ByteSink::new();
        self.stream_info.write(&mut sink).map_err(enc_err)?;
        let mut body = sink.as_slice().to_vec();
        // flacenc counts a short final frame into min_blocksize, but the
        // FLAC spec excludes the last frame from that bound: a
        // fixed-blocksize stream must report min == max, and strict decoders
        // (e.g. Symphonia) refuse to sync on the frames otherwise.
        if self.wrote_full_block && body.len() >= 4 {
            body[0] = (FLAC_BLOCK >> 8) as u8;
            body[1] = (FLAC_BLOCK & 0xff) as u8;
        }
        self.file.write_all(&body)?;
        self.file.flush()?;
        Ok(())
    }
}

fn write_flac_header<W: Write>(w: &mut W, info: &flacenc::component::StreamInfo) -> Result<()> {
    w.write_all(b"fLaC")?;
    let mut sink = ByteSink::new();
    info.write(&mut sink).map_err(enc_err)?;
    let body = sink.as_slice();
    // Metadata block header: last-block flag + type 0 (STREAMINFO), 24-bit size.
    w.write_all(&[0x80, 0, 0, body.len() as u8])?;
    w.write_all(body)?;
    Ok(())
}
