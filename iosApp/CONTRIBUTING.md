# Contributing to Vibra Music for iOS

Thank you for helping with Vibra Music for iOS. This guide covers how to propose a change, build and test the project, and what a pull request needs before review.

Vibra Music for iOS is a port of [Vibra Music for Android](https://github.com/kushagrasinghx/Vibra Music). Bugs that also happen on Android, and new features, usually belong upstream first. This repository takes iOS bugs, iOS-specific work, and ports of features that have already landed on Android.

## Proposing a change

- Open an issue before you start on a new feature, a refactor or a UI redesign, so the approach can be agreed first.
- Bug fixes, documentation fixes and small corrections can go straight to a pull request.
- The app follows the Android app screen for screen. A change that makes the iOS app look or behave differently from Android needs a reason in the issue or the pull request.

## Branches and pull requests

Pull requests target `main`.

- Fork the repository and create a branch with a descriptive name, for example `fix/lyrics-offset` or `docs/build-steps`.
- Keep each pull request to one change. Do not mix refactors, reformatting or unrelated fixes into it.
- Keep your branch up to date with `main`.
- Describe what changed and why, and how you tested it. For UI changes, add screenshots or a short screen recording from a simulator or device.
- Do not commit your signing team, bundle identifiers, app group or API keys.
- Respond to review comments and keep the discussion on the code.

### Commit messages

Commits in this project name the area, then say what changed for the user in a full sentence:

```
Lyrics: kept on disk per track, used when nothing answers
Crossfade: the outgoing song no longer drops out as the next one starts
```

## Development setup

You need a Mac with Xcode 27. See [Building from source](README.md#building-from-source) for opening the workspace, signing for a device and the optional Last.fm keys.

The scripts use `/Applications/Xcode.app` unless `DEVELOPER_DIR` points somewhere else.

## Build and test

```sh
scripts/kit-test.sh                       # VibraMusicKit tests on the Mac host, no simulator
scripts/kit-test.sh --filter LyricsTests  # one module's tests
scripts/kit-build-ios.sh                  # compile VibraMusicKit for the iOS Simulator
scripts/app-build.sh                      # compile the app, extensions and every test bundle
scripts/sim-test.sh                       # the Vibra Music test plan on the "iPhone 16" simulator
scripts/sim-test.sh -only-testing:VibraMusicTests
```

The full gate is the `Vibra Music` scheme's test plan, `App/VibraMusic.xctestplan`. It runs `VibraMusicTests` and every `VibraMusicKit` test target:

```sh
xcodebuild test -workspace VibraMusic.xcworkspace -scheme Vibra Music \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The UI tests in `VibraMusicUITests`, some of which need the network, are in a second test plan, `App/VibraMusicE2E.xctestplan`. Run it with `-testPlan Vibra MusicE2E` added to the command above. Tests that call real services are skipped unless `VIBRAMUSIC_LIVE_TESTS=1` is set. The default run must stay offline and deterministic.

Every pull request runs the `Tests` workflow in `.github/workflows/tests.yml` on GitHub Actions. It builds the `Vibra Music` scheme and runs the `Vibra Music` test plan on an iPhone 16 simulator. It does not run the UI tests in `Vibra MusicE2E`. On a failure, the run keeps the `.xcresult` bundle as an artifact for 7 days. Run the tests your change touches before you open a pull request, and say in the pull request which ones you ran. Do not introduce new failures. If a test was already failing before your change, say so.

## Code style

The repository has an `.editorconfig` for indentation and line endings: 4 spaces in Swift, 2 in C++ and shell scripts, LF line endings. There is no linter or formatter configuration. Match the code around you, do not reformat code you are not changing, and follow these conventions.

### Porting

- Read the Kotlin before writing Swift. Keep the behaviour, including the edge cases the Kotlin comments explain, and drop Android plumbing.
- Port the Kotlin unit tests for the code you port.
- Name the Android file a Swift file ports in its header comment, as the existing files do.
- Where iOS cannot do what Android does, use the closest iOS equivalent and say so in a doc comment. [docs/PORTING.md](docs/PORTING.md) section 4 lists the equivalents already chosen.

### Modules

- All non-UI logic lives in `VibraMusicKit`, one module per subsystem. Screens live in `App/Vibra Music/Features/<Area>`.
- A module depends only on what `VibraMusicKit/Package.swift` declares. When a module needs something another module provides, it declares a small protocol and the app wires in the implementation. Shared types such as `Song` and `AppSettings` live in `VibraMusicCore`.
- Make public only what the app or another module uses. Everything else stays `internal`.
- Avoid generic top-level names such as `Client`, `Parser`, `Cache`, `Track`, `Settings` or `Store`. The app imports every module, so name types after their subsystem: `LyricsCache`, `InnerTubeClient`.
- Extensions on standard types (`String`, `Data`, `URL`) are `internal` or `fileprivate` unless they are part of the module's API.
- `VibraMusicKit` must also compile for macOS 14, so its tests run on the Mac host. Guard iOS-only frameworks such as `UIKit`, `AVAudioSession`, `CarPlay` and `WidgetKit` with `#if os(iOS)` or `#if canImport(UIKit)`.

### Code

- Swift 5 language mode. Use Swift concurrency (`async`/`await`, actors). UI-facing state is `@Observable` and `@MainActor`.
- Networking goes through a `URLSession` passed into the initializer (default `.shared`), so tests can inject the `URLProtocol` stubs in `VibraMusicTestSupport`.
- Store settings in `UserDefaults` (injectable suite), data as JSON under Application Support (injectable directory), and credentials in the Keychain.
- Log with `os.Logger`, subsystem `com.fortune.vibramusic.ios`, category set to the module name.
- Comment why the code does something, not what it does. No commented-out code. No TODO without an explanation.
- The app project uses synchronized folders. A new `.swift` file in a target's folder is compiled without editing the project file.

### Tests

- XCTest only. Tests are fast, deterministic and offline by default.
- Put recorded API responses in the module's `Fixtures/` folder and load them with `Bundle.module`.
- Name test classes after the behaviour they check (`QueueShuffleTests`), not after the Android file.
- App tests go in `App/VibraMusicTests/<Area>`.

## Review

A maintainer reviews and approves every pull request before it merges. Review looks at correctness, fit with the Android behaviour and the module boundaries, and maintainability.

## Dependencies and licensing

Vibra Music for iOS is licensed under GPL-3.0. Everything you contribute, and every dependency, must be compatible with it. Files ported from Orchard keep their AGPL-3.0 headers; do not remove or weaken a licence header or a credit to another project.

The package has two third-party dependencies, AMSMB2 and ONNX Runtime. Do not add another unless the change cannot be done without it. A new dependency needs a reason in the pull request covering why it is necessary, its effect on app size, and its licence, and an entry in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
