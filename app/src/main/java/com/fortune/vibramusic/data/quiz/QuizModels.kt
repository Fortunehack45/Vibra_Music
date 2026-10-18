package com.fortune.vibramusic.data.quiz

import com.fortune.vibramusic.data.model.Song
import kotlinx.serialization.Serializable

enum class QuizGameState {
    IDLE,
    COUNTDOWN,
    QUESTION_ACTIVE,
    QUESTION_ANSWERED,
    COMPLETED,
}

/**
 * An artist eligible for a music quiz.
 */
@Serializable
data class QuizArtist(
    val id: String,
    val name: String,
    val avatarUrl: String? = null,
    val artworkUrl: String? = avatarUrl,
)

/**
 * A single multiple choice question in the 10-question music quiz.
 */
data class QuizQuestion(
    val targetSong: Song,
    val options: List<String>, // 4 choices: song titles
    val correctOptionIndex: Int,
    val previewStreamUrl: String? = null,
)

/**
 * Active game session tracking time and score.
 */
data class QuizGameSession(
    val artist: QuizArtist,
    val questions: List<QuizQuestion>,
    val currentIndex: Int = 0,
    val correctCount: Int = 0,
    val startTimeMs: Long = 0L,
    val elapsedTimeMs: Long = 0L,
    val isFinished: Boolean = false,
) {
    val totalQuestions: Int get() = questions.size
    val currentQuestion: QuizQuestion? get() = questions.getOrNull(currentIndex)
    val remainingQuestions: Int get() = (totalQuestions - currentIndex).coerceAtLeast(0)
}

/**
 * Verified final result of a completed quiz session.
 */
@Serializable
data class QuizScoreResult(
    val id: String = "",
    val userId: String,
    val artistId: String,
    val artistName: String,
    val artistAvatar: String? = null,
    val score: Int,
    val totalQuestions: Int = 10,
    val timeSeconds: Double,
    val percentile: Int = 50,
    val rank: Int? = null,
    val createdAt: String = "",
) {
    val artistArtworkUrl: String? get() = artistAvatar
    val totalTimeMillis: Long get() = (timeSeconds * 1000).toLong()
    val percentileRank: String get() = "Top $percentile%"
}

/**
 * Daily lives and referral unlock state.
 */
@Serializable
data class QuizLivesState(
    val remainingLives: Int = 5,
    val nextRefillMillis: Long = 0L,
    val isUnlimited: Boolean = false,
    val referralCode: String = "",
    val invitesCount: Int = 0,
    val requiredInvitesForUnlimited: Int = 2,
) {
    val canPlay: Boolean get() = isUnlimited || remainingLives > 0
    val livesRemaining: Int get() = remainingLives
    val maxLives: Int get() = 5
    val refillTimeMillisRemaining: Long get() = (nextRefillMillis - System.currentTimeMillis()).coerceAtLeast(0L)
}

/**
 * An entry on the Artist Leaderboard.
 */
@Serializable
data class LeaderboardEntry(
    val id: String = "",
    val rank: Int,
    val userId: String,
    val handle: String,
    val displayName: String,
    val avatarUrl: String? = null,
    val score: Int,
    val totalQuestions: Int = 10,
    val timeSeconds: Double,
    val isCurrentUser: Boolean = false,
    val createdAt: String = "",
) {
    val userName: String get() = displayName
    val userHandle: String get() = handle
    val userAvatar: String? get() = avatarUrl
    val totalTimeMillis: Long get() = (timeSeconds * 1000).toLong()
}

/**
 * Curated popular artists with verified YouTube Music browse IDs and high-resolution artwork.
 */
val VERIFIED_CURATED_ARTISTS = listOf(
    QuizArtist("UCU6cE7pdJPc6DU2jSrKEsdQ", "Drake", "https://yt3.googleusercontent.com/MxNjcRJ-uK4Xvx7u90IhEFLQM8x9LIGTA9VCKHq5U4Wn2jOgiWaMtg-qz329SIzqnCyhdCCB3MpdAGs=w540-h540-p-l90-rj"),
    QuizArtist("UCPC0L1d253x-KuMNwa05TpA", "Taylor Swift", "https://yt3.googleusercontent.com/RCpTA6EXJQyjVFDosWOKa2SMmqkua_lA9mHPDWWciLwgqpZLz-k8rXWRF_367trrQ7up9BUwCbk6kRk=w540-h540-p-l90-rj"),
    QuizArtist("UCr61sufuLt7_eB7ak1bXHIg", "Burna Boy", "https://lh3.googleusercontent.com/_QE_u2AbzzmENeNq9ixrSpB_dZHCgX1sX9_4NAzGIWTR8Gd6jHpGcUZlmG4ZjA97F7pHrErkFOdNfw=w540-h540-p-l90-rj"),
    QuizArtist("UClYV6hHlupm_S_ObS1W-DYw", "The Weeknd", "https://lh3.googleusercontent.com/U-SAmNOu4TynE818gLCfKsuHZ0U5YNEtO9mrjSI9WCCKERs98LzrCal5kajBBTQNwdcisoB2Bn-pHp4=w540-h540-p-l90-rj"),
    QuizArtist("UCprAFmT0C6O4X0ToEXpeFTQ", "Kendrick Lamar", "https://yt3.googleusercontent.com/uB8Magh99SvDyT_mcDYeNYxlVZ_F9WN-cJtAFMHw_Q-_N_8y5-uZiay8-EZSKKloNoWxymBzVehSF4PN=w540-h540-p-l90-rj"),
    QuizArtist("UCERrDZ8oN0U_n9MphMKERcg", "Billie Eilish", "https://lh3.googleusercontent.com/tQC4rOL6xz6FhmFr0ggQExxyGbYSOsyveXVSnPBh2WjEyIzQ9pMHablLJ-0GlMBrLBlBrbWQGmzrV6KN=w540-h540-p-l90-rj"),
    QuizArtist("UC25DGtgYk5TwdksvtpeWYvA", "Wizkid", "https://yt3.googleusercontent.com/dQgIc1h2NbMRCL4J8swMlXCVPvyvbOQlRu94k__cGSJ45lvdORXRBFVcCJmcvkDVMCOFoRz2znUk9Q=w540-h540-p-l90-rj"),
    QuizArtist("UCCjfbcoH0ZYT0r1jScDHJMg", "Asake", "https://yt3.googleusercontent.com/05DKB1O6aaWS7E36alLqe7w9qIexy3YnVp0nHFT9Gz9ot7lRKLBRUioKREDdLmWuOH5jgWfX_Q=w540-h540-p-l90-rj"),
    QuizArtist("UCf_gP4AMRSgAfyzbkeS9k4g", "Travis Scott", "https://yt3.googleusercontent.com/r9k_FpAswxhQnl_cudiaT2ocWFccR6SzEFXgZ9a12iR5eDPSILlIL2EQewyQ-yYSt1JFyH1pqnoBXxs=w540-h540-p-l90-rj"),
    QuizArtist("UCeKDV9JgivrXehVluw5bKFA", "SZA", "https://lh3.googleusercontent.com/c-ILO8kXxjY6HhqSkoClWPUtPfHYQW6iHr51EiQOaZiUZ7IZr_WwwkyqclAOFyZgLpC3R0dPXuZiRt0=w540-h540-p-l90-rj"),
    QuizArtist("UCyD3XWRK9ko-izf2nBSFitw", "Post Malone", "https://lh3.googleusercontent.com/48LfK4z6o-CCEWgHQnQfg0ltcT9tbZSN0qjSh0FSJsJI5GF48j2-pH219ciG1ML-PI80ZGD4Vz6sjg=w540-h540-p-l90-rj"),
    QuizArtist("UC0076UMUgEng8HORUw_MYHA", "Ariana Grande", "https://yt3.googleusercontent.com/DU6Kpr5TYKcW6QHvMnsJau5_8QSuix8LCLtf5UEaziZZdXw8SxvcxJ9YWmVIQuzhg2R-MVHYgjdGCQ=w540-h540-p-l90-rj"),
)

