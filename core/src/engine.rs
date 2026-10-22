//! Suggestions across every enabled dictionary at once.
//!
//! The caller passes the text before the cursor and gets back up to `max` words. The
//! engine decides the mode itself:
//! - mid-word: completions and corrections of the word being typed;
//! - after a space: next-word predictions from the previous word, unless a sentence just
//!   ended, where the previous word says nothing about what comes next.
//!
//! All dictionaries are queried together, so German and English (or any mix) work without a
//! language switch.

use std::collections::{HashMap, HashSet};

use crate::dict::Dict;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Completion,
    Correction,
    NextWord,
}

impl Kind {
    pub fn code(self) -> char {
        match self {
            Kind::Completion => 'c',
            Kind::Correction => 'x',
            Kind::NextWord => 'n',
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Suggestion {
    pub word: String,
    pub kind: Kind,
    pub score: i32,
}

pub struct Engine {
    dicts: Vec<Dict>,
    neighbours: HashSet<(char, char)>,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

/// Correction is scored by frequency minus this per unit of edit cost. A normal edit costs
/// 2, so one typo costs about as much as a 60-point frequency gap.
const COST_PENALTY: i32 = 30;
/// Corrections get this boost when what was typed is not a word at all.
const UNKNOWN_WORD_BONUS: i32 = 25;
/// Restoring accents to a word that is already valid ("esta" -> "está") is not a typo fix;
/// both are real and often equally likely, so it costs far less than a correction.
const ACCENT_PENALTY: i32 = 10;
/// Candidates from the language the recent words belong to get this boost, so a German
/// sentence prefers German completions and an English one English.
const LANGUAGE_BONUS: i32 = 30;
/// How many words before the cursor decide the language.
const LANGUAGE_WINDOW: usize = 6;

impl Engine {
    pub fn new() -> Self {
        let mut engine = Engine { dicts: Vec::new(), neighbours: HashSet::new() };
        engine.set_layout("qwertyuiop|asdfghjkl|zxcvbnm");
        engine
    }

    pub fn add(&mut self, dict: Dict) {
        self.dicts.push(dict);
    }

    pub fn dicts(&self) -> &[Dict] {
        &self.dicts
    }

    /// Rows of the letter layout separated by `|`, top first. Keys are neighbours when they
    /// touch on the same row or on an adjacent row, accounting for the half-key stagger.
    pub fn set_layout(&mut self, rows: &str) {
        let rows: Vec<Vec<char>> = rows.split('|').map(|r| r.chars().flat_map(char::to_lowercase).collect()).collect();
        let mut neighbours = HashSet::new();
        for (r, row) in rows.iter().enumerate() {
            for (x, &a) in row.iter().enumerate() {
                let ax = x as f32 + r as f32 * 0.5;
                for (r2, row2) in rows.iter().enumerate() {
                    if (r as isize - r2 as isize).abs() > 1 {
                        continue;
                    }
                    for (x2, &b) in row2.iter().enumerate() {
                        if a == b {
                            continue;
                        }
                        let bx = x2 as f32 + r2 as f32 * 0.5;
                        let close = if r == r2 { (ax - bx).abs() <= 1.0 } else { (ax - bx).abs() <= 1.0 };
                        if close {
                            neighbours.insert((a, b));
                        }
                    }
                }
            }
        }
        self.neighbours = neighbours;
    }

    /// Price of the dictionary having `wanted` where the user typed `typed`.
    fn substitution(&self, typed: char, wanted: char) -> u16 {
        if typed == wanted {
            0
        } else if base_letter(typed) == base_letter(wanted) || self.neighbours.contains(&(typed, wanted)) {
            1
        } else {
            2
        }
    }

    pub fn suggest(&self, before: &str, max: usize) -> Vec<Suggestion> {
        if self.dicts.is_empty() || max == 0 {
            return Vec::new();
        }
        let context = Context::parse(before);
        if context.suppressed {
            return Vec::new();
        }
        let bonus = self.language_bonus(&context.recent);
        let mut list = if context.current.is_empty() {
            match &context.previous {
                Some(previous) => self.next_words(previous, &bonus),
                None => Vec::new(),
            }
        } else {
            self.typing(&context.current, &bonus)
        };

        // Casing follows what was typed, then duplicates created by casing collapse.
        if !context.current.is_empty() {
            for s in &mut list {
                s.word = apply_case(&context.current, &s.word);
            }
        }
        list.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.word.cmp(&b.word)));
        // One slot per word regardless of case: "schön" and "Schön" are not two choices.
        let mut seen = HashSet::new();
        list.retain(|s| s.word != context.current && seen.insert(s.word.to_lowercase()));
        list.truncate(max);
        list
    }

    fn typing(&self, current: &str, bonus: &[i32]) -> Vec<Suggestion> {
        let lower = current.to_lowercase();
        let query: Vec<char> = lower.chars().collect();

        let mut pool: HashMap<String, (i32, Kind)> = HashMap::new();
        let mut offer = |word: &str, score: i32, kind: Kind| {
            let slot = pool.entry(word.to_string()).or_insert((i32::MIN, kind));
            if score > slot.0 {
                *slot = (score, kind);
            }
        };

        let mut any_completion = false;
        for (dict, bonus) in self.dicts.iter().zip(bonus) {
            for (entry, f) in dict.completions(&lower, 8) {
                any_completion = true;
                offer(dict.display(entry), f as i32 + bonus, Kind::Completion);
            }
        }

        // Corrections only when the text looks wrong. A real word does not get a different word
        // offered (typing "Haus" must not offer "Aus") — but it can still be missing its
        // accents: "manana" is in the English list, yet "mañana" is what a Spanish writer
        // means. A text that is the valid start of some word is probably right, so it gets one
        // cheap edit only (one neighbour-key slip, one "oe" for "ö"); two would let "graci"
        // reach "track". That also keeps the expensive walks off long, correctly typed words.
        let known = self.dicts.iter().any(|d| !d.exact(&lower).is_empty());
        let max_cost = match query.len() {
            0..=2 => None,
            _ if known => Some(2),
            _ if any_completion => Some(1),
            3..=4 => Some(2),
            _ => Some(3),
        };
        if let Some(max_cost) = max_cost {
            let typed_fold = fold(&lower);
            let substitution = |typed: char, wanted: char| self.substitution(typed, wanted);
            for (dict, bonus) in self.dicts.iter().zip(bonus) {
                for (entry, cost) in dict.corrections(&query, max_cost, &substitution) {
                    let display = dict.display(entry);
                    if known && fold(display) != typed_fold {
                        continue;
                    }
                    let score = if known {
                        dict.frequency(entry) as i32 - ACCENT_PENALTY * cost as i32 + bonus
                    } else {
                        dict.frequency(entry) as i32 - COST_PENALTY * cost as i32 + UNKNOWN_WORD_BONUS + bonus
                    };
                    offer(display, score, Kind::Correction);
                }
            }
        }
        pool.into_iter().map(|(word, (score, kind))| Suggestion { word, kind, score }).collect()
    }

    fn next_words(&self, previous: &str, bonus: &[i32]) -> Vec<Suggestion> {
        let lower = previous.to_lowercase();
        let mut list = Vec::new();
        for (dict, bonus) in self.dicts.iter().zip(bonus) {
            let entries = dict.exact(&lower);
            // Prefer the spelling actually typed ("Arm" the noun, not "arm").
            let Some(&entry) = entries.iter().find(|&&e| dict.display(e) == previous).or(entries.first()) else {
                continue;
            };
            // A word that is common in this language makes its followers more trustworthy:
            // "der" is German first, even though an English list also contains it.
            let weight = dict.frequency(entry) as i32 / 2 + bonus;
            for (target, rank) in dict.bigrams(entry) {
                list.push(Suggestion {
                    word: dict.display(target).to_string(),
                    kind: Kind::NextWord,
                    score: 200 - rank as i32 * 10 + weight,
                });
            }
        }
        list
    }

    /// One bonus per dictionary: the language whose words dominate the recent context gets
    /// `LANGUAGE_BONUS`, everything else 0. No context or a tie means no bonus.
    fn language_bonus(&self, recent: &[String]) -> Vec<i32> {
        let mut fit = vec![0i32; self.dicts.len()];
        for word in recent {
            let lower = word.to_lowercase();
            for (dict, fit) in self.dicts.iter().zip(fit.iter_mut()) {
                if let Some(&entry) = dict.exact(&lower).first() {
                    *fit += dict.frequency(entry) as i32;
                }
            }
        }
        let best = fit.iter().copied().max().unwrap_or(0);
        let leaders = fit.iter().filter(|&&f| f == best).count();
        fit.iter()
            .map(|&f| if best > 0 && leaders == 1 && f == best { LANGUAGE_BONUS } else { 0 })
            .collect()
    }
}

pub(crate) fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '\'' || c == '-'
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Context {
    pub current: String,
    pub previous: Option<String>,
    pub suppressed: bool,
    /// Up to `LANGUAGE_WINDOW` words before the current one, nearest last, used to tell
    /// which language is being written.
    pub recent: Vec<String>,
}

impl Context {
    pub(crate) fn parse(before: &str) -> Context {
        let chars: Vec<char> = before.chars().collect();
        let end = chars.len();
        let mut start = end;
        while start > 0 && is_word_char(chars[start - 1]) {
            start -= 1;
        }
        let current: String = chars[start..end].iter().collect();

        // Identifiers, URLs, paths, mentions and snippet triggers are not prose.
        let suppressed = !current.is_empty()
            && start > 0
            && matches!(chars[start - 1], ':' | '@' | '/' | '#' | '\\' | '_' | '.' | '$');

        let mut i = start;
        let mut newline = false;
        while i > 0 && chars[i - 1].is_whitespace() {
            newline |= chars[i - 1] == '\n';
            i -= 1;
        }
        let sentence_start = i == 0 || newline || matches!(chars[i - 1], '.' | '!' | '?');
        let mut j = i;
        while j > 0 && is_word_char(chars[j - 1]) {
            j -= 1;
        }
        let previous = (!sentence_start && j < i).then(|| chars[j..i].iter().collect());

        let head: String = chars[..start].iter().collect();
        let mut recent: Vec<String> = head
            .split(|c: char| !is_word_char(c))
            .filter(|w| !w.is_empty())
            .map(str::to_string)
            .collect();
        let skip = recent.len().saturating_sub(LANGUAGE_WINDOW);
        recent.drain(..skip);
        Context { current, previous, suppressed, recent }
    }
}

/// The word lowercased with every diacritic removed: "Mañana" and "manana" fold alike.
fn fold(word: &str) -> String {
    word.to_lowercase().chars().map(base_letter).collect()
}

/// The letter with its diacritics removed, so "schon" can correct to "schön" cheaply.
fn base_letter(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ä' | 'ã' | 'å' | 'æ' => 'a',
        'è' | 'é' | 'ê' | 'ë' => 'e',
        'ì' | 'í' | 'î' | 'ï' => 'i',
        'ò' | 'ó' | 'ô' | 'ö' | 'õ' | 'ø' | 'œ' => 'o',
        'ù' | 'ú' | 'û' | 'ü' => 'u',
        'ñ' => 'n',
        'ç' => 'c',
        'ß' => 's',
        'ÿ' => 'y',
        other => other,
    }
}

/// Capitalise like the user: first letter typed upper → first letter upper; whole word typed
/// upper (two or more letters) → whole word upper. The dictionary's own capitals are kept.
pub(crate) fn apply_case(typed: &str, word: &str) -> String {
    let letters: Vec<char> = typed.chars().filter(|c| c.is_alphabetic()).collect();
    if letters.len() >= 2 && letters.iter().all(|c| c.is_uppercase()) {
        return word.to_uppercase();
    }
    if letters.first().is_some_and(|c| c.is_uppercase()) {
        let mut chars = word.chars();
        if let Some(first) = chars.next() {
            return first.to_uppercase().chain(chars).collect();
        }
    }
    word.to_string()
}
