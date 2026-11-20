import XCTest
import VibraMusicCore
@testable import InnerTube

/// Reading the channels a login can act as out of an account-switcher response (Android's
/// AccountChannelTest), and the signed-in profile out of the account menu.
///
/// Pinned because the two things each row must yield — the `pageId` header and the `datasyncIdToken`
/// body value — arrive as single-key objects in a list Google never promised an order for, alongside
/// tokens meant for other purposes. A positional read works right up until Google adds a token, and
/// then silently switches the listener to a channel that isn't the one they tapped.
final class AccountChannelParsingTests: XCTestCase {

    private func parse(_ text: String) -> [AccountChannel] {
        InnerTubeParser.parseAccountChannels(json(text))
    }

    func testPersonalChannelAndBrandChannelAreBothRead() {
        let channels = parse(Self.switcher)
        XCTAssertEqual(channels.count, 2)

        let personal = channels[0]
        XCTAssertEqual(personal.name, "Ada Lovelace")
        XCTAssertEqual(personal.subtitle, "@ada")
        // Not a delegated page, and must not be given one — an `X-Goog-PageId` on the account's own
        // channel is a different request entirely.
        XCTAssertNil(personal.pageId)
        XCTAssertEqual(personal.dataSyncId, "SESSION_A")
        XCTAssertTrue(personal.activeOnWeb)

        let brand = channels[1]
        XCTAssertEqual(brand.name, "Analytical Engine Radio")
        XCTAssertEqual(brand.subtitle, "Brand account")
        XCTAssertEqual(brand.pageId, "113355")
        XCTAssertEqual(brand.dataSyncId, "SESSION_B")
        XCTAssertFalse(brand.activeOnWeb)
    }

    func testTokenOrderIsNotAssumed() {
        // Same brand channel, tokens listed the other way round with an unrelated one first.
        let channels = parse(Self.shuffledTokens)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first?.pageId, "113355")
        XCTAssertEqual(channels.first?.dataSyncId, "SESSION_B")
    }

    func testDelegatedHalfOfTheDataSyncIdIsUsed() {
        XCTAssertEqual(parse(Self.shuffledTokens).first?.dataSyncId, "SESSION_B")
    }

    func testPlainAccountFallsBackWhenDelegatedHalfIsEmpty() {
        XCTAssertEqual(YouTubeWebLogin.normalizeDataSyncId("SYNC_PERSONAL||"), "SYNC_PERSONAL")
        XCTAssertEqual(YouTubeWebLogin.normalizeDataSyncId("PLAIN"), "PLAIN")
        XCTAssertNil(YouTubeWebLogin.normalizeDataSyncId(""))
        XCTAssertNil(YouTubeWebLogin.normalizeDataSyncId("  "))
        XCTAssertNil(YouTubeWebLogin.normalizeDataSyncId("||"))
        XCTAssertNil(YouTubeWebLogin.normalizeDataSyncId(nil))
    }

    func testAnEntryWithNothingToSendIsDropped() {
        // Offering a channel that would quietly leave the current one selected is worse than not
        // listing it.
        XCTAssertTrue(parse(Self.noTokens).isEmpty)
    }

    func testAnUnrecognisedEnvelopeYieldsNothingRatherThanThrowing() {
        XCTAssertTrue(parse(#"{"responseContext":{},"contents":{}}"#).isEmpty)
    }

    func testTheSameChannelListedTwiceIsKeptOnce() {
        let doubled = #"{"a":[\#(Self.shuffledTokensItem),\#(Self.shuffledTokensItem)]}"#
        XCTAssertEqual(parse(doubled).count, 1)
    }

    // MARK: - Recorded shapes

    func testAccountsListFixture() throws {
        let channels = InnerTubeParser.parseAccountChannels(try Fixtures.json("signed_in/accounts_list.json"))
        XCTAssertEqual(channels.map(\.name), ["Ada Lovelace", "Analytical Engine Radio"])
        XCTAssertEqual(channels.map(\.pageId), [nil, "113355"])
        XCTAssertEqual(channels.first?.thumbnailUrl, "https://x/s40")
    }

    func testAccountSwitcherBodyBehindTheXSSIGuard() throws {
        let raw = try Fixtures.text("signed_in/account_switcher.txt")
        XCTAssertTrue(raw.hasPrefix(")]}'"))
        let parsed = try InnerTubeJSON.parse(InnerTubeClient.strippingXSSIGuard(raw))
        let channels = InnerTubeParser.parseAccountChannels(parsed)
        XCTAssertEqual(channels.map(\.dataSyncId), ["SESSION_A", "SESSION_B"])
    }

    func testAnEmptyAccountsListIsEmpty() throws {
        XCTAssertTrue(InnerTubeParser.parseAccountChannels(try Fixtures.json("signed_in/accounts_list_empty.json")).isEmpty)
    }

    // MARK: - Account menu

    func testAccountMenuFixtureUsesTheHandleWhenThereIsNoEmail() throws {
        let account = try XCTUnwrap(InnerTubeParser.parseAccount(try Fixtures.json("signed_in/account_menu.json")))
        XCTAssertEqual(account.name, "Analytical Engine Radio")
        XCTAssertEqual(account.email, "@engine-radio")
        // Largest photo, as offered.
        XCTAssertEqual(account.thumbnailUrl, "https://yt3.ggpht.com/brand=s88")
    }

    func testAccountMenuPrefersEmailInEitherShape() {
        let runs = json(#"{"h":{"activeAccountHeaderRenderer":{"accountName":{"runs":[{"text":"Ada"}]},"email":{"runs":[{"text":"ada@example.com"}]},"channelHandle":{"runs":[{"text":"@ada"}]}}}}"#)
        XCTAssertEqual(InnerTubeParser.parseAccount(runs)?.email, "ada@example.com")
        let simple = json(#"{"h":{"activeAccountHeaderRenderer":{"accountName":{"runs":[{"text":"Ada"}]},"email":{"simpleText":"ada@example.com"}}}}"#)
        XCTAssertEqual(InnerTubeParser.parseAccount(simple)?.email, "ada@example.com")
    }

    func testAccountMenuWithoutANameIsNoAccount() {
        XCTAssertNil(InnerTubeParser.parseAccount(json(#"{"h":{"activeAccountHeaderRenderer":{"accountName":{"runs":[]}}}}"#)))
        XCTAssertNil(InnerTubeParser.parseAccount(json(#"{"responseContext":{}}"#)))
    }

    // MARK: - Samples (Android's AccountChannelTest fixtures)

    static let switcher = #"""
    {"data":{"actions":[{"getMultiPageMenuAction":{"menu":{"multiPageMenuRenderer":{
      "sections":[{"accountSectionListRenderer":{"contents":[{"accountItemSectionRenderer":{
        "contents":[
          {"accountItem":{
            "accountName":{"simpleText":"Ada Lovelace"},
            "accountPhoto":{"thumbnails":[{"url":"https://x/s40","width":40}]},
            "isSelected":true,
            "channelHandle":{"simpleText":"@ada"},
            "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[
              {"accountSigninToken":{"signinUrl":"https://accounts.google.com/x"}},
              {"datasyncIdToken":{"datasyncIdToken":"SYNC_PERSONAL||SESSION_A"}}
            ]}}
          }},
          {"accountItem":{
            "accountName":{"runs":[{"text":"Analytical Engine Radio"}]},
            "accountPhoto":{"thumbnails":[{"url":"https://y/s40","width":40}]},
            "isSelected":false,
            "accountByline":{"simpleText":"Brand account"},
            "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[
              {"pageIdToken":{"pageId":"113355"}},
              {"datasyncIdToken":{"datasyncIdToken":"SYNC_BRAND||SESSION_B"}}
            ]}}
          }}
        ]}}]}}]}}}}]}}
    """#

    static let shuffledTokensItem = #"""
    {"accountItem":{
      "accountName":{"simpleText":"Analytical Engine Radio"},
      "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[
        {"offlineCacheKeyToken":{"clientCacheKey":"CACHE"}},
        {"datasyncIdToken":{"datasyncIdToken":"SYNC_BRAND||SESSION_B"}},
        {"pageIdToken":{"pageId":"113355"}}
      ]}}
    }}
    """#

    static let shuffledTokens = #"{"contents":[\#(shuffledTokensItem)]}"#

    static let noTokens = #"""
    {"contents":[{"accountItem":{
      "accountName":{"simpleText":"Ada Lovelace"},
      "serviceEndpoint":{"signalServiceEndpoint":{"signal":"CLIENT_SIGNAL"}}
    }}]}
    """#
}
