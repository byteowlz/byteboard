//! The on-disk dictionary format (`.bbd`), version 1.
//!
//! Designed to be memory-mapped and read in place: every record has a fixed size and every
//! cross-reference is an index, so a lookup touches only the pages it needs. Clean,
//! file-backed pages are not charged to a keyboard extension's footprint the way heap is.
//!
//! All integers are little-endian.
//!
//! ```text
//! header   64 bytes   magic "BBD1", version, counts, section offsets, locale
//! nodes    20 bytes   char trie keyed on the lowercased word, children contiguous and
//!                     sorted by char so they can be binary-searched
//! entries  16 bytes   one per word: display form, frequency, flags, next-word range
//! bigrams   8 bytes   next-word targets as entry indices, best rank first
//! strings  UTF-8      display forms, concatenated
//! ```
//!
//! The trie is keyed on the lowercased form so typing is case-insensitive, while the entry
//! keeps the dictionary's own casing — which matters for German nouns.

pub const MAGIC: &[u8; 4] = b"BBD1";
pub const VERSION: u32 = 1;
pub const HEADER_LEN: usize = 64;
pub const NODE_LEN: usize = 20;
pub const ENTRY_LEN: usize = 16;
pub const BIGRAM_LEN: usize = 8;
pub const LOCALE_LEN: usize = 16;

/// Marks "no index" in u32 fields.
pub const NONE: u32 = u32::MAX;

/// The word is valid but must never be offered (the source marks it `possibly_offensive`).
pub const FLAG_NOSUGGEST: u8 = 1;

// Header field offsets.
pub const H_VERSION: usize = 4;
pub const H_NODE_COUNT: usize = 8;
pub const H_ENTRY_COUNT: usize = 12;
pub const H_BIGRAM_COUNT: usize = 16;
pub const H_STRINGS_LEN: usize = 20;
pub const H_NODES_OFF: usize = 24;
pub const H_ENTRIES_OFF: usize = 28;
pub const H_BIGRAMS_OFF: usize = 32;
pub const H_STRINGS_OFF: usize = 36;
pub const H_LOCALE: usize = 40;

// Reads that never panic: a corrupt or truncated file yields zeros rather than undefined
// behaviour, and the reader bounds every walk by the declared counts.

pub(crate) fn u32_at(b: &[u8], off: usize) -> u32 {
    match b.get(off..off + 4) {
        Some(s) => u32::from_le_bytes([s[0], s[1], s[2], s[3]]),
        None => 0,
    }
}

pub(crate) fn u16_at(b: &[u8], off: usize) -> u16 {
    match b.get(off..off + 2) {
        Some(s) => u16::from_le_bytes([s[0], s[1]]),
        None => 0,
    }
}

pub(crate) fn u8_at(b: &[u8], off: usize) -> u8 {
    b.get(off).copied().unwrap_or(0)
}
