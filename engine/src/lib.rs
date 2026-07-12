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
pub mod mix;
pub mod playback;
pub mod render;
pub mod session;
pub mod wav;

pub use error::{EngineError, Result};
