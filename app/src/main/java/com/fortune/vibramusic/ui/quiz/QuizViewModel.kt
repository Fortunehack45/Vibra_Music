package com.fortune.vibramusic.ui.quiz

import android.app.Application
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.innertube.StreamResolver
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.quiz.LeaderboardEntry
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.quiz.QuizAudioEngine
import com.fortune.vibramusic.data.quiz.QuizGameSession
import com.fortune.vibramusic.data.quiz.QuizGameState
import com.fortune.vibramusic.data.quiz.QuizLivesState
import com.fortune.vibramusic.data.quiz.QuizQuestion
import com.fortune.vibramusic.data.quiz.QuizScoreResult
import com.fortune.vibramusic.data.supabase.SupabaseService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

import com.fortune.vibramusic.auth.AuthStore
import com.fortune.vibramusic.data.quiz.QuizLivesManager
import com.fortune.vibramusic.data.settings.AppSettings

class QuizViewModel(application: Application) : AndroidViewModel(application) {

    private val TAG = "QuizViewModel"
    val audioEngine = QuizAudioEngine(application)
    val livesManager = QuizLivesManager(application)
    private val authStore = AuthStore(application)

    private val _gameState = MutableStateFlow(QuizGameState.IDLE)
    val gameState: StateFlow<QuizGameState> = _gameState.asStateFlow()

    private val _currentArtist = MutableStateFlow<QuizArtist?>(null)
    val currentArtist: StateFlow<QuizArtist?> = _currentArtist.asStateFlow()

    private val _countdownNumber = MutableStateFlow(3)
    val countdownNumber: StateFlow<Int> = _countdownNumber.asStateFlow()

    private val _questions = MutableStateFlow<List<QuizQuestion>>(emptyList())
    private val _currentQuestionIndex = MutableStateFlow(0)
    val currentQuestionIndex: StateFlow<Int> = _currentQuestionIndex.asStateFlow()

    val currentQuestion = MutableStateFlow<QuizQuestion?>(null)
    val totalQuestions = MutableStateFlow(10)

    private val _selectedOptionIndex = MutableStateFlow<Int?>(null)
    val selectedOptionIndex: StateFlow<Int?> = _selectedOptionIndex.asStateFlow()

    private val _isCorrect = MutableStateFlow<Boolean?>(null)
    val isCorrect: StateFlow<Boolean?> = _isCorrect.asStateFlow()

    private val _elapsedQuestionMillis = MutableStateFlow(0L)
    val elapsedQuestionMillis: StateFlow<Long> = _elapsedQuestionMillis.asStateFlow()

    private val _totalTimerMillis = MutableStateFlow(0L)
    val totalTimerMillis: StateFlow<Long> = _totalTimerMillis.asStateFlow()

    private val _lastResult = MutableStateFlow<QuizScoreResult?>(null)
    val lastResult: StateFlow<QuizScoreResult?> = _lastResult.asStateFlow()

    val livesState: StateFlow<QuizLivesState> = livesManager.livesState

    private val _isPreparingQuiz = MutableStateFlow(false)
    val isPreparingQuiz: StateFlow<Boolean> = _isPreparingQuiz.asStateFlow()

    private var timerJob: Job? = null
    private var questionStartTimestamp = 0L
    private var totalStartTimestamp = 0L
    private var correctAnswersCount = 0

    private val streamCache = java.util.concurrent.ConcurrentHashMap<String, String>()

    fun startQuizForArtist(
        artist: QuizArtist,
        onInsufficientLives: () -> Unit,
    ) {
        if (!livesManager.consumeLife()) {
            onInsufficientLives()
            return
        }

        _currentArtist.value = artist
        _isPreparingQuiz.value = true
        _selectedOptionIndex.value = null
        _isCorrect.value = null
        _lastResult.value = null
        correctAnswersCount = 0
        streamCache.clear()

        viewModelScope.launch {
            // Fetch artist tracks
            val discography = fetchArtistSongs(artist)
            if (discography.size < 4) {
                Log.w(TAG, "Not enough songs for quiz: ${discography.size}")
                _isPreparingQuiz.value = false
                return@launch
            }

            // Pick 10 target tracks randomly
            val targets = discography.shuffled().take(10)
            val questionList = targets.map { target ->
                val otherSongs = discography.filter { it.videoId != target.videoId }.shuffled().take(3)
                val choices = (otherSongs + target).shuffled()
                val correctIdx = choices.indexOfFirst { it.videoId == target.videoId }.coerceAtLeast(0)
                QuizQuestion(
                    targetSong = target,
                    options = choices.map { it.title },
                    correctOptionIndex = correctIdx,
                )
            }

            _questions.value = questionList
            totalQuestions.value = questionList.size
            _currentQuestionIndex.value = 0
            currentQuestion.value = questionList.firstOrNull()
            _isPreparingQuiz.value = false

            // Countdown Phase - Pre-buffer Question 0 during countdown so playback is 0ms instant!
            _gameState.value = QuizGameState.COUNTDOWN
            val firstQuestion = questionList.firstOrNull()
            launch(Dispatchers.IO) {
                if (firstQuestion != null) {
                    val url = runCatching { StreamResolver.resolve(firstQuestion.targetSong.videoId) }.getOrNull()
                    if (url != null) {
                        streamCache[firstQuestion.targetSong.videoId] = url
                        withContext(Dispatchers.Main) {
                            if (_gameState.value == QuizGameState.COUNTDOWN) {
                                audioEngine.prepareSnippet(url, startPositionMs = 25_000L)
                            }
                        }
                    }
                }
            }

            for (c in 3 downTo 1) {
                _countdownNumber.value = c
                delay(800)
            }
            _countdownNumber.value = 0
            delay(400)

            // Start Questions
            totalStartTimestamp = SystemClock.elapsedRealtime()
            startQuestion(0)
        }
    }

    private fun startQuestion(index: Int) {
        val q = _questions.value.getOrNull(index) ?: run {
            finishQuiz()
            return
        }

        _currentQuestionIndex.value = index
        currentQuestion.value = q
        _selectedOptionIndex.value = null
        _isCorrect.value = null
        _gameState.value = QuizGameState.QUESTION_ACTIVE

        questionStartTimestamp = SystemClock.elapsedRealtime()
        startLiveTimer()

        // 1. Play mystery 15s audio snippet immediately
        if (index == 0 && audioEngine.isSnippetPrepared()) {
            audioEngine.startPreparedSnippet()
        } else {
            val cachedUrl = streamCache[q.targetSong.videoId]
            if (cachedUrl != null) {
                audioEngine.playSnippet(cachedUrl, startPositionMs = 25_000L)
            } else {
                viewModelScope.launch {
                    val resolvedUrl = withContext(Dispatchers.IO) {
                        runCatching { StreamResolver.resolve(q.targetSong.videoId) }.getOrNull()
                    }
                    if (resolvedUrl != null) {
                        streamCache[q.targetSong.videoId] = resolvedUrl
                        if (_gameState.value == QuizGameState.QUESTION_ACTIVE && _currentQuestionIndex.value == index) {
                            audioEngine.playSnippet(resolvedUrl, startPositionMs = 25_000L)
                        }
                    }
                }
            }
        }

        // 2. Pre-fetch the NEXT question's audio stream in background so question N+1 is instant
        val nextQ = _questions.value.getOrNull(index + 1)
        if (nextQ != null && !streamCache.containsKey(nextQ.targetSong.videoId)) {
            viewModelScope.launch(Dispatchers.IO) {
                val nextUrl = runCatching { StreamResolver.resolve(nextQ.targetSong.videoId) }.getOrNull()
                if (nextUrl != null) {
                    streamCache[nextQ.targetSong.videoId] = nextUrl
                }
            }
        }
    }

    fun selectOption(index: Int) {
        if (_gameState.value != QuizGameState.QUESTION_ACTIVE) return
        val q = currentQuestion.value ?: return

        _selectedOptionIndex.value = index
        val correct = index == q.correctOptionIndex
        _isCorrect.value = correct
        if (correct) correctAnswersCount++

        _gameState.value = QuizGameState.QUESTION_ANSWERED
        audioEngine.stop()

        viewModelScope.launch {
            delay(1200) // Delay to show feedback before moving to next question
            val nextIdx = _currentQuestionIndex.value + 1
            if (nextIdx < _questions.value.size) {
                startQuestion(nextIdx)
            } else {
                finishQuiz()
            }
        }
    }

    private fun finishQuiz() {
        stopLiveTimer()
        audioEngine.stop()
        val totalTime = SystemClock.elapsedRealtime() - totalStartTimestamp
        val artist = _currentArtist.value ?: return

        val percentile = calculatePercentile(correctAnswersCount, totalTime)

        val session = authStore.activeSession ?: authStore.sessions.firstOrNull()
        val activeUserId = session?.activeProfileId
            ?: session?.profiles?.firstOrNull()?.profileId
            ?: session?.accountId
            ?: AppSettings.deviceUserId

        val result = QuizScoreResult(
            id = UUID.randomUUID().toString(),
            userId = activeUserId,
            artistId = artist.id,
            artistName = artist.name,
            artistAvatar = artist.artworkUrl,
            score = correctAnswersCount,
            totalQuestions = _questions.value.size,
            timeSeconds = totalTime / 1000.0,
            percentile = percentile,
        )

        _lastResult.value = result
        _gameState.value = QuizGameState.COMPLETED

        // Submit to Supabase leaderboard
        viewModelScope.launch {
            SupabaseService.submitQuizScore(result)
        }
    }

    fun abandonQuiz() {
        stopLiveTimer()
        audioEngine.stop()
        streamCache.clear()
        _gameState.value = QuizGameState.IDLE
        _lastResult.value = null
        _currentArtist.value = null
    }

    private fun startLiveTimer() {
        timerJob?.cancel()
        timerJob = viewModelScope.launch(Dispatchers.Default) {
            while (isActive) {
                val now = SystemClock.elapsedRealtime()
                _elapsedQuestionMillis.value = now - questionStartTimestamp
                _totalTimerMillis.value = now - totalStartTimestamp

                // Auto timeout after 15 seconds
                if (_elapsedQuestionMillis.value >= 15000L && _gameState.value == QuizGameState.QUESTION_ACTIVE) {
                    withContext(Dispatchers.Main) {
                        selectOption(-1) // Timeout counts as incorrect
                    }
                }
                delay(16) // ~60fps smooth ticker
            }
        }
    }

    private fun stopLiveTimer() {
        timerJob?.cancel()
        timerJob = null
    }

    private fun calculatePercentile(score: Int, timeMillis: Long): Int {
        val basePercentile = (score * 9.5).toInt().coerceIn(10, 99)
        val timeBonus = if (timeMillis < 25000L) 5 else 0
        return (basePercentile + timeBonus).coerceIn(1, 99)
    }

    private suspend fun fetchArtistSongs(artist: QuizArtist): List<Song> = withContext(Dispatchers.IO) {
        runCatching {
            val page = YtMusicRepository.artistPage(artist.id).getOrNull()
            val songsFromPage = page?.songs.orEmpty()
            if (songsFromPage.size >= 4) return@withContext songsFromPage

            // Fallback search by artist name
            val search = YtMusicRepository.search(artist.name, SearchFilter.SONGS).getOrNull().orEmpty()
            val songsFromSearch = search.mapNotNull { result ->
                when (result) {
                    is SearchResult.Track -> result.song
                    is SearchResult.TopTrack -> result.song
                    else -> null
                }
            }
            if (songsFromSearch.isNotEmpty()) {
                songsFromPage + songsFromSearch
            } else {
                songsFromPage
            }
        }.getOrDefault(emptyList())
    }

    override fun onCleared() {
        super.onCleared()
        audioEngine.release()
        stopLiveTimer()
    }
}
