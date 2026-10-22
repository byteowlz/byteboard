#!/usr/bin/env bash
# Build unsigned, sign here, and install through the MacBook relay (USB).
#
# Why not let Xcode sign: automatic signing needs an Xcode account, and an
# explicit PROVISIONING_PROFILE_SPECIFIER is rejected against an Xcode-managed
# profile. So the app is built unsigned and signed by hand from each bundle's
# own profile entitlements. The relay's keychain is never needed because
# `devicectl device install app` performs no signing.
#
# See the wiki runbook: guides/remote-iphone-install-relay
set -euo pipefail

# Device and signing values are per person: they live in the repo's gitignored local.env
# (template: local.env.example), and the environment overrides them.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$REPO_ROOT/local.env" ]; then
  set -a; . "$REPO_ROOT/local.env"; set +a
fi
need() { [ -n "${!1:-}" ] || { echo "missing $1: set it in local.env (see local.env.example)" >&2; exit 2; }; }
for var in BB_DEVICE_ID BB_SIGN_IDENTITY BB_APP_PROFILE_UUID BB_EXT_PROFILE_UUID; do need "$var"; done

RELAY="${BB_RELAY:-}"
DEVICE_ID="$BB_DEVICE_ID"
SIGN_IDENTITY="$BB_SIGN_IDENTITY"
PROFILE_DIR="${PROFILE_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
APP_PROFILE="$BB_APP_PROFILE_UUID"
EXT_PROFILE="$BB_EXT_PROFILE_UUID"

APP_NAME=ByteBoardSpike
EXT_NAME=ByteBoardKeyboard
DERIVED=/tmp/bb-rel
PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$PROBE_DIR"

# The just-bash bundle is a gitignored build artifact; regenerate on first run.
if [ ! -f "$PROBE_DIR/ByteBoardKeyboard/Resources/just-bash-iife.js" ]; then
  echo "== bundling just-bash (first run) =="
  "$PROBE_DIR/bundle-just-bash.sh"
fi

echo "== core + dictionaries =="
"$PROBE_DIR/build-core.sh"
"$PROBE_DIR/bundle-dicts.sh"
"$PROBE_DIR/bundle-espanso.sh"

echo "== generate =="
xcodegen generate >/dev/null

echo "== build (unsigned, Release) =="
xcodebuild -project KeyboardProbe.xcodeproj -scheme "$APP_NAME" \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > /tmp/bb-rel.log 2>&1 || { rg -i 'error:' /tmp/bb-rel.log | head -10; exit 1; }
echo "   $(rg -o 'BUILD SUCCEEDED' /tmp/bb-rel.log | head -1)"

APP="$DERIVED/Build/Products/Release-iphoneos/$APP_NAME.app"
APEX="$APP/PlugIns/$EXT_NAME.appex"
[ -d "$APEX" ] || { echo "missing appex at $APEX"; exit 1; }

echo "== sign =="
security cms -D -i "$PROFILE_DIR/$APP_PROFILE.mobileprovision" > /tmp/bb-app.plist
security cms -D -i "$PROFILE_DIR/$EXT_PROFILE.mobileprovision" > /tmp/bb-ext.plist
plutil -extract Entitlements xml1 -o /tmp/bb-app.ent.plist /tmp/bb-app.plist
plutil -extract Entitlements xml1 -o /tmp/bb-ext.ent.plist /tmp/bb-ext.plist
cp "$PROFILE_DIR/$EXT_PROFILE.mobileprovision" "$APEX/embedded.mobileprovision"
cp "$PROFILE_DIR/$APP_PROFILE.mobileprovision" "$APP/embedded.mobileprovision"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --entitlements /tmp/bb-ext.ent.plist "$APEX"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --entitlements /tmp/bb-app.ent.plist "$APP"
codesign --verify --deep --strict "$APP" && echo "   signature OK"

echo "== install =="
# Try this machine first (phone on the same network or cable): no relay, no copy step.
# The list shows UDIDs, not the CoreDevice identifier, so reachability is decided by trying.
direct=$(xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 || true)
if echo "$direct" | grep -q 'App installed'; then
  echo "   direct, from this machine"
  echo "$direct" | grep -e 'bundleID' -e 'App installed' | head -3
elif [ -n "$RELAY" ]; then
  echo "   direct failed ($(echo "$direct" | grep -o 'error [0-9]*' | head -1)); via $RELAY over USB"
  ssh -o BatchMode=yes "$RELAY" 'rm -rf ~/bb-install && mkdir -p ~/bb-install'
  rsync -a "$APP" "$RELAY:~/bb-install/"
  ssh -o BatchMode=yes "$RELAY" \
    "xcrun devicectl device install app --device $DEVICE_ID ~/bb-install/$APP_NAME.app" 2>&1 \
    | grep -e 'bundleID' -e 'App installed' -e 'error' | head -5
else
  echo "   direct install failed and no BB_RELAY is set:" >&2
  echo "$direct" | grep -e 'ERROR' -e 'error' | head -3 >&2
  exit 1
fi
