# byteboard

An iOS keyboard for byteowlz: snippet expansion, multilingual word prediction and an
on-device agent, built as a keyboard extension plus a containing app over a shared Rust core.

## Status

Pre-alpha. Everything lives in a working spike (`spike/keyboard-probe/`) that is used daily
on a device and measured as it grows. Not on the App Store; you build and sign it yourself.

What works today:

- **Snippets:** Espanso match files compiled into the keyboard. Static, cursor, date,
  clipboard, form and shell snippets (shell via just-bash, a sandboxed bash in JavaScript),
  undo with Backspace, and a searchable snippet list.
- **Prediction:** completions, corrections and next-word suggestions for German, English and
  Spanish at once, from a Rust engine over memory-mapped dictionaries (`core/`).
- **Typing:** data-driven layout with a number row, long-press alternates, space-bar cursor,
  hold-to-delete by word, auto-capitalisation and double-space period.
- **@pi agent:** a durable conversation (PiDurableKit) answered by Apple's on-device model.
  The prompt lives in the keyboard's own field, never in the host app. Answers can be inserted
  or copied, and the field text, the clipboard or a copied screenshot (read with on-device
  OCR) can be attached as context.

## Privacy

Typing never leaves the phone. The keyboard makes no network requests: the agent's runtime
has every request denied, and the model is Apple's on-device one. Snippet values and word
lists are never committed; they are built locally into gitignored paths.

## Layout

- `core/` - Rust: dictionary compiler (`bbdict`), mmap reader and prediction engine, C ABI.
- `spike/keyboard-probe/` - XcodeGen project: containing app and keyboard extension.

## Build

Requires Xcode with the iOS 27 SDK, XcodeGen, Rust with the `aarch64-apple-ios` target,
`bun`, `just` and a development team. The agent uses
[PiDurableKit](https://github.com/finnvoor/PiDurableKit) as a local Swift package; the path in
`spike/keyboard-probe/project.yml` points at the copy in byteowlz's oqto-mobile, so change it
to wherever your checkout lives.

    cp local.env.example local.env    # device, signing identity, profiles, team
    spike/keyboard-probe/relay-install.sh

The script builds the Rust core, fetches and compiles word lists, compiles your Espanso
snippets (from your own Espanso config, if present), builds, signs and installs. Then enable
the keyboard under Settings, General, Keyboard, Keyboards, and allow Full Access.

## Data and licences

Word lists come from [Helium314/aosp-dictionaries](https://codeberg.org/Helium314/aosp-dictionaries),
based on the [Leipzig Corpora Collection](https://wortschatz.uni-leipzig.de/en/download/),
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). They are downloaded at
build time and compiled to byteboard's own format; none are in this repository.
AOSP LatinIME and FlorisBoard (Apache-2.0) were read as references.

byteboard itself is MIT licensed; see `LICENSE`.
