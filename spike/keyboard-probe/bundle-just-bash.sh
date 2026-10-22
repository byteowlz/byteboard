#!/usr/bin/env bash
# Build a single-file, Node-free just-bash bundle for the keyboard extension.
#
# Why: just-bash is pure TypeScript, so it runs in bare JavaScriptCore with no
# WKWebView, no WebAssembly and no Node. Two things have to be fixed up:
#
#   1. Its "browser" bundle statically imports `node:zlib` (twice, for
#      gzip/gunzip). Aliased to fflate so gzip still works and nothing else in
#      the graph needs Node. The other `node:` strings in the output are only
#      error text and a stack-trace regex, not resolution.
#   2. It is ES module syntax, which a JSContext cannot evaluate as a script.
#      Bundled to IIFE with a `JustBash` global.
#
# The output is a build artifact and is gitignored. Re-run this to regenerate.
set -euo pipefail

OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ByteBoardKeyboard/Resources"
OUT="$OUT_DIR/just-bash-iife.js"
WORK="${TMPDIR:-/tmp}/byteboard-just-bash"

mkdir -p "$OUT_DIR"
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"

echo "== fetching just-bash =="
bun init -y >/dev/null 2>&1 || true
bun add just-bash >/dev/null 2>&1
bun add -d esbuild >/dev/null 2>&1
bun add fflate >/dev/null 2>&1
echo "   $(rg -o '"just-bash": "[^"]+"' package.json 2>/dev/null || echo 'just-bash ?')"

cat > zlib-shim.js <<'EOF'
import { gzipSync, gunzipSync } from "fflate";
export const constants = {
  Z_BEST_COMPRESSION: 9, Z_BEST_SPEED: 1, Z_DEFAULT_COMPRESSION: -1, Z_NO_COMPRESSION: 0,
};
export { gzipSync, gunzipSync };
EOF

cat > entry.js <<'EOF'
import * as jb from "just-bash";
globalThis.JustBash = jb;
EOF

echo "== bundling =="
./node_modules/.bin/esbuild entry.js --bundle --format=iife --platform=browser \
  --alias:node:zlib=./zlib-shim.js --outfile="$OUT" --log-level=warning

echo "== result =="
printf '   %s: %s bytes\n' "$OUT" "$(stat -f '%z' "$OUT")"
if rg -q '^\s*import[ {"'"'"']' "$OUT"; then
  echo "   WARNING: output still contains a top-level import; it will not load as a script"
  exit 1
fi
echo "   classic script, no top-level imports"
