import VibraMusicCore
import Replay
import SwiftUI
import Theming
import UIKit

// Ports ui/replay/ReplayPoster.kt: the Replay as one 1080 × 1920 picture, drawn rather than
// screenshotted. A story card is one fact and a screenshot would carry the status bar and the
// progress segments; the poster is the whole year (or, from a card's share button, that card),
// laid out at fixed positions on a canvas — so it is drawn with Core Graphics at Android's own
// coordinates, text placed by its baseline as Android's `drawText` places it.

enum ReplayPoster {
    static let width: CGFloat = CGFloat(replayPosterWidth)
    static let height: CGFloat = CGFloat(replayPosterHeight)
    static let margin: CGFloat = 72
    static let contentWidth = width - margin * 2
    static let headlineSize: CGFloat = 88
    static let headlineLeading: CGFloat = 108
    static let cardRows = 5
    static let columnGap: CGFloat = 36
    static let rowHeight: CGFloat = 116
    static let art: CGFloat = 84
    static let accent = UIColor(red: 0xFA / 255, green: 0x2D / 255, blue: 0x48 / 255, alpha: 1)
    static let posterRows = replayPosterSongRows
    static let posterAlbums = replayPosterAlbumCount
    static let posterGenres = replayPosterGenreCount

    /// Everything the poster shows, gathered once so the drawing is a pure function of it.
    struct Content {
        var summary: ReplaySummary
        var periodLabel: String
        var holder: String
        var memberSince: String?
        /// The story card, or nil for the whole Replay.
        var page: ReplayStoryPage?
        /// Covers by artwork URL (as they appear on the rows).
        var covers: [String: UIImage]
    }

    /// Loads the dozen covers the poster needs (together, so a cold cache is one round trip rather
    /// than twelve), then draws it.
    static func render(summary: ReplaySummary, periodLabel: String, holder: String, memberSince: String?,
                       page: ReplayStoryPage?, loader: @escaping @Sendable (String) async -> UIImage? = ReplayPoster.loadCover) async -> UIImage {
        let urls = artworkURLs(summary: summary, page: page)
        var covers: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for url in urls { group.addTask { (url, await loader(url)) } }
            for await (url, image) in group { if let image { covers[url] = image } }
        }
        let content = Content(summary: summary, periodLabel: periodLabel, holder: holder,
                              memberSince: memberSince, page: page, covers: covers)
        return await Task.detached(priority: .userInitiated) { draw(content) }.value
    }

    static func artworkURLs(summary: ReplaySummary, page: ReplayStoryPage?) -> [String] {
        // The Top Albums card draws five rows; the whole poster only three.
        let albumRows = page == .albums ? cardRows : posterAlbums
        let rows = replaySongRows(for: summary, limit: posterRows) + replayArtistRows(for: summary, limit: posterRows)
            + replayAlbumRows(for: summary, limit: albumRows)
        var urls: [String] = []
        for url in rows.compactMap(\.artworkUrl) where !urls.contains(url) { urls.append(url) }
        let (covers, faces) = ReplayCollage.pieces(summary)
        for url in covers + faces where !urls.contains(url) { urls.append(url) }
        if let page, let lit = replayStoryArtwork(for: summary, page: page), !urls.contains(lit) { urls.append(lit) }
        return urls
    }

    @Sendable static func loadCover(_ raw: String) async -> UIImage? {
        guard let url = Artwork.resized(raw, to: ArtworkSize.card).flatMap(URL.init(string:)) else { return nil }
        return await ArtworkImageCache.shared.image(for: url)
    }

    // MARK: Drawing

    static func draw(_ content: Content) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let summary = content.summary
            let songs = replaySongRows(for: summary, limit: posterRows)
            let artists = replayArtistRows(for: summary, limit: posterRows)
            let albums = replayAlbumRows(for: summary, limit: posterAlbums)
            // The same cover and turn of the wheel the card on screen was drawn with.
            let lit = content.page.flatMap { replayStoryArtwork(for: summary, page: $0) } ?? songs.first?.artworkUrl
            drawBackdrop(cg, lead: lit.flatMap { content.covers[$0] }, hue: content.page.map(replayStoryHue) ?? 0)
            var y = drawHeader(content)
            if let page = content.page {
                y = drawRuns(ReplayText.headline(page, summary: summary, periodLabel: content.periodLabel), x: margin, top: y, maxWidth: contentWidth)
                drawCard(page, content: content, top: y + 56)
            } else {
                y = drawTotals(summary, top: y)
                y = drawColumns(songs: songs, artists: artists, covers: content.covers, top: y)
                y = drawAlbums(albums, covers: content.covers, top: y)
                drawGenres(summary, top: y)
            }
            drawFooter()
        }
    }

    // MARK: Background

    /// The mesh, by hand: four wide radial gradients off the sleeve's own colours over a dark base,
    /// flattened under a vertical ink weighted to the foot.
    ///
    /// `height` is the canvas it is being drawn on: the poster passes the full frame, a card that
    /// grows with its own contents passes whatever it turned out to be. The anchors are fractions of
    /// it, so a short card gets the same composition squeezed into its rows rather than the bottom
    /// half of a poster left blank.
    static func drawBackdrop(_ cg: CGContext, lead: UIImage?, hue: Double, height: CGFloat = ReplayPoster.height) {
        let palette = (lead?.cgImage.flatMap(MeshPalette.init(image:)) ?? .fallback).rotated(degrees: Float(hue))
        let colors = MeshGradientColors(palette: palette)
        cg.setFillColor(colors.base.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let anchors: [CGPoint] = [CGPoint(x: 0.20, y: 0.16), CGPoint(x: 0.84, y: 0.22), CGPoint(x: 0.76, y: 0.66), CGPoint(x: 0.18, y: 0.78)]
        let space = CGColorSpaceCreateDeviceRGB()
        for (index, color) in colors.blobs.prefix(4).enumerated() {
            let center = CGPoint(x: width * anchors[index].x, y: height * anchors[index].y)
            let radius = width * 0.95
            let stops = [color.withAlpha(210.0 / 255).cgColor, color.withAlpha(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: stops, locations: [0, 1]) {
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
        }
        let ink = [UIColor(white: 0, alpha: 0x8C / 255).cgColor, UIColor(white: 0, alpha: 0x59 / 255).cgColor,
                   UIColor(white: 0, alpha: 0xCC / 255).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: ink, locations: [0, 0.42, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }
    }

    // MARK: Bands

    private static func drawHeader(_ content: Content) -> CGFloat {
        text(ReplayText.title(periodLabel: content.periodLabel), x: margin, baseline: 132, font: heading(46), color: .white)
        let brand = "Vibra Music"
        let brandFont = heading(46)
        text(brand, x: width - margin, baseline: 132, font: brandFont, color: white(0xE6), alignRight: true)
        // The mark to the left of the word, as the story header and the card carry it.
        let wordWidth = measure(brand, font: brandFont)
        drawLogo(right: width - margin - wordWidth - 20, baseline: 132)
        let credit = [content.holder.isEmpty ? L10n.defaultReplayHolder : content.holder,
                      content.memberSince.map(L10n.memberSinceValue)].compactMap { $0 }.joined(separator: " · ")
        text(credit.uppercased(with: ReplayText.locale), x: margin, baseline: 182, font: label(24), color: white(0x8C), tracking: 0.10)
        return 300
    }

    private static func drawTotals(_ summary: ReplaySummary, top: CGFloat) -> CGFloat {
        text(ReplayText.minutes(summary.totalMs), x: margin, baseline: top + 120, font: heading(148), color: .white)
        text(L10n.minutesListened.uppercased(with: ReplayText.locale), x: margin, baseline: top + 176, font: label(30), color: white(0xB3), tracking: 0.14)
        let totals = "\(ReplayText.plays(summary.totalPlays)) · \(ReplayText.songs(summary.distinctSongs)) · \(ReplayText.artists(summary.distinctArtists))"
        text(totals, x: margin, baseline: top + 232, font: body(30), color: white(0x99))
        return top + 320
    }

    /// Songs on the left, artists on the right as circles.
    private static func drawColumns(songs: [ReplayRow], artists: [ReplayRow], covers: [String: UIImage], top: CGFloat) -> CGFloat {
        let columnWidth = (width - margin * 2 - columnGap) / 2
        let right = margin + columnWidth + columnGap
        text(L10n.topSongs.uppercased(with: ReplayText.locale), x: margin, baseline: top, font: label(28), color: white(0xB3), tracking: 0.16)
        text(L10n.topArtists.uppercased(with: ReplayText.locale), x: right, baseline: top, font: label(28), color: white(0xB3), tracking: 0.16)
        var y = top + 54
        for index in 0..<max(songs.count, artists.count) {
            if index < songs.count { drawRow(songs[index], covers: covers, x: margin, y: y, width: columnWidth, circular: false) }
            if index < artists.count { drawRow(artists[index], covers: covers, x: right, y: y, width: columnWidth, circular: true) }
            y += rowHeight
        }
        return y + 40
    }

    private static func drawRow(_ row: ReplayRow, covers: [String: UIImage], x: CGFloat, y: CGFloat, width: CGFloat, circular: Bool) {
        text("\(row.rank)", x: x, baseline: y + art * 0.68, font: heading(34), color: row.rank == 1 ? accent : white(0x73))
        let artX = x + 44
        drawArtwork(row.artworkUrl.flatMap { covers[$0] }, fallback: row.title, x: artX, y: y, size: art, circular: circular)
        let textX = artX + art + 20
        let textWidth = width - (textX - x)
        let titleFont = body(30, bold: true)
        text(ellipsised(row.title, font: titleFont, width: textWidth), x: textX, baseline: y + 36, font: titleFont, color: .white)
        let subFont = body(25)
        let detail = [row.subtitle, ReplayText.listening(row.ms)].compactMap { $0 }.joined(separator: " · ")
        text(ellipsised(detail, font: subFont, width: textWidth), x: textX, baseline: y + 72, font: subFont, color: white(0x99))
    }

    private static func drawAlbums(_ albums: [ReplayRow], covers: [String: UIImage], top: CGFloat) -> CGFloat {
        guard !albums.isEmpty else { return top }
        text(L10n.topAlbums.uppercased(with: ReplayText.locale), x: margin, baseline: top, font: label(28), color: white(0xB3), tracking: 0.16)
        let size: CGFloat = 200
        let count = CGFloat(posterAlbums)
        let gap = (width - margin * 2 - size * count) / (count - 1)
        let y = top + 40
        for (index, album) in albums.prefix(posterAlbums).enumerated() {
            let x = margin + CGFloat(index) * (size + gap)
            drawArtwork(album.artworkUrl.flatMap { covers[$0] }, fallback: album.title, x: x, y: y, size: size, circular: false)
            let nameFont = body(25, bold: true)
            text(ellipsised(album.title, font: nameFont, width: size), x: x, baseline: y + size + 38, font: nameFont, color: .white)
            let subFont = body(22)
            text(ellipsised(album.subtitle ?? ReplayText.listening(album.ms), font: subFont, width: size), x: x, baseline: y + size + 70, font: subFont, color: white(0x8C))
        }
        return y + size + 130
    }

    private static func drawGenres(_ summary: ReplaySummary, top: CGFloat) {
        let genres = replayGenreRows(for: summary, limit: posterGenres)
        guard !genres.isEmpty else { return }
        text(L10n.topGenres.uppercased(with: ReplayText.locale), x: margin, baseline: top, font: label(28), color: white(0xB3), tracking: 0.16)
        let font = body(32, bold: true)
        var x = margin
        let y = top + 44
        for genre in genres {
            let chipWidth = measure(genre.title, font: font) + 44
            if x + chipWidth > width - margin { return }
            UIColor(white: 1, alpha: 0x26 / 255).setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: chipWidth, height: 62), cornerRadius: 31).fill()
            text(genre.title, x: x + 22, baseline: y + 42, font: font, color: .white)
            x += chipWidth + 14
        }
    }

    private static func drawFooter() {
        text(L10n.countedOnDeviceWithVibraMusic, x: margin, baseline: height - 64, font: label(24), color: white(0x73), tracking: 0.08)
    }

    // MARK: One story card

    /// The card's content under its headline — the same sentence, hero and runners-up as on screen.
    private static func drawCard(_ page: ReplayStoryPage, content: Content, top: CGFloat) {
        let summary = content.summary
        switch page {
        case .intro, .minutes: drawCollage(summary, covers: content.covers, top: top)
        case .songs: drawLeaderboard(replaySongRows(for: summary, limit: cardRows), covers: content.covers, top: top, circular: false)
        case .artists: drawLeaderboard(replayArtistRows(for: summary, limit: cardRows), covers: content.covers, top: top, circular: true)
        case .albums: drawLeaderboard(replayAlbumRows(for: summary, limit: cardRows), covers: content.covers, top: top, circular: false)
        case .genres: drawBigList(replayGenreRows(for: summary, limit: cardRows), top: top)
        case .habits: drawHabits(summary, top: top)
        case .summary: drawRecap(summary, top: top)
        }
    }

    private static func drawLeaderboard(_ rows: [ReplayRow], covers: [String: UIImage], top: CGFloat, circular: Bool) {
        guard let lead = rows.first else { return }
        let hero: CGFloat = 348
        drawArtwork(lead.artworkUrl.flatMap { covers[$0] }, fallback: lead.title, x: margin, y: top, size: hero, circular: circular)
        let textX = margin + hero + 48
        let textWidth = width - margin - textX
        let titleFont = heading(78)
        text(ellipsised(lead.title, font: titleFont, width: textWidth), x: textX, baseline: top + 86, font: titleFont, color: .white)
        var y = top + 86
        if let subtitle = lead.subtitle {
            let subFont = body(50)
            y += 62
            text(ellipsised(subtitle, font: subFont, width: textWidth), x: textX, baseline: y, font: subFont, color: white(0xB3))
        }
        text("\(ReplayText.listening(lead.ms)) · \(ReplayText.plays(lead.plays))", x: textX, baseline: y + 62, font: body(44), color: white(0x8C))

        var rowY = top + hero + 90
        for row in rows.dropFirst() {
            text("\(row.rank)", x: margin, baseline: rowY + 72, font: heading(44), color: white(0x73))
            let artX = margin + 62
            drawArtwork(row.artworkUrl.flatMap { covers[$0] }, fallback: row.title, x: artX, y: rowY, size: 108, circular: circular)
            let nameFont = body(48, bold: true)
            let nameX = artX + 108 + 28
            let statFont = body(38)
            let stat = ReplayText.listening(row.ms)
            let statWidth = measure(stat, font: statFont)
            text(ellipsised(row.title, font: nameFont, width: width - margin - nameX - statWidth - 32), x: nameX, baseline: rowY + 72, font: nameFont, color: .white)
            text(stat, x: width - margin, baseline: rowY + 72, font: statFont, color: white(0x80), alignRight: true)
            rowY += 148
        }
    }

    /// The genre card: one word, big, then the rest as a ranked list.
    private static func drawBigList(_ rows: [ReplayRow], top: CGFloat) {
        guard let lead = rows.first else { return }
        let word = heading(150)
        text(ellipsised(lead.title, font: word, width: contentWidth), x: margin, baseline: top + 120, font: word, color: .white)
        text(ReplayText.listening(lead.ms), x: margin, baseline: top + 186, font: body(46), color: white(0x99))
        var y = top + 300
        for row in rows.dropFirst() {
            text("\(row.rank)", x: margin, baseline: y, font: heading(48), color: white(0x73))
            text(row.title, x: margin + 80, baseline: y, font: body(52, bold: true), color: .white)
            text(ReplayText.listening(row.ms), x: width - margin, baseline: y, font: body(38), color: white(0x80), alignRight: true)
            y += 106
        }
    }

    private static func drawHabits(_ summary: ReplaySummary, top: CGFloat) {
        var y = top + 40
        for stat in ReplayText.habitStats(summary) {
            text(stat.value, x: margin, baseline: y, font: heading(84), color: .white)
            text(stat.label, x: margin, baseline: y + 56, font: body(42), color: white(0x99))
            y += 176
        }
    }

    private static func drawRecap(_ summary: ReplaySummary, top: CGFloat) {
        var y = top + 40
        for line in ReplayText.recapLines(summary) {
            text(line.label, x: margin, baseline: y, font: body(42), color: white(0x80))
            let valueFont = body(52, bold: true)
            text(ellipsised(line.value, font: valueFont, width: contentWidth - 320), x: margin + 320, baseline: y, font: valueFont, color: .white)
            y += 96
        }
    }

    /// The scatter of covers the opening cards are built around.
    private static func drawCollage(_ summary: ReplaySummary, covers: [String: UIImage], top: CGFloat) {
        let (squares, faces) = ReplayCollage.pieces(summary)
        let squareAt: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.30, 500), (0.02, 0.06, 260), (0.66, 0.00, 215)]
        let faceAt: [(CGFloat, CGFloat, CGFloat)] = [(0.00, 0.62, 185), (0.72, 0.32, 225), (0.46, 0.76, 200)]
        let boxHeight: CGFloat = 900
        for (index, url) in squares.enumerated() {
            let (fx, fy, size) = squareAt[index]
            drawArtwork(covers[url], fallback: "", x: margin + contentWidth * fx, y: top + boxHeight * fy, size: size, circular: false)
        }
        for (index, url) in faces.enumerated() {
            let (fx, fy, size) = faceAt[index]
            drawArtwork(covers[url], fallback: "", x: margin + contentWidth * fx, y: top + boxHeight * fy, size: size, circular: true)
        }
    }

    /// A card's sentence, wrapped greedily word by word, each word keeping the weight of the run it
    /// came from (flattened first, so a run ending mid-word doesn't grow a space). Returns the
    /// bottom of the last line.
    static func drawRuns(_ runs: [ReplayHeadlineRun], x: CGFloat, top: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let bold = heading(headlineSize)
        let plain = body(headlineSize, bold: true)
        var characters: [Character] = []
        var weights: [Bool] = []
        for run in runs {
            characters.append(contentsOf: run.text)
            weights.append(contentsOf: Array(repeating: run.bold, count: run.text.count))
        }
        var lineX = x
        var y = top + headlineSize
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace { index += 1; continue }
            var end = index
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            let word = String(characters[index..<end])
            let isBold = weights[index]
            let font = isBold ? bold : plain
            let wordWidth = measure(word + " ", font: font)
            if lineX + wordWidth - x > maxWidth, lineX > x {
                lineX = x
                y += headlineLeading
            }
            text(word, x: lineX, baseline: y, font: font, color: isBold ? .white : white(0x9E))
            lineX += wordWidth
            index = end
        }
        return y + 24
    }

    // MARK: Pieces

    /// A cover cropped square and rounded, or the lettered stand-in where one never loaded.
    static func drawArtwork(_ image: UIImage?, fallback: String, x: CGFloat, y: CGFloat, size: CGFloat, circular: Bool) {
        let bounds = CGRect(x: x, y: y, width: size, height: size)
        let radius = circular ? size / 2 : size * 0.10
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: radius)
        if let image {
            let context = UIGraphicsGetCurrentContext()
            context?.saveGState()
            path.addClip()
            let scale = size / min(image.size.width, image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: x - (drawn.width - size) / 2, y: y - (drawn.height - size) / 2, width: drawn.width, height: drawn.height))
            context?.restoreGState()
        } else {
            UIColor(Color(replayHue: replayInitialTileHue(for: fallback) / 360, saturation: 0.55, lightness: 0.45)).setFill()
            path.fill()
        }
    }

    static func drawLogo(right: CGFloat, baseline: CGFloat) {
        let logoWidth: CGFloat = 66, logoHeight: CGFloat = 44
        let configuration = UIImage.SymbolConfiguration(pointSize: logoHeight, weight: .semibold)
        guard let symbol = UIImage(systemName: ReplayLogo.symbol, withConfiguration: configuration)?
            .withTintColor(white(0xE6), renderingMode: .alwaysOriginal) else { return }
        let fitted = min(logoWidth / symbol.size.width, logoHeight / symbol.size.height)
        let size = CGSize(width: symbol.size.width * fitted, height: symbol.size.height * fitted)
        symbol.draw(in: CGRect(x: right - size.width, y: baseline - size.height, width: size.width, height: size.height))
    }

    // MARK: Type

    static func heading(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .heavy) }
    static func body(_ size: CGFloat, bold: Bool = false) -> UIFont { .systemFont(ofSize: size, weight: bold ? .semibold : .regular) }
    static func label(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .semibold) }

    static func white(_ alpha: Int) -> UIColor { UIColor(white: 1, alpha: CGFloat(alpha) / 255) }

    private static func attributes(_ font: UIFont, _ color: UIColor, tracking: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .kern: tracking * font.pointSize]
    }

    static func measure(_ string: String, font: UIFont, tracking: CGFloat = 0) -> CGFloat {
        (string as NSString).size(withAttributes: attributes(font, .white, tracking: tracking)).width
    }

    /// Draws `string` with its baseline at `baseline` (Android's `Canvas.drawText`).
    static func text(_ string: String, x: CGFloat, baseline: CGFloat, font: UIFont, color: UIColor,
                     tracking: CGFloat = 0, alignRight: Bool = false) {
        let attrs = attributes(font, color, tracking: tracking)
        let drawX = alignRight ? x - measure(string, font: font, tracking: tracking) : x
        (string as NSString).draw(at: CGPoint(x: drawX, y: baseline - font.ascender), withAttributes: attrs)
    }

    /// Trims `string` to `width` with an ellipsis, the way a single-line row would.
    static func ellipsised(_ string: String, font: UIFont, width: CGFloat) -> String {
        if measure(string, font: font) <= width { return string }
        var end = string.count
        while end > 1, measure(String(string.prefix(end)) + "…", font: font) > width { end -= 1 }
        return String(string.prefix(end)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
