use thiserror::Error;

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("not a RIFF/RF64 WAV file")]
    NotWav,
    #[error("missing fmt chunk")]
    MissingFmt,
    #[error("missing data chunk")]
    MissingData,
    #[error("RF64 file is missing the ds64 chunk")]
    MissingDs64,
    #[error("unsupported sample format: {0}")]
    UnsupportedFormat(String),
    #[error("channel index {index} out of range (file has {channels} channels)")]
    ChannelOutOfRange { index: u32, channels: u16 },
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("WAV encode error: {0}")]
    Encode(String),
    #[error("mastering error: {0}")]
    Mastering(String),
}

pub type Result<T> = std::result::Result<T, EngineError>;
