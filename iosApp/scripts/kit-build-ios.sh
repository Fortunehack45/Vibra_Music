#!/bin/zsh
# Compile every VibraMusicKit module for the iOS Simulator (catches iOS-only API misuse
# that the Mac-host `swift test` cannot). No simulator is booted.
set -euo pipefail
# Parallel compile jobs are capped at 3 so the machine stays usable during a build (JOBS=n overrides).
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
xcodebuild build -workspace VibraMusic.xcworkspace -scheme VibraMusicKit \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived -jobs "${JOBS:-3}" -quiet "$@"
