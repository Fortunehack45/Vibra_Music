import Foundation

// Ports localizeShelfTitle / localizeShelfSubtitle / localizeCardSubtitle from
// ui/screens/HomeScreen.kt.
//
// YouTube answers in the language the request asked for, but a few shelf names come back in
// English (or Vietnamese / Japanese) whatever was asked, so the app maps the ones it knows onto its
// own translations. Anything else is shown exactly as YouTube sent it.

enum ShelfLocalization {
    private static func matches(_ text: String, _ candidates: String...) -> Bool {
        candidates.contains { text.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// A shelf heading in the app's language.
    static func title(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(trimmed, "Recents", "Recently played", "Gần đây", "最近") { return L10n.shelfRecents }
        if matches(trimmed, "Playlists", "Danh sách phát", "再生リスト") { return L10n.playlists }
        if matches(trimmed, "Albums", "Album", "アルバム") { return L10n.albums }
        if matches(trimmed, "Artists", "Nghệ sĩ", "アーティスト") { return L10n.artists }
        if matches(trimmed, "Subscriptions", "Đã đăng ký", "登録チャンネル") { return L10n.subscriptions }
        if matches(trimmed, "Trending community playlists", "Danh sách phát cộng đồng thịnh hành",
                   "Danh sách phát thịnh hành trong cộng đồng người dùng", "急上昇のコミュニティ再生リスト") {
            return L10n.shelfTrendingCommunityPlaylists
        }
        if matches(trimmed, "Featured playlists for you", "Danh sách phát đề xuất cho bạn",
                   "Danh sách phát nổi bật dành cho bạn", "おすすめの再生リスト") {
            return L10n.shelfFeaturedPlaylistsForYou
        }
        if matches(trimmed, "Quick picks", "Lựa chọn nhanh", "Chọn nhanh đài phát", "クイック ミックス") { return L10n.shelfQuickPicks }
        if matches(trimmed, "Listen again", "Nghe lại", "もう一度聴く") { return L10n.shelfListenAgain }
        if matches(trimmed, "Mixed for you", "Dành riêng cho bạn", "ミックス") { return L10n.shelfMixedForYou }
        if let rest = trimmed.droppingPrefix("Similar to") { return L10n.shelfSimilarTo(rest) }
        if let rest = trimmed.droppingPrefix("Tương tự như") { return L10n.shelfSimilarTo(rest) }
        if matches(trimmed, "Forgotten favorites", "Giai điệu quen thuộc", "よく聴いたお気に入りの曲") { return L10n.shelfForgottenFavorites }
        if matches(trimmed, "Recommended music videos", "Video âm nhạc đề xuất", "おすすめのミュージック ビデオ") {
            return L10n.shelfRecommendedMusicVideos
        }
        if matches(trimmed, "From your library", "Từ thư viện của bạn", "ライブラリから") { return L10n.shelfFromYourLibrary }
        if matches(trimmed, "Charts", "Bảng xếp hạng", "チャート") { return L10n.shelfCharts }
        if matches(trimmed, "New releases", "Bản phát hành mới", "最新リリース") { return L10n.shelfNewReleases }
        if matches(trimmed, "Top music videos", "Video âm nhạc hàng đầu", "人気のミュージック ビデオ") { return L10n.shelfTopMusicVideos }
        if matches(trimmed, "For you", "Dành cho bạn", "あなたへのおすすめ") { return L10n.shelfForYou }
        if matches(trimmed, "Hits today", "Today's Hits", "Bản hit hôm nay", "今日のヒット曲") { return L10n.shelfHitsToday }
        if matches(trimmed, "Artists on the rise", "Nghệ sĩ đang lên") { return L10n.shelfArtistsOnTheRise }
        if matches(trimmed, "Concerts", "Buổi hòa nhạc", "コンサート") { return L10n.shelfConcerts }
        if trimmed.lowercased().hasPrefix("shorts") || matches(trimmed, "Shorts nổi bật", "ショート") { return L10n.shelfShorts }
        if matches(trimmed, "Trending", "Thịnh hành", "急上昇") { return L10n.shelfTrending }
        return title
    }

    /// A shelf's strapline in the app's language.
    static func subtitle(_ subtitle: String) -> String {
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches(trimmed, "TOP TUNES RIGHT NOW", "Top tunes right now", "Giai điệu hàng đầu hiện nay", "注目の曲") {
            return L10n.shelfTopTunesRightNow
        }
        if matches(trimmed, "From the community", "Từ cộng đồng", "コミュニティより") { return L10n.shelfFromTheCommunity }
        if matches(trimmed, "YouTube Charts", "Bảng xếp hạng YouTube", "YouTube チャート") { return L10n.shelfYoutubeCharts }
        return subtitle
    }

    /// A card's "Song • Artist • 1.2M plays" line, with the type words and tallies translated.
    static func cardSubtitle(_ subtitle: String) -> String {
        guard !subtitle.trimmingCharacters(in: .whitespaces).isEmpty else { return subtitle }
        let delimiter = " • "
        return subtitle.components(separatedBy: delimiter).map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if matches(trimmed, "Song", "Titre", "Bài hát", "曲") { return L10n.shelfSongItem }
            if matches(trimmed, "Single", "Đĩa đơn", "シングル") { return L10n.shelfSingle }
            if matches(trimmed, "Chart", "Bảng xếp hạng", "チャート") { return L10n.shelfChart }
            if matches(trimmed, "Playlist", "Danh sách phát", "再生リスト") { return L10n.playlist }
            if [" views", " view", " lượt xem", " 回視聴", "回視聴"].contains(where: lower.hasSuffix) {
                return tally(trimmed, fallback: part, format: L10n.cardViewsFormat)
            }
            if [" plays", " play", " lượt phát", " 回再生", "回再生"].contains(where: lower.hasSuffix) {
                return tally(trimmed, fallback: part, format: L10n.cardPlaysFormat)
            }
            if [" songs", " song", " bài hát", " 曲", "曲"].contains(where: lower.hasSuffix) {
                return tally(trimmed, fallback: part, format: L10n.cardSongsFormat)
            }
            return part
        }.joined(separator: delimiter)
    }

    /// Kotlin's `substringBeforeLast(' ', "")`: the count ahead of the unit, when there is one.
    private static func tally(_ text: String, fallback: String, format: (String) -> String) -> String {
        guard let space = text.lastIndex(of: " ") else { return fallback }
        let count = text[..<space].trimmingCharacters(in: .whitespaces)
        return count.contains(where: \.isNumber) ? format(count) : fallback
    }
}

private extension String {
    /// The rest of the string after `prefix` (case-insensitive), trimmed; nil if it doesn't start so.
    func droppingPrefix(_ prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
