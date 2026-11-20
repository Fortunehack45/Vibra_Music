import VibraMusicCore
import Foundation
import InnerTube

/// Who the app is signed in as, the way the account screens read it: MainActivity's `signedIn`,
/// `account`, `selectedChannelName`, `googleAccounts`, `activeAccountId` and `activeProfileId`.
///
/// A value rather than reads straight off `YouTubeAccountManager`, so the screens can be drawn for
/// a signed-in listener in tests and debug screenshots without a real Google login.
struct AccountIdentity: Equatable {
    var signedIn: Bool
    var account: Account?
    var channelName: String?
    var accounts: [GoogleAccountSession]
    var activeAccountId: String?
    var activeProfileId: String?

    static let signedOut = AccountIdentity(signedIn: false, account: nil, channelName: nil, accounts: [],
                                           activeAccountId: nil, activeProfileId: nil)

    @MainActor
    init(_ manager: YouTubeAccountManager) {
        #if DEBUG
        if let demo = AccountDebugLaunch.demoIdentity {
            self = demo
            return
        }
        #endif
        signedIn = manager.isSignedIn
        // The top bar and the card show the account menu's answer; until it arrives, the stored
        // profile (name, handle, photo) stands in, as Android's cached listener did.
        account = manager.account ?? manager.activeProfile.map {
            Account(name: $0.name, email: manager.activeSession?.email ?? $0.handle, thumbnailUrl: $0.avatar)
        }
        channelName = manager.selectedChannelName
        accounts = manager.accounts
        activeAccountId = manager.activeAccountId
        activeProfileId = manager.activeProfileId
    }

    init(signedIn: Bool, account: Account?, channelName: String?, accounts: [GoogleAccountSession],
         activeAccountId: String?, activeProfileId: String?) {
        self.signedIn = signedIn
        self.account = account
        self.channelName = channelName
        self.accounts = accounts
        self.activeAccountId = activeAccountId
        self.activeProfileId = activeProfileId
    }
}
