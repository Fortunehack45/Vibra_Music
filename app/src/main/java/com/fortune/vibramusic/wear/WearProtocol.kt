package com.fortune.vibramusic.wear

/**
 * The wire between the phone app and the watch app.
 *
 * Two channels:
 *  - State, phone -> watch, as DataItems ([PATH_NOW_PLAYING], [PATH_QUEUE]).
 *  - Commands, watch -> phone, as messages under [PATH_COMMAND].
 */
object WearProtocol {

    /** Advertised by the phone app (res/values/wear.xml) so the watch can find it. */
    const val CAPABILITY_PHONE = "vibra_phone"

    /** Advertised by the watch app, so the phone only does the work with one around. */
    const val CAPABILITY_WATCH = "vibra_watch"

    const val PATH_NOW_PLAYING = "/vibra/now_playing"
    const val PATH_QUEUE = "/vibra/queue"
    const val PATH_COMMAND = "/vibra/command"
    const val PATH_OUTPUTS = "/vibra/outputs"

    /**
     * Phone -> watch messages driving the watch as the speaker.
     */
    const val PATH_SPEAKER = "/vibra/speaker"

    const val SPEAKER_LOAD = "load"
    const val SPEAKER_AHEAD = "ahead"
    const val SPEAKER_JUMP = "jump"
    const val SPEAKER_PLAY = "play"
    const val SPEAKER_PAUSE = "pause"
    const val SPEAKER_SEEK = "seek"
    const val SPEAKER_REPEAT = "repeat"
    const val SPEAKER_VOLUME = "volume"
    const val SPEAKER_STOP = "stop"

    const val PATH_STREAM = "/vibra/stream"
    const val PATH_WATCH_INFO_REQUEST = "/vibra/watch/info_request"
    const val PATH_WATCH_INFO = "/vibra/watch/info"
    const val KEY_VERSION_CODE = "version_code"
    const val KEY_VERSION_NAME = "version_name"
    const val KEY_APK_SHA256 = "apk_sha256"

    const val PATH_APK = "/vibra/watch/apk"

    const val STREAM_OK: Int = 0
    const val STREAM_FAILED: Int = 1

    // ---- Commands (last path segment under PATH_COMMAND) ----
    const val CMD_SYNC = "sync"
    const val CMD_TOGGLE = "toggle"
    const val CMD_NEXT = "next"
    const val CMD_PREVIOUS = "previous"
    const val CMD_LIKE = "like"
    const val CMD_SHUFFLE = "shuffle"
    const val CMD_REPEAT = "repeat"
    const val CMD_VOLUME = "volume"
    const val CMD_QUEUE = "queue"
    const val CMD_SEEK = "seek"
    const val CMD_SKIP_TO = "skip_to"
    const val CMD_OUTPUTS = "outputs"
    const val CMD_SELECT_OUTPUT = "select_output"
    const val CMD_SPEAKER_WATCH = "speaker_watch"
    const val CMD_SPEAKER_STATUS = "speaker_status"

    // ---- PATH_NOW_PLAYING keys ----
    const val KEY_HAS_TRACK = "has_track"
    const val KEY_MEDIA_ID = "media_id"
    const val KEY_TITLE = "title"
    const val KEY_ARTIST = "artist"
    const val KEY_ALBUM = "album"
    const val KEY_PLAYING = "playing"
    const val KEY_ADVANCING = "advancing"
    const val KEY_POSITION_MS = "position_ms"
    const val KEY_POSITION_AT = "position_at"
    const val KEY_DURATION_MS = "duration_ms"
    const val KEY_SPEED = "speed"
    const val KEY_HAS_PREVIOUS = "has_previous"
    const val KEY_HAS_NEXT = "has_next"
    const val KEY_LIKED = "liked"
    const val KEY_CAN_LIKE = "can_like"
    const val KEY_SHUFFLE = "shuffle"
    const val KEY_REPEAT = "repeat"
    const val KEY_COLORS = "colors"
    const val KEY_ART = "art"
    const val KEY_ART_ID = "art_id"
    const val KEY_VOLUME = "volume"
    const val KEY_VOLUME_MAX = "volume_max"

    // ---- PATH_OUTPUTS keys ----
    const val KEY_OUTPUTS = "outputs"
    const val KEY_OUTPUT_ID = "output_id"
    const val KEY_OUTPUT_NAME = "output_name"
    const val KEY_OUTPUT_KIND = "output_kind"
    const val KEY_OUTPUT_ACTIVE = "output_active"

    // ---- Watch speaker ----
    const val KEY_WATCH_SPEAKER = "watch_speaker"
    const val KEY_TRACKS = "tracks"
    const val KEY_URI = "uri"
    const val KEY_STATE = "state"

    // ---- PATH_QUEUE keys ----
    const val KEY_ITEMS = "items"
    const val KEY_INDEX = "index"
    const val KEY_CURRENT_INDEX = "current_index"
    const val KEY_QUEUE_MEDIA_ID = "queue_media_id"

    const val ART_PX = 240
    const val ROW_ART_PX = 96
}
