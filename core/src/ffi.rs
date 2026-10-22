//! C ABI for the iOS keyboard (and any other non-Rust host).
//!
//! Deliberately small and string-based: the host hands over the text before the cursor and
//! gets back newline-separated `kind<TAB>word` lines. Every entry point tolerates null
//! pointers and invalid UTF-8, and no panic crosses the boundary.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::slice;

use crate::dict::Dict;
use crate::engine::Engine;

unsafe fn text<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    if ptr.is_null() {
        return (len == 0).then_some("");
    }
    // SAFETY: the caller guarantees `ptr` is valid for `len` bytes for the duration of the call.
    std::str::from_utf8(unsafe { slice::from_raw_parts(ptr, len) }).ok()
}

#[no_mangle]
pub extern "C" fn bb_engine_new() -> *mut Engine {
    Box::into_raw(Box::new(Engine::new()))
}

/// # Safety
/// `engine` must come from `bb_engine_new` and not be used after this call.
#[no_mangle]
pub unsafe extern "C" fn bb_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// Memory-maps a `.bbd` dictionary and adds it. 0 on success; negative on error
/// (-1 no engine, -2 bad path, -3 unreadable or invalid file, -4 internal failure).
///
/// # Safety
/// `engine` must be live; `path` must be valid for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn bb_engine_add_dict(engine: *mut Engine, path: *const u8, len: usize) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else { return -1 };
    let Some(path) = (unsafe { text(path, len) }) else { return -2 };
    match catch_unwind(AssertUnwindSafe(|| Dict::open(Path::new(path)))) {
        Ok(Ok(dict)) => {
            engine.add(dict);
            0
        }
        Ok(Err(_)) => -3,
        Err(_) => -4,
    }
}

/// Sets the letter rows used for neighbour-key corrections, top row first, separated by
/// `|`, e.g. `qwertzuiop|asdfghjkl|yxcvbnm`.
///
/// # Safety
/// `engine` must be live; `rows` must be valid for `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn bb_engine_set_layout(engine: *mut Engine, rows: *const u8, len: usize) -> i32 {
    let Some(engine) = (unsafe { engine.as_mut() }) else { return -1 };
    let Some(rows) = (unsafe { text(rows, len) }) else { return -2 };
    match catch_unwind(AssertUnwindSafe(|| engine.set_layout(rows))) {
        Ok(()) => 0,
        Err(_) => -4,
    }
}

/// # Safety
/// `engine` must be live or null.
#[no_mangle]
pub unsafe extern "C" fn bb_engine_dict_count(engine: *const Engine) -> u32 {
    unsafe { engine.as_ref() }.map(|e| e.dicts().len() as u32).unwrap_or(0)
}

/// Writes up to `max` suggestions for the text before the cursor into `out` as
/// `kind<TAB>word<LF>` lines, where kind is `c` completion, `x` correction, `n` next word.
///
/// Returns the number of bytes written, or `-(bytes needed)` when `cap` is too small, so the
/// caller can retry with a larger buffer. Returns 0 when there is nothing to suggest, and
/// `isize::MIN` on an internal failure.
///
/// # Safety
/// `engine` must be live; `before` valid for `len` bytes; `out` valid for `cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn bb_engine_suggest(
    engine: *const Engine,
    before: *const u8,
    len: usize,
    max: u32,
    out: *mut u8,
    cap: usize,
) -> isize {
    let Some(engine) = (unsafe { engine.as_ref() }) else { return 0 };
    let Some(before) = (unsafe { text(before, len) }) else { return 0 };
    let Ok(list) = catch_unwind(AssertUnwindSafe(|| engine.suggest(before, max as usize))) else {
        return isize::MIN;
    };
    let mut buffer = String::new();
    for s in list {
        if s.word.contains(['\t', '\n']) {
            continue;
        }
        buffer.push(s.kind.code());
        buffer.push('\t');
        buffer.push_str(&s.word);
        buffer.push('\n');
    }
    let bytes = buffer.as_bytes();
    if bytes.len() > cap || (out.is_null() && !bytes.is_empty()) {
        return -(bytes.len() as isize);
    }
    if !bytes.is_empty() {
        // SAFETY: `out` is valid for `cap` bytes and `bytes.len() <= cap`.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len()) };
    }
    bytes.len() as isize
}
