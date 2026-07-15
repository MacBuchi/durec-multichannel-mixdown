//! Streaming RIFF/RF64 WAV reader.
//!
//! RME DUREC recorders write BWF WAV files, switching to RF64 (64-bit sizes)
//! for recordings above 4 GB. Files are never loaded into memory: the header
//! is parsed once, then audio is pulled in blocks of frames and decoded to
//! f64 in the range [-1.0, 1.0).

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use crate::error::{EngineError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleFormat {
    Int,
    Float,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WavSpec {
    pub channels: u16,
    pub sample_rate: u32,
    pub bits_per_sample: u16,
    pub sample_format: SampleFormat,
}

impl WavSpec {
    pub fn bytes_per_sample(&self) -> usize {
        (self.bits_per_sample as usize).div_ceil(8)
    }

    pub fn bytes_per_frame(&self) -> usize {
        self.bytes_per_sample() * self.channels as usize
    }
}

const WAVE_FORMAT_PCM: u16 = 0x0001;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

pub struct WavReader<R: Read + Seek> {
    reader: R,
    spec: WavSpec,
    data_start: u64,
    data_bytes: u64,
    num_frames: u64,
    pos_frames: u64,
    ixml: Option<String>,
}

/// Where to read a recording from: a filesystem path, or (on Unix) a raw
/// file descriptor handed over by the platform — Android's Storage Access
/// Framework never exposes paths, only fds, and DUREC files are far too
/// large to copy. Each engine call consumes one fresh fd (the platform side
/// opens one per call), so no duplication happens here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputHandle {
    Path(String),
    /// Owned raw fd; must be open for reading and seekable.
    Fd(i32),
}

impl InputHandle {
    pub fn open(&self) -> Result<WavReader<BufReader<File>>> {
        match self {
            InputHandle::Path(p) => WavReader::open(p),
            #[cfg(unix)]
            InputHandle::Fd(fd) => {
                use std::os::fd::FromRawFd;
                // Safety: the platform layer hands us exclusive ownership of
                // a freshly opened descriptor.
                let file = unsafe { File::from_raw_fd(*fd) };
                WavReader::new(BufReader::new(file))
            }
            #[cfg(not(unix))]
            InputHandle::Fd(_) => Err(crate::error::EngineError::Encode(
                "fd input is only supported on unix platforms".into(),
            )),
        }
    }
}

impl WavReader<BufReader<File>> {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        Self::new(BufReader::new(File::open(path)?))
    }
}

impl<R: Read + Seek> WavReader<R> {
    pub fn new(mut reader: R) -> Result<Self> {
        let mut magic = [0u8; 4];
        reader.read_exact(&mut magic)?;
        let is_rf64 = match &magic {
            b"RIFF" => false,
            b"RF64" | b"BW64" => true,
            _ => return Err(EngineError::NotWav),
        };

        let mut riff_size = [0u8; 4];
        reader.read_exact(&mut riff_size)?;

        let mut wave = [0u8; 4];
        reader.read_exact(&mut wave)?;
        if &wave != b"WAVE" {
            return Err(EngineError::NotWav);
        }

        let mut ds64_data_size: Option<u64> = None;
        let mut spec: Option<WavSpec> = None;
        let mut data: Option<(u64, u64)> = None; // (start offset, byte length)
        let mut ixml: Option<String> = None;

        loop {
            let mut header = [0u8; 8];
            match reader.read_exact(&mut header) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(e.into()),
            }
            let chunk_id: [u8; 4] = header[0..4].try_into().unwrap();
            let chunk_size32 = u32::from_le_bytes(header[4..8].try_into().unwrap());

            match &chunk_id {
                b"ds64" => {
                    let mut buf = vec![0u8; chunk_size32 as usize];
                    reader.read_exact(&mut buf)?;
                    if buf.len() < 16 {
                        return Err(EngineError::MissingDs64);
                    }
                    ds64_data_size = Some(u64::from_le_bytes(buf[8..16].try_into().unwrap()));
                }
                b"fmt " => {
                    let mut buf = vec![0u8; chunk_size32 as usize];
                    reader.read_exact(&mut buf)?;
                    spec = Some(parse_fmt_chunk(&buf)?);
                }
                b"data" => {
                    let start = reader.stream_position()?;
                    let size = if chunk_size32 == u32::MAX {
                        ds64_data_size.ok_or(EngineError::MissingDs64)?
                    } else {
                        chunk_size32 as u64
                    };
                    data = Some((start, size));
                    // Skip past the audio payload to keep scanning for
                    // metadata chunks (iXML often follows data).
                    let padded = size + (size & 1);
                    if reader.seek(SeekFrom::Current(padded as i64)).is_err() {
                        break;
                    }
                    continue;
                }
                b"iXML" => {
                    let mut buf = vec![0u8; chunk_size32 as usize];
                    reader.read_exact(&mut buf)?;
                    ixml = Some(String::from_utf8_lossy(&buf).into_owned());
                }
                _ => {
                    let padded = chunk_size32 as u64 + (chunk_size32 as u64 & 1);
                    if reader.seek(SeekFrom::Current(padded as i64)).is_err() {
                        break;
                    }
                    continue;
                }
            }
            // Consume the pad byte for odd-sized chunks we read inline.
            if chunk_size32 & 1 == 1 {
                let mut pad = [0u8; 1];
                let _ = reader.read_exact(&mut pad);
            }
            if is_rf64 && ds64_data_size.is_none() {
                // ds64 must be the first chunk in an RF64 file; if the first
                // chunk was something else the file is malformed, but keep
                // scanning — some writers are lenient.
            }
        }

        let spec = spec.ok_or(EngineError::MissingFmt)?;
        let (data_start, data_bytes) = data.ok_or(EngineError::MissingData)?;
        let num_frames = data_bytes / spec.bytes_per_frame() as u64;

        reader.seek(SeekFrom::Start(data_start))?;

        Ok(Self {
            reader,
            spec,
            data_start,
            data_bytes,
            num_frames,
            pos_frames: 0,
            ixml,
        })
    }

    pub fn spec(&self) -> WavSpec {
        self.spec
    }

    pub fn num_frames(&self) -> u64 {
        self.num_frames
    }

    /// Size of the audio payload in bytes.
    pub fn data_bytes(&self) -> u64 {
        self.data_bytes
    }

    pub fn duration_seconds(&self) -> f64 {
        self.num_frames as f64 / self.spec.sample_rate as f64
    }

    pub fn ixml(&self) -> Option<&str> {
        self.ixml.as_deref()
    }

    pub fn pos_frames(&self) -> u64 {
        self.pos_frames
    }

    pub fn seek_to_frame(&mut self, frame: u64) -> Result<()> {
        let frame = frame.min(self.num_frames);
        let byte = self.data_start + frame * self.spec.bytes_per_frame() as u64;
        self.reader.seek(SeekFrom::Start(byte))?;
        self.pos_frames = frame;
        Ok(())
    }

    /// Read up to `max_frames` interleaved frames, decoded to f64 in
    /// [-1.0, 1.0). Returns the number of frames actually read (0 at EOF).
    /// `out` is cleared and refilled.
    pub fn read_frames(&mut self, out: &mut Vec<f64>, max_frames: usize) -> Result<usize> {
        out.clear();
        let remaining = (self.num_frames - self.pos_frames) as usize;
        let frames = max_frames.min(remaining);
        if frames == 0 {
            return Ok(0);
        }

        let bpf = self.spec.bytes_per_frame();
        let mut raw = vec![0u8; frames * bpf];
        self.reader.read_exact(&mut raw)?;
        self.pos_frames += frames as u64;

        let n_samples = frames * self.spec.channels as usize;
        out.reserve(n_samples);

        match (self.spec.sample_format, self.spec.bits_per_sample) {
            (SampleFormat::Int, 16) => {
                for c in raw.chunks_exact(2) {
                    let v = i16::from_le_bytes([c[0], c[1]]);
                    out.push(v as f64 / 32768.0);
                }
            }
            (SampleFormat::Int, 24) => {
                for c in raw.chunks_exact(3) {
                    let v = i32::from_le_bytes([0, c[0], c[1], c[2]]) >> 8;
                    out.push(v as f64 / 8_388_608.0);
                }
            }
            (SampleFormat::Int, 32) => {
                for c in raw.chunks_exact(4) {
                    let v = i32::from_le_bytes([c[0], c[1], c[2], c[3]]);
                    out.push(v as f64 / 2_147_483_648.0);
                }
            }
            (SampleFormat::Float, 32) => {
                for c in raw.chunks_exact(4) {
                    out.push(f32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64);
                }
            }
            (SampleFormat::Float, 64) => {
                for c in raw.chunks_exact(8) {
                    out.push(f64::from_le_bytes(c.try_into().unwrap()));
                }
            }
            (f, b) => {
                return Err(EngineError::UnsupportedFormat(format!("{f:?} {b}-bit")));
            }
        }
        debug_assert_eq!(out.len(), n_samples);
        Ok(frames)
    }
}

fn parse_fmt_chunk(buf: &[u8]) -> Result<WavSpec> {
    if buf.len() < 16 {
        return Err(EngineError::MissingFmt);
    }
    let mut format_tag = u16::from_le_bytes([buf[0], buf[1]]);
    let channels = u16::from_le_bytes([buf[2], buf[3]]);
    let sample_rate = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let bits_per_sample = u16::from_le_bytes([buf[14], buf[15]]);

    if format_tag == WAVE_FORMAT_EXTENSIBLE {
        // Sub-format GUID starts at offset 24; its first two bytes are the
        // effective format tag.
        if buf.len() < 26 {
            return Err(EngineError::UnsupportedFormat(
                "truncated WAVEFORMATEXTENSIBLE".into(),
            ));
        }
        format_tag = u16::from_le_bytes([buf[24], buf[25]]);
    }

    let sample_format = match format_tag {
        WAVE_FORMAT_PCM => SampleFormat::Int,
        WAVE_FORMAT_IEEE_FLOAT => SampleFormat::Float,
        other => {
            return Err(EngineError::UnsupportedFormat(format!(
                "format tag 0x{other:04X}"
            )));
        }
    };

    if channels == 0 || sample_rate == 0 || bits_per_sample == 0 {
        return Err(EngineError::MissingFmt);
    }

    Ok(WavSpec {
        channels,
        sample_rate,
        bits_per_sample,
        sample_format,
    })
}

/// Lightweight metadata of a recording, for file-browser listings.
#[derive(Debug, Clone, PartialEq)]
pub struct ProbeInfo {
    pub channels: u16,
    pub sample_rate: u32,
    pub bits_per_sample: u16,
    pub num_frames: u64,
    pub duration_seconds: f64,
    /// Number of iXML track entries; 0 when the file carries no iXML.
    pub ixml_track_count: u32,
}

/// Probe a recording without touching audio data: [`WavReader::new`] parses
/// only chunk headers (seeking past the payload) and reads iXML inline, so
/// this stays fast even for multi-GB RF64 takes on slow USB media.
pub fn probe(input: &InputHandle) -> Result<ProbeInfo> {
    let reader = input.open()?;
    let spec = reader.spec();
    Ok(ProbeInfo {
        channels: spec.channels,
        sample_rate: spec.sample_rate,
        bits_per_sample: spec.bits_per_sample,
        num_frames: reader.num_frames(),
        duration_seconds: reader.duration_seconds(),
        ixml_track_count: reader
            .ixml()
            .map_or(0, |x| crate::ixml::parse_tracks(x).len() as u32),
    })
}
