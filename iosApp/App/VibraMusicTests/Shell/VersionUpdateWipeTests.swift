import AudioCache
import Automix
import VibraMusicCore
import Downloads
import XCTest
@testable import VibraMusic

/// The first launch of a different build empties the caches the previous build wrote, as
/// VibraMusicApplication.kt does, and nothing else.
@MainActor
final class VersionUpdateWipeTests: XCTestCase {
    /// Settings on a throwaway suite whose device last launched `build`, or recorded none (0.9.0).
    private func settings(lastLaunched build: Int?) -> AppSettings {
        let suite = "vibramusic.version-wipe.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
        if let build { _ = settings.consumeVersionUpdate(currentVersionCode: build) }
        return settings
    }

    /// One directory per cache the wipe clears, with a file in each.
    private func seededCaches() throws -> [URL] {
        let root = makeTemporaryDirectory(self)
        return try ["audio", "links", "artwork", "canvas", "remote"].map { name in
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("seed".utf8).write(to: directory.appending(path: "entry"))
            return directory
        }
    }

    private func contents(of directory: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    }

    /// An update from 0.9.0, which never recorded its build: that launch clears every cache,
    /// and leaves each directory in place, empty, for the cache to write to.
    func testUpdatingFrom090EmptiesEveryCache() throws {
        let caches = try seededCaches()
        XCTAssertTrue(VersionUpdateWipe.run(settings: settings(lastLaunched: nil), versionCode: 100_000_002, directories: caches))
        for directory in caches {
            XCTAssertEqual(contents(of: directory), [], "\(directory.lastPathComponent) was not emptied")
        }
    }

    /// Relaunching the build that wrote the caches clears nothing.
    func testRelaunchingTheSameBuildTouchesNothing() throws {
        let caches = try seededCaches()
        XCTAssertFalse(VersionUpdateWipe.run(settings: settings(lastLaunched: 2), versionCode: 2, directories: caches))
        for directory in caches {
            XCTAssertEqual(contents(of: directory), ["entry"], "\(directory.lastPathComponent) was cleared without an update")
        }
    }

    /// A directory that won't clear leaves the old build on record, so the next launch wipes again
    /// instead of keeping the stale bytes for good.
    func testAWipeThatFailsIsRetriedNextLaunch() throws {
        let caches = try seededCaches()
        let stuck = caches[0].path(percentEncoded: false)
        let recorded = settings(lastLaunched: 1)
        // An immutable directory refuses both the rename and the delete, even to its owner.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck)
        addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck) }
        XCTAssertTrue(VersionUpdateWipe.run(settings: recorded, versionCode: 2, directories: caches))
        XCTAssertEqual(contents(of: caches[0]), ["entry"], "an immutable directory should have kept the cache")

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck)
        XCTAssertTrue(VersionUpdateWipe.run(settings: recorded, versionCode: 2, directories: caches), "the failed wipe was not retried")
        XCTAssertEqual(contents(of: caches[0]), [])
        XCTAssertFalse(VersionUpdateWipe.run(settings: recorded, versionCode: 2, directories: caches), "a finished wipe runs once")
    }

    /// The live list is the audio cache, where it lives now (Application Support, out of iOS's
    /// reach), and caches inside Library/Caches. None of it holds Downloads or the Automix analysis
    /// store, which must survive every update.
    func testTheWipeNeverReachesDownloadsOrTheAnalysisStore() {
        func isInside(_ child: URL, _ parent: URL) -> Bool {
            let child = child.standardizedFileURL.pathComponents, parent = parent.standardizedFileURL.pathComponents
            return child.count > parent.count && Array(child.prefix(parent.count)) == parent
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let audio = AudioStreamCache.Configuration.standard().directory
        XCTAssertTrue(VersionUpdateWipe.cacheDirectories.contains(audio), "the wipe follows the audio cache")
        XCTAssertTrue(VersionUpdateWipe.cacheDirectories.contains(AudioStreamCache.legacyDirectory),
                      "and clears the old one a failed move left behind")
        XCTAssertFalse(isInside(audio, caches), "the audio cache is out of Caches, which iOS purges")
        let userData = [DownloadStore.applicationSupport().root, AutomixAnalysisStore.defaultDirectory]
        for directory in VersionUpdateWipe.cacheDirectories {
            XCTAssertTrue(directory == audio || isInside(directory, caches), "\(directory.path) is not a cache under \(caches.path)")
            for kept in userData {
                XCTAssertFalse(kept.standardizedFileURL == directory.standardizedFileURL || isInside(kept, directory),
                               "wiping \(directory.path) would delete \(kept.path)")
            }
        }
    }

    /// Every release gets its own version code, whether it bumps the marketing version, the build
    /// number or both: 0.9.0 and a 1.0.0 that kept build 1 must still differ, and so must a
    /// pre-release and its release.
    func testEveryReleaseHasItsOwnVersionCode() {
        let releases = [("0.9.0", "1"), ("1.0.0", "1"), ("1.0.0", "2"), ("1.0.1", "1"), ("1.1", "1"), ("1.1.0", "1"),
                        ("1.0.0-beta.2", "1"), ("1.0.0", "1.1")]
        let codes = releases.map { AppBuild.versionCode(marketing: $0.0, build: $0.1) }
        XCTAssertEqual(Set(codes).count, codes.count, "two releases share a version code: \(codes)")
        XCTAssertEqual(AppBuild.versionCode(marketing: "1.0.0", build: "2"), codes[2], "the same build reads the same code")
    }
}
