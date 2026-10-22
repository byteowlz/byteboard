#!/usr/bin/env bash
# Fetch word lists and compile them into memory-mappable .bbd dictionaries for the keyboard.
#
# Any of the ~280 lists in Helium314/aosp-dictionaries works; BB_LANGS picks which are
# bundled into this build (default: German, US English and Spanish). Output is gitignored.
# Sources are CC BY 4.0 (Leipzig Corpora via Helium314/aosp-dictionaries); see
# docs/acknowledgements.md.
set -euo pipefail
PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$PROBE/../.." && pwd)"
OUT="$PROBE/ByteBoardKeyboard/Resources/dicts"
CACHE="$ROOT/research/dicts"
BASE="https://codeberg.org/Helium314/aosp-dictionaries/raw/branch/main/wordlists"
LANGS="${BB_LANGS:-de:main_de en:main_en_US__experimental es:main_es__experimental}"

mkdir -p "$OUT"
cargo build --release --bin bbdict --manifest-path "$ROOT/core/Cargo.toml" --quiet
BBDICT="$ROOT/core/target/release/bbdict"

for pair in $LANGS; do
  code="${pair%%:*}"; list="${pair#*:}"
  src="$CACHE/$list/$list.combined"
  if [ ! -s "$src" ]; then
    # Untrusted download: its own fresh directory, read only as data by bbdict.
    rm -rf "$CACHE/$list" && mkdir -p "$CACHE/$list"
    echo "   fetching $list"
    curl -sfL --max-time 600 -o "$src" "$BASE/$list.combined"
    curl -sfL --max-time 60 -o "$CACHE/$list/$list.source" "$BASE/$list.source" || true
  fi
  if [ ! -s "$OUT/$code.bbd" ] || [ "$src" -nt "$OUT/$code.bbd" ]; then
    "$BBDICT" compile "$src" "$OUT/$code.bbd" | sed 's/^/   /'
  fi
done
