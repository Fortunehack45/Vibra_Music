Test fixtures for LyricsTests. Load with Bundle.module.url(forResource: "Fixtures/<name>", withExtension: nil).

Recorded from the live services on 2026-09-26 (trimmed only where noted):
  lrclib-get-get-lucky.json, lrclib-search-get-lucky.json (first 4 synced hits + 1 unsynced),
                                                       GET lrclib.net/api/get|search
  betterlyrics-get-lucky.json                          GET lyrics-api.boidu.dev/getLyrics
  betterlyrics-portato-401.json / -404.json            GET lyrics-api.boidu.dev/qq/getLyrics (Portato refuses today)
  binilyrics-search-get-lucky.json, binilyrics-USQX91300809.ttml   lyrics-api.binimum.org (redirects to lrc.red)
  paxsenix-apple-search-get-lucky.json                 amp-api.music.apple.com catalog search
  paxsenix-apple-lyrics-1459540658.json                lyrics.paxsenix.org/apple-music/lyrics
  lyricsplus-get-lucky.json, lyricsplus-mirror-402.json lyricsplus.binimum.org / a Vercel mirror out of credit
  unison-golden-hour.json, unison-404.json             unison.boidu.dev/lyrics
  kugou-*.json                                         mobileservice.kugou.com + lyrics.kugou.com
  musixmatch-*.json                                    apic.musixmatch.com (user_token redacted)
  genius-search-get-lucky.json                         genius.com/api/search/multi
  genius-page-get-lucky.html                           genius.com song page, trimmed to the lyrics root
  youtube-next-4D7u5KF7SP8.json                        music.youtube.com next, trimmed to the tab renderers
  youtube-browse-lyrics-4D7u5KF7SP8.json               music.youtube.com browse (Lyrics tab)
  translate-ja-en.json, translate-ja-romanize.json     translate.googleapis.com translate_a/single (dt=t / dt=rm)
  simpmusic-403.html                                   api-lyrics.simpmusic.org answering this network with a Cloudflare block
  megalobiz-searchall-404.json                         the /searchall endpoint Android uses (404)

From the Wayback Machine (www.megalobiz.com timed out on 2026-09-26):
  megalobiz-search-thriller-archived.html              /search/all?qry=thriller, captured 2024-02-05
  megalobiz-lrc-all-out-of-love-archived.html          /lrc/maker/"All Out Of Love".55503798, captured 2025-05-12

Constructed (the live service was unreachable from this network):
  simpmusic-get-lucky-constructed.json                 shaped after the server's published OpenAPI schema
                                                       (DocsLyricsListResponseSuccess / LyricResponseDTO in
                                                       github.com/maxrave-dev/lyrics-frontend src/data/openapi.json:
                                                       {"success": true, "data": [...]}), rich sync HTML-escaped
                                                       the way the Android comments describe
