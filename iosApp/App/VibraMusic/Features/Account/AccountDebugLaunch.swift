import VibraMusicCore
import Foundation
import InnerTube

#if DEBUG
/// Debug-build launch arguments that open the account screens for screenshots and manual checks.
/// Release builds ignore them.
///
/// - `-accountOpen account | discord | profiles | signIn | discordLogin | listenBrainzToken |
///   lastfmLogin | discordToken | discordStatus | library` opens that screen (alerts on top of their
///   page; `library` is the Library tab, for its top bar).
/// - `-accountDemo` draws the screens for a demo listener with two Google accounts (one with a
///   Brand profile). Nothing is stored and nothing is signed in: taps that would act on an account
///   find none.
enum AccountDebugLaunch {
    enum Target: String {
        case account, discord, profiles, signIn, discordLogin, library
        case listenBrainzToken, lastfmLogin, discordToken, discordStatus
    }

    static var target: Target? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-accountOpen"), index + 1 < arguments.count else { return nil }
        return Target(rawValue: arguments[index + 1])
    }

    @MainActor private static var consumed: Set<Target> = []

    /// Consumed once, by the first screen that acts on it.
    @MainActor static func take(_ wanted: Target) -> Target? {
        guard target == wanted, !consumed.contains(wanted) else { return nil }
        consumed.insert(wanted)
        return wanted
    }

    /// The alert a page should open for `target`, if it names one.
    @MainActor static func takeAlert(_ alert: AccountAlert) -> AccountAlert? {
        guard let wanted = Target(rawValue: alert.rawValue) else { return nil }
        return take(wanted) == nil ? nil : alert
    }

    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("-accountDemo") }

    static var demoIdentity: AccountIdentity? {
        guard isDemo else { return nil }
        return AccountDebugLaunch.demo
    }

    static let demo: AccountIdentity = {
        let personal = YouTubeProfile(profileId: "demo-personal", name: "Maya Chen", handle: "@mayachen",
                                      dataSyncId: "demo-personal")
        let brand = YouTubeProfile(profileId: "demo-brand", name: "Night Drive Radio", handle: "",
                                   pageId: "demo-brand", dataSyncId: "demo-brand", isBrandAccount: true)
        let work = YouTubeProfile(profileId: "demo-work", name: "Maya Chen", handle: "", dataSyncId: "demo-work")
        let accounts = [
            GoogleAccountSession(accountId: "demo-a", cookie: "", name: "Maya Chen", email: "maya.chen@example.com",
                                 profiles: [personal, brand], activeProfileId: personal.profileId),
            GoogleAccountSession(accountId: "demo-b", cookie: "", name: "Maya Chen", email: "maya@studio.example",
                                 profiles: [work], activeProfileId: work.profileId),
        ]
        return AccountIdentity(signedIn: true,
                               account: Account(name: "Maya Chen", email: "maya.chen@example.com", thumbnailUrl: nil),
                               channelName: "Maya Chen", accounts: accounts,
                               activeAccountId: "demo-a", activeProfileId: personal.profileId)
    }()
}
#endif
