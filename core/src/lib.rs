//! byteboard-core: word completion, correction and next-word prediction.
//!
//! Shared by the iOS keyboard extension (through the C ABI in `ffi`) and, later, desktop
//! input methods. It has no platform dependencies beyond memory-mapping a file.
//!
//! Dictionaries are compiled offline from AOSP `.combined` word lists (`compile`) into a
//! fixed-record format (`format`) that is memory-mapped and read in place (`dict`). The
//! `engine` merges every enabled language per keystroke.

pub mod compile;
pub mod dict;
pub mod engine;
pub mod ffi;
pub mod format;

pub use dict::{Dict, OpenError};
pub use engine::{Engine, Kind, Suggestion};

#[cfg(test)]
mod tests;
