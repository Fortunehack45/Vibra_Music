import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// The `X-Super-Properties` client fingerprint Discord's own mobile client
/// sends on every request (ports `SuperProperties.kt`).
///
/// The gateway accepts a presence without it, but the REST endpoint that
/// mirrors external artwork treats a request with no client fingerprint as
/// suspicious and starts returning 401s — so cover art silently stops
/// appearing while the rest of the presence keeps working. Sending this makes
/// the call look like what it is impersonating.
///
/// The device UUIDs are generated once per process and cached: rotating them
/// per request is exactly what a real client never does. On iOS the `os`
/// is reported as `"iOS"` with the real system version; `client_version`
/// stays the researched Android constant because the gateway keys behaviour
/// off the build number, not the platform string.
public enum DiscordSuperProperties {
    private static let clientVersion = "314.13 - Stable"
    private static let clientBuildNumber = 314_013
    private static let releaseChannel = "stable"

    public static var userAgent: String {
        "Discord-iOS/\(clientBuildNumber);RNA"
    }

    private static let cachedIDs: (vendor: String, uuid: String, launch: String) = (
        UUID().uuidString, UUID().uuidString, UUID().uuidString
    )

    /// The fingerprint dictionary. `device` / `osVersion` describe the real
    /// iOS device so the value does not rot into a stale Android claim.
    public static func dictionary() -> [String: Any] {
        var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        var device = "iOS"
        #if canImport(UIKit)
        osVersion = UIDevice.current.systemVersion
        device = UIDevice.current.model
        #endif
        return [
            "os": "iOS",
            "browser": "Discord iOS",
            "device": device,
            "system_locale": Locale.current.identifier,
            "client_version": clientVersion,
            "release_channel": releaseChannel,
            "device_vendor_id": cachedIDs.vendor,
            "client_uuid": cachedIDs.uuid,
            "client_launch_id": cachedIDs.launch,
            "os_version": osVersion,
            "client_build_number": clientBuildNumber,
            "client_event_source": NSNull(),
            "design_id": 0,
        ]
    }

    /// The fingerprint as Base64 JSON, for the `X-Super-Properties` header.
    public static func base64() -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dictionary(), options: [.sortedKeys]
        ) else { return nil }
        return data.base64EncodedString()
    }

    /// Headers identifying the request as Discord's own mobile client.
    public static func headers(token: String) -> [String: String] {
        var headers = [
            "Authorization": token,
            "User-Agent": userAgent,
            "Content-Type": "application/json",
        ]
        if let superProperties = base64() {
            headers["X-Super-Properties"] = superProperties
        }
        return headers
    }
}
