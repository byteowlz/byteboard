//! Turns an AOSP `.combined` word list into a `.bbd` dictionary.
//!
//! Source format (AOSP LatinIME, extended by Helium314/aosp-dictionaries):
//!
//! ```text
//! dictionary=main:de,locale=de,...
//!  word=der,f=254
//!   bigram=Stadt,f=1
//!  word=Haus,f=180,possibly_offensive=true
//! ```
//!
//! Two scales, easy to confuse:
//! - word `f` is a log-scaled frequency, 15..254, **higher is more common**;
//! - bigram `f` is a **rank, 1 is the most likely** next word (`scripts/wordlist.py` assigns
//!   1 to the most frequent follower and counts up).

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};

use crate::format::*;

#[derive(Debug, Clone)]
pub struct Word {
    pub display: String,
    pub f: u8,
    pub nosuggest: bool,
    /// (next word, rank) — rank 1 is best.
    pub bigrams: Vec<(String, u8)>,
}

#[derive(Debug, Default)]
pub struct Parsed {
    pub locale: String,
    pub words: Vec<Word>,
}

pub fn parse_combined(text: &str) -> Parsed {
    let mut parsed = Parsed::default();
    // Bigram lines belong to the word above them, but only if that word was kept.
    let mut current_kept = false;
    for line in text.lines() {
        let line = line.trim_start();
        if line.starts_with("dictionary=") {
            for field in line.split(',') {
                if let Some(value) = field.strip_prefix("locale=") {
                    parsed.locale = value.trim().to_string();
                }
            }
        } else if let Some(rest) = line.strip_prefix("word=") {
            current_kept = false;
            let (word, attributes) = split_value(rest);
            if word.is_empty() || word.contains(['\t', '\n']) {
                continue;
            }
            let mut f = 0u8;
            let mut nosuggest = false;
            let mut not_a_word = false;
            for field in attributes.split(',') {
                if let Some(value) = field.strip_prefix("f=") {
                    f = value.trim().parse::<u32>().unwrap_or(0).min(255) as u8;
                } else if field == "possibly_offensive=true" {
                    nosuggest = true;
                } else if field == "not_a_word=true" {
                    not_a_word = true;
                }
            }
            // `not_a_word` entries exist only to carry shortcuts.
            if not_a_word {
                continue;
            }
            parsed.words.push(Word { display: word.to_string(), f, nosuggest, bigrams: Vec::new() });
            current_kept = true;
        } else if let Some(rest) = line.strip_prefix("bigram=") {
            if !current_kept {
                continue;
            }
            let (target, attributes) = split_value(rest);
            let mut rank = 0u8;
            for field in attributes.split(',') {
                if let Some(value) = field.strip_prefix("f=") {
                    rank = value.trim().parse::<u32>().unwrap_or(0).min(255) as u8;
                }
            }
            if let Some(word) = parsed.words.last_mut() {
                if !target.is_empty() {
                    word.bigrams.push((target.to_string(), rank));
                }
            }
        }
    }
    parsed
}

/// `value,f=...,more=...` → (`value`, `f=...,more=...`). The value runs up to the first
/// `,f=` because a word may itself contain a comma.
fn split_value(rest: &str) -> (&str, &str) {
    match rest.find(",f=") {
        Some(i) => (&rest[..i], &rest[i + 1..]),
        None => (rest, ""),
    }
}

#[derive(Debug, Clone)]
pub struct BuildOptions {
    /// Keep only the most frequent words. The long tail of a 1.3M-word list is mostly
    /// inflections and noise, and it is what makes a dictionary large on disk.
    pub max_words: usize,
}

impl Default for BuildOptions {
    fn default() -> Self {
        Self { max_words: 250_000 }
    }
}

#[derive(Default)]
struct BuildNode {
    edge: char,
    children: BTreeMap<char, usize>,
    entries: Vec<usize>,
}

pub fn build(locale: &str, mut words: Vec<Word>, options: &BuildOptions) -> Vec<u8> {
    // Most frequent first; the sort is stable so file order breaks ties deterministically.
    words.sort_by(|a, b| b.f.cmp(&a.f));
    let mut seen = HashSet::new();
    words.retain(|w| seen.insert(w.display.clone()));
    words.truncate(options.max_words);

    let index_of: HashMap<&str, usize> =
        words.iter().enumerate().map(|(i, w)| (w.display.as_str(), i)).collect();

    // Trie keyed on the lowercased form. Entries within a node stay frequency-ordered
    // because words were inserted most frequent first.
    let mut nodes = vec![BuildNode { edge: '\0', ..Default::default() }];
    for (word_index, word) in words.iter().enumerate() {
        let mut current = 0usize;
        for ch in word.display.to_lowercase().chars() {
            let existing = nodes[current].children.get(&ch).copied();
            current = match existing {
                Some(next) => next,
                None => {
                    let next = nodes.len();
                    nodes.push(BuildNode { edge: ch, ..Default::default() });
                    nodes[current].children.insert(ch, next);
                    next
                }
            };
        }
        nodes[current].entries.push(word_index);
    }

    // Breadth-first order makes every node's children contiguous.
    let mut order: Vec<usize> = Vec::with_capacity(nodes.len());
    let mut final_index = vec![NONE; nodes.len()];
    let mut queue = VecDeque::from([0usize]);
    final_index[0] = 0;
    order.push(0);
    while let Some(node) = queue.pop_front() {
        for &child in nodes[node].children.values() {
            final_index[child] = order.len() as u32;
            order.push(child);
            queue.push_back(child);
        }
    }

    // Best suggestable frequency anywhere below each node, for best-first search. A node
    // whose subtree holds only no-suggest words gets 0 and is never explored.
    let mut max_f = vec![0u8; nodes.len()];
    for &node in order.iter().rev() {
        let mut best = 0u8;
        for &e in &nodes[node].entries {
            if !words[e].nosuggest {
                best = best.max(words[e].f.max(1));
            }
        }
        for &child in nodes[node].children.values() {
            best = best.max(max_f[child]);
        }
        max_f[node] = best;
    }

    // Entries are laid out node by node, so each node owns a contiguous range.
    let mut entry_order: Vec<usize> = Vec::with_capacity(words.len());
    let mut entry_index = vec![NONE; words.len()];
    let mut node_entry_start = vec![NONE; nodes.len()];
    for &node in &order {
        if nodes[node].entries.is_empty() {
            continue;
        }
        node_entry_start[node] = entry_order.len() as u32;
        for &e in &nodes[node].entries {
            entry_index[e] = entry_order.len() as u32;
            entry_order.push(e);
        }
    }

    let mut bigram_bytes = Vec::new();
    let mut bigram_count = 0u32;
    let mut entry_bigrams: Vec<(u32, u16)> = Vec::with_capacity(entry_order.len());
    for &e in &entry_order {
        let mut targets: Vec<(u32, u8)> = words[e]
            .bigrams
            .iter()
            .filter_map(|(target, rank)| index_of.get(target.as_str()).map(|&t| (entry_index[t], *rank)))
            .collect();
        targets.sort_by_key(|&(_, rank)| rank);
        let start = bigram_count;
        for (target, rank) in &targets {
            bigram_bytes.extend_from_slice(&target.to_le_bytes());
            bigram_bytes.extend_from_slice(&[*rank, 0, 0, 0]);
            bigram_count += 1;
        }
        let count = targets.len().min(u16::MAX as usize) as u16;
        entry_bigrams.push((if count == 0 { NONE } else { start }, count));
    }

    let mut strings = Vec::new();
    let mut entry_bytes = Vec::with_capacity(entry_order.len() * ENTRY_LEN);
    for (position, &e) in entry_order.iter().enumerate() {
        let word = &words[e];
        let offset = strings.len() as u32;
        strings.extend_from_slice(word.display.as_bytes());
        let length = word.display.len().min(u16::MAX as usize) as u16;
        let (bigram_start, bigram_len) = entry_bigrams[position];
        entry_bytes.extend_from_slice(&offset.to_le_bytes());
        entry_bytes.extend_from_slice(&length.to_le_bytes());
        entry_bytes.push(word.f);
        entry_bytes.push(if word.nosuggest { FLAG_NOSUGGEST } else { 0 });
        entry_bytes.extend_from_slice(&bigram_start.to_le_bytes());
        entry_bytes.extend_from_slice(&bigram_len.to_le_bytes());
        entry_bytes.extend_from_slice(&[0, 0]);
    }

    let mut node_bytes = Vec::with_capacity(order.len() * NODE_LEN);
    for &node in &order {
        let n = &nodes[node];
        let first_child = n.children.values().next().map(|&c| final_index[c]).unwrap_or(NONE);
        node_bytes.extend_from_slice(&first_child.to_le_bytes());
        node_bytes.extend_from_slice(&(n.edge as u32).to_le_bytes());
        node_bytes.extend_from_slice(&node_entry_start[node].to_le_bytes());
        node_bytes.extend_from_slice(&(n.children.len().min(u16::MAX as usize) as u16).to_le_bytes());
        node_bytes.extend_from_slice(&(n.entries.len().min(u16::MAX as usize) as u16).to_le_bytes());
        node_bytes.push(max_f[node]);
        node_bytes.extend_from_slice(&[0, 0, 0]);
    }

    let nodes_off = HEADER_LEN;
    let entries_off = nodes_off + node_bytes.len();
    let bigrams_off = entries_off + entry_bytes.len();
    let strings_off = bigrams_off + bigram_bytes.len();

    let mut out = Vec::with_capacity(strings_off + strings.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&(order.len() as u32).to_le_bytes());
    out.extend_from_slice(&(entry_order.len() as u32).to_le_bytes());
    out.extend_from_slice(&bigram_count.to_le_bytes());
    out.extend_from_slice(&(strings.len() as u32).to_le_bytes());
    out.extend_from_slice(&(nodes_off as u32).to_le_bytes());
    out.extend_from_slice(&(entries_off as u32).to_le_bytes());
    out.extend_from_slice(&(bigrams_off as u32).to_le_bytes());
    out.extend_from_slice(&(strings_off as u32).to_le_bytes());
    let mut locale_bytes = [0u8; LOCALE_LEN];
    for (slot, byte) in locale_bytes.iter_mut().zip(locale.bytes()) {
        *slot = byte;
    }
    out.extend_from_slice(&locale_bytes);
    out.resize(HEADER_LEN, 0);
    out.extend_from_slice(&node_bytes);
    out.extend_from_slice(&entry_bytes);
    out.extend_from_slice(&bigram_bytes);
    out.extend_from_slice(&strings);
    out
}
