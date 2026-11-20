Test fixtures for StreamResolutionTests. Load with StreamFixture (StreamTestSupport.swift), which
wraps Bundle.module.url(forResource: "Fixtures/<name>", withExtension: nil).

All recorded 2026-09-26 from the live services, signed out. The machine's public IP, which
googlevideo embeds in every stream URL (ip=...), and which sw.js_data and the shell echo, was
replaced with the documentation address 2001:db8::1 in every form it appeared (raw, %-encoded,
double-%-encoded). Nothing else was edited.

player_visionos_ok.json            VISIONOS /player for dQw4w9WgXcQ: direct url formats 139/140/249/250/251
player_android_vr_ok.json          ANDROID_VR 1.65.10 /player (with visitorData): direct url formats
player_web_remix_cipher.json       WEB_REMIX /player (signatureTimestamp 20717): signatureCipher + n formats,
                                   and a playbackTracking block
player_ios_sabr_only.json          IOS 21.29.1 /player: OK, but SABR only (no url on any format)
player_visionos_age_restricted.json  VISIONOS for HtVdAasjOgU: LOGIN_REQUIRED "Sign in to confirm your age"
player_web_remix_age_unplayable.json WEB_REMIX for HtVdAasjOgU: UNPLAYABLE "Video unavailable"
player_visionos_unavailable.json   VISIONOS for a nonexistent id: ERROR "This video is unavailable"
music_shell_signed_out.html        the ytcfg.set(...) script of https://music.youtube.com/ (trimmed to it)
sw_js_data.txt                     https://www.youtube.com/sw.js_data
iframe_api.js                      https://www.youtube.com/iframe_api (names player 7460dd14)
player_ias_7460dd14.js.deflate     https://www.youtube.com/s/player/7460dd14/player_ias.vflset/en_US/base.js,
                                   raw DEFLATE (NSData.decompressed(using: .zlib))
zemer_player_configs.json          zemer-cipher's player_configs.json (GPL-3.0), which InnerTubeX also reads
botguard_create.json               https://www.youtube.com/api/jnn/v1/Create answer (scrambled challenge)
itag140_init_segment.mp4           first 1,019 bytes of dQw4w9WgXcQ itag 140 (ftyp, moov, sidx; no samples)
