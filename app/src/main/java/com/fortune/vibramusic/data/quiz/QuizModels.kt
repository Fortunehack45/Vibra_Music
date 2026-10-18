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
 * Curated popular artists with verified YouTube Music browse IDs (artwork resolved dynamically via API).
 */
val VERIFIED_CURATED_ARTISTS = listOf(
    QuizArtist("UCU6cE7pdJPc6DU2jSrKEsdQ", "Drake", null),
    QuizArtist("UCPC0L1d253x-KuMNwa05TpA", "Taylor Swift", null),
    QuizArtist("UCr61sufuLt7_eB7ak1bXHIg", "Burna Boy", null),
    QuizArtist("UClYV6hHlupm_S_ObS1W-DYw", "The Weeknd", null),
    QuizArtist("UCprAFmT0C6O4X0ToEXpeFTQ", "Kendrick Lamar", null),
    QuizArtist("UCERrDZ8oN0U_n9MphMKERcg", "Billie Eilish", null),
    QuizArtist("UC25DGtgYk5TwdksvtpeWYvA", "Wizkid", null),
    QuizArtist("UCCjfbcoH0ZYT0r1jScDHJMg", "Asake", null),
    QuizArtist("UCf_gP4AMRSgAfyzbkeS9k4g", "Travis Scott", null),
    QuizArtist("UCeKDV9JgivrXehVluw5bKFA", "SZA", null),
    QuizArtist("UCyD3XWRK9ko-izf2nBSFitw", "Post Malone", null),
    QuizArtist("UC0076UMUgEng8HORUw_MYHA", "Ariana Grande", null),
)

