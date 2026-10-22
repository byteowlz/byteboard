#!/usr/bin/env bash
# Compile ~/.config/espanso/match/*.yml into a normalized JSON snapshot for ByteBoard.
# Output lands in ByteBoardKeyboard/Resources/snippets.local.json, which is matched by
# *.local.json in .gitignore so private snippet values are never committed to git.
set -euo pipefail

PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$PROBE_DIR/ByteBoardKeyboard/Resources"
OUT="$OUT_DIR/snippets.local.json"
mkdir -p "$OUT_DIR"

bun -e '
import { Glob } from "bun";
import { existsSync, readFileSync, writeFileSync } from "fs";

const home = process.env.HOME || "";
const matchDir = `${home}/.config/espanso/match`;
const outPath = process.argv[1];

const entries = [];
if (existsSync(matchDir)) {
  const glob = new Glob(`${matchDir}/*.yml`);
  for (const file of Array.from(glob.scanSync()).sort()) {
    const source = file.split("/").pop() || "";
    let data;
    try {
      data = Bun.YAML.parse(readFileSync(file, "utf8")) || {};
    } catch {
      continue;
    }
    for (const m of data.matches || []) {
      const triggers = m.triggers || (m.trigger ? [m.trigger] : []);
      for (const rawTrigger of triggers) {
        const trigger = String(rawTrigger ?? "");
        if (!trigger) continue;
        const label = String(m.label ?? "").trim();
        let kind = "static";
        let replace = String(m.replace ?? "");
        let dateFormat = null;
        let dateOffsetSeconds = 0;
        let shellCmd = null;
        let clipVar = null;

        if (m.image_path) {
          kind = "image";
          replace = String(m.image_path);
        } else if (m.form) {
          kind = "form";
          replace = String(m.form);
        } else if (Array.isArray(m.vars) && m.vars.length > 0) {
          const vars = m.vars;
          const dateVar = vars.find(v => v.type === "date");
          const shellVar = vars.find(v => v.type === "shell");
          const clip = vars.find(v => v.type === "clipboard");
          const formVar = vars.find(v => v.type === "form");
          const scriptVar = vars.find(v => v.type === "script");
          if (formVar) {
            kind = "form";
          } else if (dateVar) {
            kind = "date";
            dateFormat = dateVar.params?.format ?? "%Y-%m-%d";
            const off = dateVar.params?.offset;
            if (typeof off === "number") dateOffsetSeconds = off;
          } else if (shellVar) {
            kind = "shell";
            shellCmd = String(shellVar.params?.cmd ?? "");
          } else if (clip) {
            kind = "clipboard";
            clipVar = String(clip.name ?? "clipb");
          } else if (scriptVar) {
            kind = "script";
            shellCmd = Array.isArray(scriptVar.params?.args) ? scriptVar.params.args.join(" ") : "";
          }
        } else if (replace.includes("$|$")) {
          kind = "cursor";
        }

        entries.push({
          trigger,
          label: label || replace.replace(/\s+/g, " ").slice(0, 28),
          replace,
          kind,
          dateFormat,
          dateOffsetSeconds,
          shellCmd,
          clipVar,
          source,
        });
      }
    }
  }
}

if (entries.length === 0) {
  entries.push(
    { trigger: ":owlz", label: "byteowlz", replace: "byteowlz", kind: "static", dateFormat: null, dateOffsetSeconds: 0, shellCmd: null, clipVar: null, source: "builtin" },
    { trigger: ":shrug", label: "shrug", replace: "¯\\_(ツ)_/¯", kind: "static", dateFormat: null, dateOffsetSeconds: 0, shellCmd: null, clipVar: null, source: "builtin" }
  );
}

writeFileSync(outPath, JSON.stringify({ version: 1, count: entries.length, entries }, null, 2));
console.log(`   compiled ${entries.length} snippets -> ${outPath}`);
' "$OUT"
