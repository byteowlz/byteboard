# Per-person device and signing values (see local.env.example).
set dotenv-load
set dotenv-filename := "local.env"

probe_dir := "spike/keyboard-probe"

# Regenerate the probe Xcode project from project.yml
probe-generate:
    cd {{probe_dir}} && xcodegen generate

# Build the probe for a connected iOS device
probe-build: probe-generate
    cd {{probe_dir}} && xcodebuild -project KeyboardProbe.xcodeproj -scheme ByteBoardSpike -destination 'generic/platform=iOS' build

# Build the probe for the simulator (compilation check only, not a memory measurement)
probe-build-sim: probe-generate
    cd {{probe_dir}} && xcodebuild -project KeyboardProbe.xcodeproj -scheme ByteBoardSpike -destination 'generic/platform=iOS Simulator' build

# List paired iOS devices
probe-devices:
    xcrun devicectl list devices

# Rebuild the Node-free just-bash bundle for the extension (gitignored artifact)
bash-bundle:
    ./spike/keyboard-probe/bundle-just-bash.sh

# Copy the keyboard agent's transcript export off the phone (development-signed builds only).
# The extension rewrites it on every @pi open and every finished turn. Output stays local.
pull-transcript device=env_var_or_default("BB_DEVICE_ID", "") dest="research/transcripts":
    mkdir -p {{dest}}
    xcrun devicectl device copy from --device {{device}} --domain-type appDataContainer \
      --domain-identifier com.byteowlz.byteboard.spike.keyboard \
      --source tmp/agent-transcript.json --destination {{dest}}/agent-transcript-$(date +%Y%m%dT%H%M%S).json

# Export committed content (minus publish.exclude) into ../byteboard-public with its own
# history, refusing on identifiers or private paths. Does not push.
publish-export dir="../byteboard-public":
    ./scripts/publish-export.sh {{dir}}
