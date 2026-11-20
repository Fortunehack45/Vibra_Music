import AudioCache
import VibraMusicCore
import CryptoKit
import Foundation

// Ports the version-update wipe in VibraMusicApplication.kt. An update installs over the old build and
// keeps its data, caches included, so the first launch of a new build clears them "so a format or
// key change between builds can't serve stale or mismatched bytes from a cache the new code didn't
// write".

/// The build the app is running.
enum AppBuild {
    /// This build's identity as one number, standing in for Android's `versionCode`: the marketing
    /// version (`CFBundleShortVersionString`) and the build number (`CFBundleVersion`) together.
    /// The build number alone won't do: iOS lets it start over with each marketing version, and
    /// 0.9.0 shipped as build 1, as a 1.0.0 that forgot to bump it would.
    static var versionCode: Int {
        let info = Bundle.main.infoDictionary ?? [:]
        return versionCode(marketing: info["CFBundleShortVersionString"] as? String,
                           build: info["CFBundleVersion"] as? String)
    }

    /// `marketing (build)` hashed to an integer. The wipe only asks whether the build changed, not
    /// which way, so any string works: a pre-release suffix, a dotted build number, a missing key.
    static func versionCode(marketing: String?, build: String?) -> Int {
        let identity = "\(marketing ?? "") (\(build ?? ""))"
        return SHA256.hash(data: Data(identity.utf8)).prefix(8).reduce(0) { $0 << 8 | Int($1) }
    }
}

enum VersionUpdateWipe {
    /// Every cache a format or key change between builds could invalidate. Android clears its audio
    /// cache and Coil's memory and disk caches. Here that's the audio cache (in Application Support,
    /// out of iOS's reach, as Android's is in `noBackupFilesDir`) with Automix's links into it, and
    /// the artwork cache, whose memory half is still empty this early. The Canvas clips and the
    /// remote covers go too. All but the audio cache are under `Library/Caches`.
    ///
    /// Never listed: Downloads and the Automix analysis store (Application Support too: the
    /// listener's files, and a store that versions its own schema), the lyrics translation cache (it
    /// versions itself too), and settings.
    static var cacheDirectories: [URL] {
        [
            AudioStreamCache.Configuration.standard().directory,
            // Still there only when launch couldn't move it: cleared here, so a later launch's move
            // can't fold the old build's entries into the new cache.
            AudioStreamCache.legacyDirectory,
            AudioCacheRenditions.defaultLinkDirectory,
            ArtworkImageCache.defaultDirectory,
            PlayerCanvasClips.directory,
            RemoteCoverLoader.sharedDirectory,
        ]
    }

    /// On the first launch of a build other than the last one recorded, empties `directories` and
    /// returns true, recording the build once they are all empty (a directory that won't clear
    /// makes the next launch try again). Otherwise it touches nothing. Call it before anything opens those caches.
    ///
    /// Each directory is renamed into `tmp/stale-caches` and deleted from there in the background.
    /// A rename costs the same however much the directory holds, so launch doesn't wait for up to
    /// 10 GB of audio to be deleted (Android deletes on the main thread in `onCreate`). A delete
    /// that the app quit before finishing is picked up again on the next launch. Each directory is
    /// made again, empty, so a cache that's already open still has somewhere to write.
    @MainActor @discardableResult
    static func run(settings: AppSettings, versionCode: Int = AppBuild.versionCode,
                    directories: [URL] = cacheDirectories) -> Bool {
        let manager = FileManager.default
        let stale = manager.temporaryDirectory.appending(path: "stale-caches", directoryHint: .isDirectory)
        defer {
            if manager.fileExists(atPath: stale.path(percentEncoded: false)) {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stale) }
            }
        }
        guard settings.isVersionUpdate(currentVersionCode: versionCode) else { return false }
        var cleared = 0
        var failed = 0
        for directory in directories where manager.fileExists(atPath: directory.path(percentEncoded: false)) {
            let aside = stale.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                try manager.createDirectory(at: stale, withIntermediateDirectories: true)
                try manager.moveItem(at: directory, to: aside)
                cleared += 1
            } catch {
                // Rare (tmp is on the same volume). Deleting in place is slow, but nothing has
                // opened the cache yet, so this is the moment it's safe.
                if (try? manager.removeItem(at: directory)) != nil { cleared += 1 } else { failed += 1 }
            }
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Recorded last, and only when every directory went: a launch killed mid-wipe, or a
        // directory that wouldn't clear, leaves the old build on record so the next launch retries.
        if failed == 0 { settings.recordVersionCode(versionCode) }
        DebugLog.i("App", "a build other than the one on record: cleared \(cleared) of \(directories.count) cache directories")
        return true
    }
}
