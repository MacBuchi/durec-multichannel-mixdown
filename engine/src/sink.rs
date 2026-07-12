//! Output sinks for the render pass: WAV (hound), FLAC (flacenc,
//! frame-by-frame so multi-hour takes never buffer in RAM), MP3 (LAME, CBR
//! 320 kbps — parity with the Python tool's exports).
//!
//! All sinks consume interleaved stereo f64 blocks in [−1, 1] and own the
//! final quantisation; TPDF dither is applied by the caller's `TpdfDither`
//! on 16-bit integer targets only (FLAC/WAV — MP3 takes float input).

use std::io::{Seek, SeekFrom, Write};
use std::path::Path;

use flacenc::bitsink::ByteSink;
use flacenc::component::BitRepr;
use flacenc::error::Verify;
use flacenc::source::Fill;

use crate::dsp::dither::TpdfDither;
use crate::error::{EngineError, Result};
use crate::render::OutputFormat;

/// FLAC frame size (samples per channel per frame).
const FLAC_BLOCK: usize = 4096;
/// FLAC spec minimum block size (short final blocks are zero-padded up to it).
const FLAC_MIN_BLOCK: usize = 32;

fn enc_err<E: std::fmt::Debug>(e: E) -> EngineError {
    EngineError::Encode(format!("{e:?}"))
}

pub enum StereoSink {
    Wav {
        writer: hound::WavWriter<std::io::BufWriter<std::fs::File>>,
        format: OutputFormat,
    },
    Flac(FlacWriter),
    Mp3(Mp3Writer),
}

impl StereoSink {
    pub fn create(path: &Path, format: OutputFormat, sample_rate: u32) -> Result<StereoSink> {
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
                    writer: hound::WavWriter::create(path, spec).map_err(enc_err)?,
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
                    path,
                    sample_rate,
                    bits,
                )?))
            }
            OutputFormat::Mp3 => Ok(StereoSink::Mp3(Mp3Writer::create(path, sample_rate)?)),
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
            StereoSink::Mp3(m) => m.write_block(stereo),
        }
    }

    pub fn finalize(self) -> Result<()> {
        match self {
            StereoSink::Wav { writer, .. } => writer.finalize().map_err(enc_err),
            StereoSink::Flac(f) => f.finalize(),
            StereoSink::Mp3(m) => m.finalize(),
        }
    }
}

/// Streaming FLAC writer: a placeholder STREAMINFO header is written first,
/// frames are encoded and appended one by one, and the header is patched
/// with the final block/frame statistics on finalize. The MD5 field stays
/// zeroed (= "verification disabled" per spec).
pub struct FlacWriter {
    file: std::io::BufWriter<std::fs::File>,
    config: flacenc::error::Verified<flacenc::config::Encoder>,
    stream_info: flacenc::component::StreamInfo,
    pending: Vec<i32>, // interleaved, quantised
    frame_number: usize,
    bits: usize,
}

impl FlacWriter {
    fn create(path: &Path, sample_rate: u32, bits: usize) -> Result<FlacWriter> {
        let config = flacenc::config::Encoder::default()
            .into_verified()
            .map_err(|(_, e)| enc_err(e))?;
        let stream_info =
            flacenc::component::StreamInfo::new(sample_rate as usize, 2, bits).map_err(enc_err)?;
        let mut file = std::io::BufWriter::new(std::fs::File::create(path)?);
        write_flac_header(&mut file, &stream_info)?;
        Ok(FlacWriter {
            file,
            config,
            stream_info,
            pending: Vec::with_capacity(FLAC_BLOCK * 4),
            frame_number: 0,
            bits,
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
        self.file.write_all(sink.as_slice())?;
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

/// Streaming MP3 writer (LAME, CBR 320 kbps, best quality). LAME takes the
/// float samples directly, so quantisation/dither do not apply here.
pub struct Mp3Writer {
    file: std::io::BufWriter<std::fs::File>,
    encoder: mp3lame_encoder::Encoder,
    left: Vec<f64>,
    right: Vec<f64>,
    out: Vec<u8>,
}

impl Mp3Writer {
    fn create(path: &Path, sample_rate: u32) -> Result<Mp3Writer> {
        let mut builder = mp3lame_encoder::Builder::new()
            .ok_or_else(|| EngineError::Encode("lame init failed".into()))?;
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
            file: std::io::BufWriter::new(std::fs::File::create(path)?),
            encoder,
            left: Vec::new(),
            right: Vec::new(),
            out: Vec::new(),
        })
    }

    fn write_block(&mut self, stereo: &[f64]) -> Result<()> {
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

    fn finalize(mut self) -> Result<()> {
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
