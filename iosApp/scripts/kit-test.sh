#!/bin/zsh
# Build and run the VibraMusicKit package tests on the Mac host (fast, no simulator).
#   scripts/kit-test.sh                      # every module
#   scripts/kit-test.sh --filter LyricsTests # one module's tests
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/../VibraMusicKit"
swift test -j "${JOBS:-3}" "$@"
