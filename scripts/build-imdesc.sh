#!/usr/bin/env bash
set -u

# Detect if the script is being sourced. If so, prefer returning instead of
# exiting the whole interactive shell. Many users accidentally run this script
# with `.` or `source`, which makes any `exit` call kill their terminal.
_SCRIPT_SOURCED=0
if [ "${BASH_SOURCE[0]:-}" != "${0:-}" ]; then
  _SCRIPT_SOURCED=1
fi

SCRIPT_PATH="$0"
if [ -n "${BASH_SOURCE+x}" ]; then
  # shellcheck disable=SC2128
  SCRIPT_PATH="${BASH_SOURCE[0]}"
fi

ROOT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
SWIFT_SOURCE="$ROOT_DIR/services/collector/imdesc.swift"
DEST_DIR="${IMDESC_INSTALL_DIR:-/usr/local/bin}"
DEST_PATH="$DEST_DIR/imdesc"
MODULE_CACHE_DIR="${MODULE_CACHE_DIR:-$ROOT_DIR/.build/swift-module-cache}"

log() {
  printf '[build-imdesc] %s\n' "$1"
}

fail() {
  log "ERROR: $1"
  # If the script was sourced, return with non-zero so the caller can handle
  # it; otherwise exit the process as before.
  if [ "$_SCRIPT_SOURCED" -eq 1 ]; then
    return 1
  else
    exit 1
  fi
}

if [ ! -f "$SWIFT_SOURCE" ]; then
  fail "Swift source not found at $SWIFT_SOURCE"
fi

if ! command -v swiftc >/dev/null 2>&1; then
  fail "swiftc not found. Install Xcode command-line tools or Xcode (see 
https://developer.apple.com/xcode/) and ensure \
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
is set if you have Xcode installed."
fi

# If the active developer directory is the Command Line Tools bundle we print
# a clearer hint: building with system frameworks (Vision/Foundation) is
# sometimes problematic with just the CLT; recommend using full Xcode.
DEV_DIR=$(xcode-select -p 2>/dev/null || true)
if [ -n "$DEV_DIR" ] && echo "$DEV_DIR" | grep -q "/Library/Developer/CommandLineTools"; then
  log "Note: active developer directory is CommandLineTools ($DEV_DIR)."
  log "Building against macOS frameworks (Vision/Foundation) may fail."
  log "If you have Xcode installed, point the developer directory to it with:"
  log "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

log "Building imdesc from $SWIFT_SOURCE"
log "Installing to $DEST_PATH"
log "Using module cache at $MODULE_CACHE_DIR"

mkdir -p "$DEST_DIR" || fail "Unable to create install dir: $DEST_DIR"
mkdir -p "$MODULE_CACHE_DIR" || fail "Unable to create module cache dir: $MODULE_CACHE_DIR"

if ! swiftc "$SWIFT_SOURCE" \
  -o "$DEST_PATH" \
  -framework Vision \
  -framework Foundation \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -parse-as-library; then
  fail "swiftc build failed. Check the output above for details. If you see
errors mentioning redefinition of 'SwiftBridging' or "could not build
module 'Foundation'", try using the full Xcode installation or set the
developer directory via 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'."
fi

if ! chmod +x "$DEST_PATH"; then
  fail "Unable to mark $DEST_PATH as executable"
fi

log "imdesc built at $DEST_PATH"

if [ -t 1 ]; then
  log "Build complete."
fi
