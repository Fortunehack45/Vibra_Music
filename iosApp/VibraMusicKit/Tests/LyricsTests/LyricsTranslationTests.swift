import XCTest
@testable import Lyrics

/// Translation and romanization, with the recorded Google answers for two lines of
/// YOASOBI's 夜に駆ける. PORTING.md's done-test: Japanese lyrics become English, and the
/// timing still matches.
final class LyricsTranslationTests: XCTestCase {

    /// The two lines the fixtures were recorded for, with the timing LRCLIB gives them, a
    /// break between, and a duet side to prove every timing field survives.
    private var japanese: [LyricLine] {
        [
            LyricLine(timeMs: 1_410, text: "道りちほう春まいましちほう", sungUntilMs: 6_830),
            LyricLine(timeMs: 6_830, text: ""),
            LyricLine(timeMs: 8_920, text: "皿庭くまや魚ふ庭ふふ雨う", sungUntilMs: 15_680, alignment: .end),
        ]
    }

    private func translator(_ route: @escaping StubURLProtocol.Route) -> (LyricsTranslator, String) {
        let (session, id) = StubURLProtocol.session(route)
        return (LyricsTranslator(session: session, cacheDirectory: nil), id)
    }

    private static func recorded() throws -> StubURLProtocol.Route {
        let translated = try Fixture.data("translate-ja-en.json")
        let romanized = try Fixture.data("translate-ja-romanize.json")
        return { request in request.formField("dt") == "rm" ? .ok(romanized) : .ok(translated) }
    }

    func testJapaneseLyricsBecomeEnglishAndTheTimingStillMatches() async throws {
        let (translator, id) = translator(try Self.recorded())
        let result = await translator.translate(trackId: "yoru", lines: japanese, targetLanguage: "en")
        guard case .translated(let lines, let source, let fromCache) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(source, "ja")
        XCTAssertFalse(fromCache)
        XCTAssertEqual(lines.map(\.text), ["Grand fiddle daisy laugh lucky", "", "Pillow garden collar wallet press paint tulip flag press pocket fast stair"])
        XCTAssertEqual(lines.map(\.timeMs), japanese.map(\.timeMs))
        XCTAssertEqual(lines.map(\.sungUntilMs), japanese.map(\.sungUntilMs))
        XCTAssertEqual(lines.map(\.alignment), japanese.map(\.alignment))
        XCTAssertTrue(lines[1].isGap, "the instrumental break is kept, and never sent")

        // One request, both lines in it, separated by a private-use marker.
        let request = try XCTUnwrap(StubURLProtocol.requests(id).first)
        XCTAssertEqual(StubURLProtocol.requests(id).count, 1)
        XCTAssertEqual(request.formField("q"), "道りちほう春まいましちほう\n\u{E000}0001\u{E001}\n皿庭くまや魚ふ庭ふふ雨う")
        XCTAssertEqual(request.formField("tl"), "en")
        XCTAssertEqual(request.formField("sl"), "auto")
        XCTAssertEqual(request.formField("client"), "dict-chrome-ex")
    }

    func testASecondToggleIsServedFromTheCache() async throws {
        let (translator, id) = translator(try Self.recorded())
        _ = await translator.translate(trackId: "yoru", lines: japanese, targetLanguage: "en")
        let again = await translator.translate(trackId: "yoru", lines: japanese, targetLanguage: "en")
        guard case .translated(_, _, let fromCache) = again else { return XCTFail("\(again)") }
        XCTAssertTrue(fromCache)
        XCTAssertEqual(StubURLProtocol.requests(id).count, 1)
    }

    func testTheDiskCacheOutlivesTheTranslator() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("translations-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (session, id) = StubURLProtocol.session(try Self.recorded())
        _ = await LyricsTranslator(session: session, cacheDirectory: directory).translate(trackId: "yoru", lines: japanese, targetLanguage: "en")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix(".json.deflate"))

        let fresh = LyricsTranslator(session: session, cacheDirectory: directory)
        let result = await fresh.translate(trackId: "yoru", lines: japanese, targetLanguage: "en")
        guard case .translated(let lines, _, let fromCache) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(fromCache)
        XCTAssertEqual(lines.first?.text, "Grand fiddle daisy laugh lucky")
        XCTAssertEqual(StubURLProtocol.requests(id).count, 1)
    }

    func testWordSyncedLinesSweepTheTranslationOnTheOriginalsClock() async throws {
        let words = [
            LyricWord(startMs: 1_000, endMs: 3_000, text: "道りちほう"),
            LyricWord(startMs: 3_000, endMs: 4_000, text: "春まいましちほう"),
        ]
        let source = [LyricLine(timeMs: 1_000, text: "道りちほう春まいましちほう", words: words), LyricLine(timeMs: 5_000, text: "皿庭くまや魚ふ庭ふふ雨う")]
        let (translator, _) = translator(try Self.recorded())
        guard case .translated(let lines, _, _) = await translator.translate(trackId: "w", lines: source, targetLanguage: "en") else {
            return XCTFail("not translated")
        }
        let line = lines[0]
        // One word spanning the original vocal, driven by the original's own progress.
        XCTAssertEqual(line.words, [LyricWord(startMs: 1_000, endMs: 4_000, text: "Grand fiddle daisy laugh lucky")])
        XCTAssertEqual(line.timingSource, source[0])
        // Halfway through the first (held) source word is 2.5 of 13 source characters.
        let expected = Float(2.5) / 13 * Float(line.text.utf16.count)
        XCTAssertEqual(line.revealedChars(2_000), expected, accuracy: 0.01)
        XCTAssertEqual(line.revealedChars(4_000), Float(line.text.utf16.count), accuracy: 0.01)
        // A line-synced source stays line-synced.
        XCTAssertTrue(lines[1].words.isEmpty)
        XCTAssertNil(lines[1].timingSource)
    }

    func testRomanizationKeepsTheTimingToo() async throws {
        let (translator, id) = translator(try Self.recorded())
        let result = await translator.romanize(trackId: "yoru", lines: japanese, targetLanguage: "en")
        guard case .romanized(let lines, let source, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(source, "ja")
        XCTAssertEqual(lines.map(\.text), ["Open slide bring corner short slide bring", "", "hammer short fetch tablet stair nod bring"])
        XCTAssertEqual(lines.map(\.timeMs), japanese.map(\.timeMs))
        XCTAssertEqual(StubURLProtocol.requests(id).first?.formField("dt"), "rm")
    }

    func testLatinLyricsAreAlreadyRomanizedWithoutAsking() async {
        let (translator, id) = translator { _ in .ok("[]") }
        let result = await translator.romanize(trackId: "x", lines: lineSynced("already latin", "déjà"), targetLanguage: "en")
        XCTAssertEqual(result, .alreadyRomanized)
        XCTAssertTrue(StubURLProtocol.requests(id).isEmpty)
    }

    func testLyricsAlreadyInTheTargetLanguageNeedNoTranslation() async {
        let (translator, _) = translator { _ in .ok(#"[[["hello\n","hello\n",null],["\uE0000001\uE001\n","\uE0000001\uE001\n",null],["world","world",null]],null,"en"]"#) }
        let result = await translator.translate(trackId: "x", lines: lineSynced("hello", "world"), targetLanguage: "en-GB")
        XCTAssertEqual(result, .sameLanguage("en"))
    }

    func testAPartialAnswerIsDiscardedRatherThanMappedToTheWrongLines() async {
        // The marker came back missing: two slots, one part.
        let (translator, _) = translator { _ in .ok(#"[[["Grand fiddle daisy laugh lucky Pillow garden collar","x",null]],null,"ja"]"#) }
        let result = await translator.translate(trackId: "x", lines: japanese, targetLanguage: "en")
        XCTAssertEqual(result, .unavailable)
    }

    func testANetworkFailureLeavesTheOriginalOnScreen() async {
        let (translator, _) = translator { _ in .status(503) }
        let translated = await translator.translate(trackId: "x", lines: japanese, targetLanguage: "en")
        XCTAssertEqual(translated, .unavailable)
        let romanized = await translator.romanize(trackId: "x", lines: japanese, targetLanguage: "en")
        XCTAssertEqual(romanized, .unavailable)
    }

    func testNothingToTranslateIsUnavailable() async {
        let (translator, _) = translator { _ in nil }
        let empty = await translator.translate(trackId: "x", lines: [], targetLanguage: "en")
        XCTAssertEqual(empty, .unavailable)
        let blank = await translator.translate(trackId: "x", lines: japanese, targetLanguage: "  ")
        XCTAssertEqual(blank, .unavailable)
        let gaps = await translator.translate(trackId: "x", lines: [LyricLine(timeMs: 0, text: "")], targetLanguage: "en")
        XCTAssertEqual(gaps, .unavailable)
    }

    /// Latin-script Hindi that Google's NMT hands back unchanged is re-sent in its native
    /// script (via Input Tools), and the better answer is kept.
    func testUnchangedLatinScriptLyricsAreRetriedInTheirNativeScript() async throws {
        let (translator, id) = translator { request in
            if request.url?.host == "inputtools.google.com" {
                return .ok(#"["SUCCESS",[["tera hone laga hoon",["तेरा होने लगा हूँ"],[],{}]]]"#)
            }
            if request.formField("sl") == "hi" {
                return .ok(#"[[["I am becoming yours","तेरा होने लगा हूँ",null]],null,"hi"]"#)
            }
            return .ok(#"[[["tera hone laga hoon","tera hone laga hoon",null]],null,"hi"]"#)
        }
        let result = await translator.translate(trackId: "x", lines: [LyricLine(timeMs: 1_000, text: "tera hone laga hoon")], targetLanguage: "en")
        guard case .translated(let lines, let source, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(source, "hi")
        XCTAssertEqual(lines.first?.text, "I am becoming yours")
        XCTAssertEqual(StubURLProtocol.requests(id).first(where: { $0.url?.host == "inputtools.google.com" })?.formField("itc"), "hi-t-i0-und")
    }

    // MARK: Slots and batches

    func testSectionHeadersAndBackgroundVocalsAreTranslatedAsTheirOwnSlots() {
        let lines = [
            LyricLine(timeMs: 0, text: "[Chorus]"),
            LyricLine(timeMs: 1_000, text: "lead", background: LyricLine(timeMs: 1_500, text: "(echo)")),
        ]
        let slots = LyricsTranslator.flatten(lines)
        XCTAssertEqual(slots.map(\.text), ["Chorus", "lead", "(echo)"])
        XCTAssertEqual(slots.map(\.sectionHeader), [true, false, false])
        let rebuilt = LyricsTranslator.rebuild(lines, slots: slots, translated: ["Estribillo", "principal", "(eco)"])
        XCTAssertEqual(rebuilt[0].text, "[Estribillo]")
        XCTAssertEqual(rebuilt[1].text, "principal")
        XCTAssertEqual(rebuilt[1].background?.text, "(eco)")
        XCTAssertEqual(rebuilt[1].background?.timeMs, 1_500)
    }

    func testLongLyricsAreBatchedUnderTheCharacterBudget() {
        let lines = (0..<40).map { LyricLine(timeMs: $0 * 1_000, text: String(repeating: "a", count: 200)) }
        let batches = LyricsTranslator.batches(LyricsTranslator.flatten(lines))
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.map(\.slots.count).reduce(0, +), 40)
        XCTAssertTrue(batches.allSatisfy { $0.payload.utf16.count <= LyricsTranslator.maxBatchChars + 8 * $0.slots.count })
        XCTAssertTrue(batches[0].payload.contains("\u{E000}0001\u{E001}"))
    }

    func testLanguageTagsAreComparedOnTheirBaseLanguage() {
        XCTAssertEqual(LyricsTranslator.canonicalLanguage("iw"), "he")
        XCTAssertEqual(LyricsTranslator.canonicalLanguage("in"), "id")
        XCTAssertEqual(LyricsTranslator.canonicalLanguage("zh-TW"), "zh")
        XCTAssertEqual(LyricsTranslator.canonicalLanguage("pt_BR"), "pt")
        XCTAssertEqual(LyricsTranslator.canonicalLanguage("mni-Mtei"), "mni")
        XCTAssertTrue(LyricsTranslator.sameLanguage("zh-CN", "zh-TW"))
        XCTAssertFalse(LyricsTranslator.sameLanguage("ja", "en"))
    }

    func testScriptDetectionCountsLatinAgainstOtherLetters() {
        let latin = LyricsTranslator.flatten(lineSynced("tera hone laga hoon"))
        let mixed = LyricsTranslator.flatten(lineSynced("夜に駆ける and more"))
        XCTAssertTrue(LyricsTranslator.predominantlyLatin(latin))
        XCTAssertFalse(LyricsTranslator.hasNonLatinLetters(latin))
        XCTAssertTrue(LyricsTranslator.hasNonLatinLetters(mixed))
        XCTAssertFalse(LyricsTranslator.predominantlyLatin(LyricsTranslator.flatten(lineSynced("道りちほう春まいましちほう"))))
    }
}

/// The translate / romanize buttons' state machine.
@MainActor
final class LyricsTranslationToggleTests: XCTestCase {
    private let lines = [
        LyricLine(timeMs: 1_410, text: "道りちほう春まいましちほう"),
        LyricLine(timeMs: 8_920, text: "皿庭くまや魚ふ庭ふふ雨う"),
    ]

    private func controller(_ route: @escaping StubURLProtocol.Route) -> (LyricsTranslationController, String) {
        let (session, id) = StubURLProtocol.session(route)
        return (LyricsTranslationController(translator: LyricsTranslator(session: session, cacheDirectory: nil)), id)
    }

    func testTranslateThenToggleBackToTheOriginalWithoutAnotherRequest() async throws {
        let translated = try Fixture.data("translate-ja-en.json")
        let (controller, id) = controller { _ in .ok(translated) }
        controller.configure(trackId: "yoru", lines: lines, preferredLanguage: "", appLanguageTag: "en-US")
        XCTAssertEqual(controller.targetLanguage, "en")
        XCTAssertEqual(controller.targetLanguageName, "English")

        controller.toggleTranslation()
        XCTAssertEqual(controller.translationState, .loading)
        await controller.settle()
        XCTAssertTrue(controller.showingTranslation)
        XCTAssertEqual(controller.displayedLines.first?.text, "Grand fiddle daisy laugh lucky")
        XCTAssertEqual(controller.displayedLines.map(\.timeMs), lines.map(\.timeMs))
        XCTAssertEqual(controller.subLines?.count, 2)
        XCTAssertEqual(controller.transition, 1)

        controller.toggleTranslation()
        XCTAssertEqual(controller.displayMode, .original)
        XCTAssertEqual(controller.displayedLines, lines)
        XCTAssertNil(controller.subLines)
        controller.toggleTranslation()
        XCTAssertTrue(controller.showingTranslation)
        XCTAssertEqual(StubURLProtocol.requests(id).count, 1)
    }

    func testASettingsLanguageWinsOverTheAppLanguage() {
        let (controller, _) = controller { _ in nil }
        controller.configure(trackId: "t", lines: lines, preferredLanguage: "zh-TW", appLanguageTag: "es-ES")
        XCTAssertEqual(controller.targetLanguage, "zh-TW")
        XCTAssertEqual(controller.targetLanguageName, "Chinese (Traditional)")
        controller.configure(trackId: "t", lines: lines, preferredLanguage: "", appLanguageTag: "es-ES")
        XCTAssertEqual(controller.targetLanguage, "es")
    }

    func testSameLanguageAndFailureAreReportedAndLeaveTheOriginal() async {
        let (same, _) = controller { _ in .ok(#"[[["a\n","a\n",null],["\uE0000001\uE001\n","\uE0000001\uE001\n",null],["b","b",null]],null,"ja"]"#) }
        same.configure(trackId: "t", lines: lines, preferredLanguage: "ja", appLanguageTag: "en")
        same.toggleTranslation()
        await same.settle()
        XCTAssertEqual(same.translationState, .sameLanguage)
        XCTAssertEqual(same.displayMode, .original)
        XCTAssertEqual(same.notice?.kind, .alreadyInLanguage(languageName: "Japanese"))

        let (failing, _) = controller { _ in .status(500) }
        failing.configure(trackId: "t", lines: lines, preferredLanguage: "en", appLanguageTag: "en")
        failing.toggleTranslation()
        await failing.settle()
        XCTAssertEqual(failing.translationState, .idle)
        XCTAssertEqual(failing.notice?.kind, .translationUnavailable)
        let firstNotice = failing.notice?.id
        failing.toggleTranslation()
        await failing.settle()
        XCTAssertNotEqual(failing.notice?.id, firstNotice, "the same message can be shown again")
    }

    func testRomanizationIsOneModeAtATimeWithTranslation() async throws {
        let translated = try Fixture.data("translate-ja-en.json")
        let romanized = try Fixture.data("translate-ja-romanize.json")
        let (controller, _) = controller { request in request.formField("dt") == "rm" ? .ok(romanized) : .ok(translated) }
        controller.configure(trackId: "yoru", lines: lines, preferredLanguage: "en", appLanguageTag: "en")
        controller.toggleRomanization()
        await controller.settle()
        XCTAssertTrue(controller.showingRomanization)
        XCTAssertEqual(controller.subLines?.first?.text, "Open slide bring corner short slide bring")
        controller.toggleTranslation()
        await controller.settle()
        XCTAssertTrue(controller.showingTranslation)
        XCTAssertFalse(controller.showingRomanization)
    }

    func testANewTrackResetsEverything() async throws {
        let translated = try Fixture.data("translate-ja-en.json")
        let (controller, _) = controller { _ in .ok(translated) }
        controller.configure(trackId: "a", lines: lines, preferredLanguage: "en", appLanguageTag: "en")
        controller.toggleTranslation()
        await controller.settle()
        XCTAssertTrue(controller.showingTranslation)
        controller.configure(trackId: "b", lines: lines, preferredLanguage: "en", appLanguageTag: "en")
        XCTAssertEqual(controller.translationState, .idle)
        XCTAssertEqual(controller.displayMode, .original)
        XCTAssertEqual(controller.transition, 0)
    }

    func testLatinLyricsAreReportedAsAlreadyRomanized() async {
        let (controller, _) = controller { _ in nil }
        controller.configure(trackId: "t", lines: lineSynced("hello"), preferredLanguage: "en", appLanguageTag: "en")
        controller.toggleRomanization()
        await controller.settle()
        XCTAssertEqual(controller.romanizationState, .sameLanguage)
        XCTAssertEqual(controller.notice?.kind, .alreadyRomanized)
    }
}

/// The translate-into picker's language list and names.
final class TranslationLanguageTests: XCTestCase {
    func testOffersEveryGoogleTranslateLanguageWithWireCodesIntact() {
        XCTAssertEqual(TranslationLanguage.all.count, 133)
        XCTAssertEqual(Set(TranslationLanguage.all.map(\.code)).count, 133)
        let codes = Set(TranslationLanguage.all.map(\.code))
        for code in ["zh-CN", "zh-TW", "mni-Mtei", "iw", "jw", "en", "ja"] { XCTAssertTrue(codes.contains(code), code) }
    }

    func testNamesComeFromThePlatformInTheReadersLanguage() {
        XCTAssertEqual(TranslationLanguage.displayName(for: "ja", in: Locale(identifier: "en")), "Japanese")
        XCTAssertEqual(TranslationLanguage.displayName(for: "ja", in: Locale(identifier: "es")), "Japonés")
        // Script subtags are named by the curated table, not as a country.
        XCTAssertEqual(TranslationLanguage.displayName(for: "zh-CN", in: Locale(identifier: "en")), "Chinese (Simplified)")
        // Unknown to everyone: legible rather than blank.
        XCTAssertEqual(TranslationLanguage.displayName(for: "xx-Nope", in: Locale(identifier: "en")), "Xx-Nope")
    }

    func testTheTargetFollowsTheAppUnlessSettingsSaysOtherwise() {
        XCTAssertEqual(LyricsTranslationTarget.resolve(preferred: "", appLanguageTag: "fr-CA"), "fr")
        XCTAssertEqual(LyricsTranslationTarget.resolve(preferred: "zh-TW", appLanguageTag: "fr-CA"), "zh-TW")
        XCTAssertEqual(LyricsTranslationTarget.resolve(preferred: "", appLanguageTag: ""), "en")
    }
}
