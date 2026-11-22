#!/bin/zsh
# Compile the app, widget and all test bundles for the iOS Simulator without booting one.
set -euo pipefail
# Parallel compile jobs are capped at 3 so the machine stays usable during a build (JOBS=n overrides).
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
xcodebuild build-for-testing -workspace VibraMusic.xcworkspace -scheme VibraMusic \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived -jobs "${JOBS:-3}" -quiet "$@"
