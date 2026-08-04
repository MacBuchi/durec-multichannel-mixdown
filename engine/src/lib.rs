//! durecmix-engine — pure DSP and file I/O core for DurecMix.
//!
//! No FFI, no GUI, no network. Everything here is unit-testable on any
//! platform. The `rust` crate (flutter_rust_bridge API layer) is the only
//! consumer.

pub mod analysis;
pub mod chain;
pub mod dsp;
pub mod error;
pub mod ixml;
pub mod mastering;
pub mod mix;
#[cfg(feature = "mp3-any")]
pub mod mp3;
#[cfg(feature = "playback")]
pub mod playback;
pub mod preview;
pub mod reference;
pub mod render;
pub mod session;
pub mod sink;
pub mod wav;

pub use error::{EngineError, Result};

/// Which MP3 encoder this build carries, or `None` if it carries neither.
///
/// Native builds link LAME, the browser links Shine (see [`mp3`]); the two do
/// not produce the same file, so anything that reports on an export has to be
/// able to name the encoder rather than assume it.
pub const MP3_ENCODER: Option<&str> = if cfg!(feature = "mp3") {
    Some("LAME")
} else if cfg!(feature = "mp3-shine") {
    Some("Shine")
} else {
    None
};
