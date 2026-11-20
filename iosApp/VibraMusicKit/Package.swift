// swift-tools-version: 5.10
import PackageDescription

// Every non-UI piece of the Vibra Music iOS port lives here, one module per
// subsystem of the Android app, so each can be built and tested on its own
// (`swift test` on the Mac host, or through the app scheme on the simulator).
//
// Module → Android source it ports (paths under app/src/main/java/com/music/vibramusic/):
//   VibraMusicCore      data/model, data/settings, data/Http.kt, data/TrackLog.kt, data/LikeState.kt
//   InnerTube         data/innertube (API + parser), data/YtMusicRepository.kt, auth/*
//   StreamResolution  data/innertube/{StreamResolver,PlayerClient,InnerTubeXResolver,potoken/*}
//   PlaybackQueue     playback/{Queue*,LastPlayed,Autoplay,SleepTimer,PartyPersonalQueueStash}
//   AudioDSP          playback/{Equalizer*,SpatialAudioProcessor,TransitionFilterProcessor}
//   AudioCache        playback/{AudioCache,ChunkedDataSource,DynamicLruCacheEvictor}.kt
//   PlaybackPolicy    playback/{QualityUpgrade,StreamChoice,StreamContainer,PlaybackFallback,OriginalVersion,AudioOutputStatus,AudioRouting}.kt, data/NerdStats.kt
//   Playback          playback/{PlaybackService,PlayerConnection,CrossfadeController,SleepTimer,...}.kt (AVPlayer engine)
//   Automix           playback/smart/*, native/analyzer/* (C++ in AutomixAnalyzer), app/src/main/assets/*.onnx
//   Lyrics            data/lyrics/*
//   Downloads         download/*
//   Sources           data/sources/*, data/jiosaavn/*
//   NetworkLibrary    data/smb/*, data/webdav/*, data/remote/*
//   ListenTogether    data/listentogether/*, playback/PartySync.kt
//   Integrations      data/scrobbling/*, data/discord/*
//   Replay            data/stats/*, ui/replay/ReplayModel.kt
//   Canvas            data/canvas/*
//   Theming           ui/theme/ArtworkPalette.kt, ui/player/MeshGradient.kt (colour logic)

let core: Target.Dependency = "VibraMusicCore"

// ONNX Runtime runs Automix's two models (Beat This! beats, open-unmix vocals).
// A static xcframework with iOS, iOS Simulator and macOS slices, so the package
// tests still run on the Mac host.
let onnxRuntime: Target.Dependency = .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")

let modules: [(name: String, dependencies: [Target.Dependency])] = [
    ("VibraMusicCore", []),
    ("InnerTube", [core]),
    ("StreamResolution", [core]),
    ("PlaybackQueue", [core]),
    ("AudioDSP", []),
    ("AudioCache", [core, "StreamResolution"]),
    ("PlaybackPolicy", [core]),
    ("Playback", [core, "PlaybackQueue", "AudioDSP", "AudioCache", "PlaybackPolicy"]),
    ("Automix", [core, "AudioDSP", "AutomixAnalyzer", onnxRuntime]),
    ("Lyrics", [core]),
    ("Downloads", [core]),
    ("Sources", [core]),
    ("NetworkLibrary", [core, .product(name: "AMSMB2", package: "AMSMB2")]),
    ("ListenTogether", [core]),
    ("Integrations", [core]),
    ("Replay", [core]),
    ("Canvas", [core]),
    ("Theming", [core]),
]

/// Test targets that need a module they don't already get from their target: a sibling the code
/// under test doesn't depend on (Downloads' live test resolves a real YouTube track through
/// StreamResolution, which the app wires into the queue as its `StreamResolving`; the Downloads
/// module itself still depends on Core only), or a transitive module the tests name directly
/// (PlaybackTests names AudioDSP's `LoudnessReadout`). Each extra dependency also defines
/// `TEST_DEPENDENCY_<NAME>` so the test can compile it out on a manifest without it (`canImport`
/// alone isn't enough: a sibling's module is built either way).
let extraTestDependencies: [String: [String]] = [
    "Downloads": ["StreamResolution"],
    // The Playback tests name AudioDSP's LoudnessReadout directly (the processor protocol hands one
    // to the engine); declaring it keeps that a contract rather than a transitive accident.
    "Playback": ["AudioDSP"],
]

// Resources a module ships, keyed by module name.
let moduleResources: [String: [Resource]] = [
    // beat_this_int8.onnx and vocals_umxhq_int8.onnx, copied from app/src/main/assets.
    "Automix": [.copy("Models")],
]

let package = Package(
    name: "VibraMusicKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VibraMusicKit", targets: modules.map(\.name)),
    ],
    // NetworkLibrary streams SMB shares through AMSMB2 (LGPL-2.1, wraps libsmb2);
    // every other module stays dependency-free.
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.0"),
        .package(url: "https://github.com/Fortunehack45/onnxruntime-swift-package-manager.git", exact: "1.24.2"),
    ],
    targets: modules.map { module in
        .target(name: module.name, dependencies: module.dependencies, resources: moduleResources[module.name])
    } + [
        // The Automix native analyzer (native/analyzer/*.cpp, C++17, AGPLv3) behind a
        // plain C header, so Swift imports it without C++ interop on any dependent.
        // Always optimized, as the Android CMake build does: at -O0 every std::complex
        // multiply is an out-of-line call and one track's analysis takes ten times longer.
        // Never -ffast-math: the analyzer is tuned against exact IEEE behaviour.
        .target(name: "AutomixAnalyzer", cxxSettings: [.unsafeFlags(["-O3"])]),
        // Shared test helpers (URLProtocol stubs, in-memory stores, fixture loading).
        // Only test targets depend on it; it never ships in the app.
        .target(name: "VibraMusicTestSupport", dependencies: [core]),
    ] + modules.map { module in
        let extra = extraTestDependencies[module.name] ?? []
        return .testTarget(
            name: "\(module.name)Tests",
            dependencies: [.target(name: module.name), "VibraMusicTestSupport"] + extra.map { Target.Dependency.target(name: $0) },
            resources: [.copy("Fixtures")],
            swiftSettings: extra.map { SwiftSetting.define("TEST_DEPENDENCY_\($0.uppercased())") }
        )
    },
    cxxLanguageStandard: .cxx17
)
