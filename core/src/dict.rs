//! Read-only access to one `.bbd` dictionary, memory-mapped or owned.

use std::collections::BinaryHeap;
use std::path::Path;

use crate::format::*;

enum Storage {
    Mapped(memmap2::Mmap),
    Owned(Vec<u8>),
}

impl Storage {
    fn bytes(&self) -> &[u8] {
        match self {
            Storage::Mapped(map) => map,
            Storage::Owned(bytes) => bytes,
        }
    }
}

#[derive(Debug)]
pub enum OpenError {
    Io(std::io::Error),
    Format(&'static str),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpenError::Io(error) => write!(f, "{error}"),
            OpenError::Format(reason) => write!(f, "invalid dictionary: {reason}"),
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Node {
    first_child: u32,
    ch: u32,
    entry_start: u32,
    child_count: u16,
    entry_count: u16,
    max_f: u8,
}

#[derive(Clone, Copy, Debug, Default)]
struct Entry {
    str_off: u32,
    str_len: u16,
    f: u8,
    flags: u8,
    bigram_start: u32,
    bigram_count: u16,
}

pub struct Dict {
    storage: Storage,
    locale: String,
    node_count: u32,
    entry_count: u32,
    bigram_count: u32,
    nodes_off: usize,
    entries_off: usize,
    bigrams_off: usize,
    strings_off: usize,
}

/// Bounds how much of the trie a single query may visit, so a pathological input cannot
/// stall a keystroke.
const VISIT_BUDGET: usize = 60_000;

/// The usual ASCII spellings of letters a keyboard may not have. Typing "schoen" for
/// "schön" or "Strasse" for "Straße" is a convention, not a typo, so it costs one cheap edit.
const TRANSLITERATIONS: [(char, char, char); 4] = [('a', 'e', 'ä'), ('o', 'e', 'ö'), ('u', 'e', 'ü'), ('s', 's', 'ß')];

impl Dict {
    pub fn open(path: &Path) -> Result<Dict, OpenError> {
        let file = std::fs::File::open(path).map_err(OpenError::Io)?;
        // SAFETY: the file is a read-only dictionary we ship; it is not modified while mapped.
        let map = unsafe { memmap2::Mmap::map(&file) }.map_err(OpenError::Io)?;
        Self::from_storage(Storage::Mapped(map))
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Result<Dict, OpenError> {
        Self::from_storage(Storage::Owned(bytes))
    }

    fn from_storage(storage: Storage) -> Result<Dict, OpenError> {
        let b = storage.bytes();
        if b.len() < HEADER_LEN || &b[0..4] != MAGIC {
            return Err(OpenError::Format("bad magic"));
        }
        if u32_at(b, H_VERSION) != VERSION {
            return Err(OpenError::Format("unsupported version"));
        }
        let node_count = u32_at(b, H_NODE_COUNT);
        let entry_count = u32_at(b, H_ENTRY_COUNT);
        let bigram_count = u32_at(b, H_BIGRAM_COUNT);
        let strings_len = u32_at(b, H_STRINGS_LEN) as usize;
        let nodes_off = u32_at(b, H_NODES_OFF) as usize;
        let entries_off = u32_at(b, H_ENTRIES_OFF) as usize;
        let bigrams_off = u32_at(b, H_BIGRAMS_OFF) as usize;
        let strings_off = u32_at(b, H_STRINGS_OFF) as usize;

        let fits = |offset: usize, count: u32, size: usize| {
            (count as usize).checked_mul(size).and_then(|n| n.checked_add(offset)).is_some_and(|end| end <= b.len())
        };
        if node_count == 0
            || !fits(nodes_off, node_count, NODE_LEN)
            || !fits(entries_off, entry_count, ENTRY_LEN)
            || !fits(bigrams_off, bigram_count, BIGRAM_LEN)
            || strings_off.checked_add(strings_len).is_none_or(|end| end > b.len())
        {
            return Err(OpenError::Format("section out of bounds"));
        }

        let locale_bytes = &b[H_LOCALE..H_LOCALE + LOCALE_LEN];
        let end = locale_bytes.iter().position(|&c| c == 0).unwrap_or(LOCALE_LEN);
        let locale = String::from_utf8_lossy(&locale_bytes[..end]).into_owned();

        Ok(Dict {
            locale,
            node_count,
            entry_count,
            bigram_count,
            nodes_off,
            entries_off,
            bigrams_off,
            strings_off,
            storage,
        })
    }

    pub fn locale(&self) -> &str {
        &self.locale
    }

    pub fn word_count(&self) -> u32 {
        self.entry_count
    }

    pub fn bigram_count(&self) -> u32 {
        self.bigram_count
    }

    fn bytes(&self) -> &[u8] {
        self.storage.bytes()
    }

    fn node(&self, index: u32) -> Node {
        if index >= self.node_count {
            return Node::default();
        }
        let b = self.bytes();
        let o = self.nodes_off + index as usize * NODE_LEN;
        Node {
            first_child: u32_at(b, o),
            ch: u32_at(b, o + 4),
            entry_start: u32_at(b, o + 8),
            child_count: u16_at(b, o + 12),
            entry_count: u16_at(b, o + 14),
            max_f: u8_at(b, o + 16),
        }
    }

    fn entry(&self, index: u32) -> Entry {
        if index >= self.entry_count {
            return Entry::default();
        }
        let b = self.bytes();
        let o = self.entries_off + index as usize * ENTRY_LEN;
        Entry {
            str_off: u32_at(b, o),
            str_len: u16_at(b, o + 4),
            f: u8_at(b, o + 6),
            flags: u8_at(b, o + 7),
            bigram_start: u32_at(b, o + 8),
            bigram_count: u16_at(b, o + 12),
        }
    }

    /// The word as the dictionary spells it.
    pub fn display(&self, index: u32) -> &str {
        let e = self.entry(index);
        let start = self.strings_off + e.str_off as usize;
        self.bytes()
            .get(start..start + e.str_len as usize)
            .and_then(|s| std::str::from_utf8(s).ok())
            .unwrap_or("")
    }

    pub fn frequency(&self, index: u32) -> u8 {
        self.entry(index).f
    }

    pub fn suggestable(&self, index: u32) -> bool {
        index < self.entry_count && self.entry(index).flags & FLAG_NOSUGGEST == 0
    }

    fn children(&self, node: &Node) -> std::ops::Range<u32> {
        if node.first_child == NONE || node.child_count == 0 {
            return 0..0;
        }
        let end = node.first_child.saturating_add(node.child_count as u32).min(self.node_count);
        node.first_child..end
    }

    fn entries(&self, node: &Node) -> std::ops::Range<u32> {
        if node.entry_start == NONE || node.entry_count == 0 {
            return 0..0;
        }
        let end = node.entry_start.saturating_add(node.entry_count as u32).min(self.entry_count);
        node.entry_start..end
    }

    fn child(&self, node: &Node, ch: char) -> Option<u32> {
        let range = self.children(node);
        let (mut low, mut high) = (range.start, range.end);
        let target = ch as u32;
        while low < high {
            let mid = low + (high - low) / 2;
            let c = self.node(mid).ch;
            match c.cmp(&target) {
                std::cmp::Ordering::Equal => return Some(mid),
                std::cmp::Ordering::Less => low = mid + 1,
                std::cmp::Ordering::Greater => high = mid,
            }
        }
        None
    }

    /// The trie node for an already-lowercased key.
    fn find(&self, key: &str) -> Option<u32> {
        let mut index = 0u32;
        for ch in key.chars() {
            index = self.child(&self.node(index), ch)?;
        }
        Some(index)
    }

    /// Every entry spelled like `key` (lowercased), most frequent first. Includes words
    /// that are never suggested, because they are still valid words.
    pub fn exact(&self, key: &str) -> Vec<u32> {
        match self.find(key) {
            Some(node) => self.entries(&self.node(node)).collect(),
            None => Vec::new(),
        }
    }

    /// The `k` most frequent suggestable words starting with `prefix` (lowercased).
    ///
    /// Best-first over the subtree: a node's priority is the best frequency below it, so
    /// the search pops words in frequency order and stops after `k` without scanning the
    /// whole subtree — "s" has six-figure completions in German.
    pub fn completions(&self, prefix: &str, k: usize) -> Vec<(u32, u8)> {
        let Some(start) = self.find(prefix) else { return Vec::new() };
        // (priority, 1 = word / 0 = node, index). Words beat nodes at equal priority, which
        // is what makes the pop order correct.
        let mut heap: BinaryHeap<(u8, u8, u32)> = BinaryHeap::new();
        heap.push((self.node(start).max_f, 0, start));
        let mut out = Vec::with_capacity(k);
        let mut visits = 0usize;
        while let Some((priority, kind, index)) = heap.pop() {
            if priority == 0 || out.len() >= k || visits >= VISIT_BUDGET {
                break;
            }
            visits += 1;
            if kind == 1 {
                out.push((index, self.frequency(index)));
                continue;
            }
            let node = self.node(index);
            for e in self.entries(&node) {
                let entry = self.entry(e);
                if entry.flags & FLAG_NOSUGGEST == 0 {
                    heap.push((entry.f.max(1), 1, e));
                }
            }
            for c in self.children(&node) {
                let child = self.node(c);
                if child.max_f > 0 {
                    heap.push((child.max_f, 0, c));
                }
            }
        }
        out
    }

    /// Suggestable words within `max_cost` of `query` (lowercased chars), as (entry, cost).
    ///
    /// Weighted optimal-string-alignment distance walked over the trie, pruning any branch
    /// whose best cost already exceeds the budget. `substitution` prices replacing a typed
    /// character with a dictionary one, so neighbouring keys and diacritic swaps can be
    /// cheaper than arbitrary ones. Insertion and deletion cost 2; swapping two adjacent
    /// letters and the two-letter umlaut spellings cost 1.
    pub fn corrections(
        &self,
        query: &[char],
        max_cost: u16,
        substitution: &dyn Fn(char, char) -> u16,
    ) -> Vec<(u32, u16)> {
        let first: Vec<u16> = (0..=query.len()).map(|j| j as u16 * 2).collect();
        let mut walk = Walk {
            dict: self,
            query,
            max_cost,
            substitution,
            rows: vec![first],
            path: Vec::new(),
            out: Vec::new(),
            visits: 0,
        };
        let root = self.node(0);
        for child in self.children(&root) {
            walk.visit(child);
        }
        walk.out
    }

    /// Next-word candidates after `entry`, best first, as (entry, rank).
    pub fn bigrams(&self, entry: u32) -> Vec<(u32, u8)> {
        let e = self.entry(entry);
        if e.bigram_start == NONE || e.bigram_count == 0 {
            return Vec::new();
        }
        let b = self.bytes();
        let end = e.bigram_start.saturating_add(e.bigram_count as u32).min(self.bigram_count);
        (e.bigram_start..end)
            .map(|i| {
                let o = self.bigrams_off + i as usize * BIGRAM_LEN;
                (u32_at(b, o), u8_at(b, o + 4))
            })
            .filter(|&(target, _)| self.suggestable(target))
            .collect()
    }
}

struct Walk<'a> {
    dict: &'a Dict,
    query: &'a [char],
    max_cost: u16,
    substitution: &'a dyn Fn(char, char) -> u16,
    /// rows[i] is the distance row after `i` trie characters.
    rows: Vec<Vec<u16>>,
    /// The trie characters on the current path.
    path: Vec<char>,
    out: Vec<(u32, u16)>,
    visits: usize,
}

impl Walk<'_> {
    fn visit(&mut self, index: u32) {
        if self.visits >= VISIT_BUDGET {
            return;
        }
        self.visits += 1;
        let node = self.dict.node(index);
        let Some(ch) = char::from_u32(node.ch) else { return };
        let n = self.query.len();
        let depth = self.rows.len();
        let prev = &self.rows[depth - 1];
        let mut row = vec![0u16; n + 1];
        row[0] = depth as u16 * 2;
        for j in 1..=n {
            let mut cost = (prev[j] + 2)
                .min(row[j - 1] + 2)
                .min(prev[j - 1] + (self.substitution)(self.query[j - 1], ch));
            // Swapped neighbours ("teh" -> "the"): one finger slip, so a cheap edit. It must
            // fit the one-edit budget a valid prefix gets, or "teh" (the start of "Tehran")
            // never reaches "the".
            if depth >= 2 && j >= 2 && ch == self.query[j - 2] && self.path[depth - 2] == self.query[j - 1] {
                cost = cost.min(self.rows[depth - 2][j - 2] + 1);
            }
            // Two typed letters standing for one ("oe" -> "ö", "ss" -> "ß"): one cheap edit.
            if j >= 2 && TRANSLITERATIONS.iter().any(|&(a, b, c)| c == ch && self.query[j - 2] == a && self.query[j - 1] == b) {
                cost = cost.min(prev[j - 2] + 1);
            }
            row[j] = cost;
        }

        if row[n] <= self.max_cost {
            for e in self.dict.entries(&node) {
                if self.dict.suggestable(e) {
                    self.out.push((e, row[n]));
                }
            }
        }

        // A transposition can still reach back one row, so only stop when both are out of
        // budget.
        let best_here = row.iter().copied().min().unwrap_or(u16::MAX);
        let best_prev = prev.iter().copied().min().unwrap_or(u16::MAX);
        if best_here > self.max_cost && best_prev > self.max_cost {
            return;
        }
        self.rows.push(row);
        self.path.push(ch);
        for child in self.dict.children(&node) {
            self.visit(child);
        }
        self.rows.pop();
        self.path.pop();
    }
}
