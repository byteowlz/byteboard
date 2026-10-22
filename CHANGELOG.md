# Changelog

## Unreleased

Working spike, used on a device.

- Snippets: Espanso match files compiled into the keyboard; static, cursor, date, clipboard,
  form, shell (just-bash) and image snippets; prefix arming for triggers that start longer
  ones; Backspace undo; a searchable list showing what each snippet inserts.
- Prediction: Rust engine with completions, weighted corrections (neighbouring keys,
  diacritics, swaps), accent restoration and bigram next-word, for several languages at once.
- Typing: data-driven layout with number row, long-press alternates, space-bar cursor,
  word delete, auto-capitalisation, double-space period, haptics, near-miss touches going to
  the nearest key, and rollover that keeps fast overlapping taps in order.
- Toolbar in the suggestion slot while nothing is suggested: Pi, snippets, paste, hide.
- @pi agent: PiDurableKit conversation on Apple's on-device model with sessions that survive
  the keyboard being killed, new session, inline markdown, insert and copy, and field,
  clipboard or screenshot-OCR context.
