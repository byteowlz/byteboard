#!/usr/bin/env bash
# Build byteboard-core as a static library for the device. The Xcode project links
# core/target/aarch64-apple-ios/release/libbyteboard_core.a and imports core/include.
set -euo pipefail
CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../core" && pwd)"
export IPHONEOS_DEPLOYMENT_TARGET=18.0
cargo build --release --lib --target aarch64-apple-ios --manifest-path "$CORE/Cargo.toml" --quiet
echo "   $(ls -lh "$CORE/target/aarch64-apple-ios/release/libbyteboard_core.a" | awk '{print $5}') libbyteboard_core.a"
