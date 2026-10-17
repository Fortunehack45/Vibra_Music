package com.fortune.vibramusic.data.quiz

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Manages persistent quiz lives, consumption, and automatic 30-minute time-based refilling.
 * Maximum lives: 5. Refill rate: 1 life every 30 minutes.
 */
class QuizLivesManager(private val context: Context) {

    private val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val scope = CoroutineScope(Dispatchers.Default)
    private var tickerJob: Job? = null

    private val _livesState = MutableStateFlow(loadInitialState())
    val livesState: StateFlow<QuizLivesState> = _livesState.asStateFlow()

    init {
        recalculateLives()
        startTicker()
    }

    private fun loadInitialState(): QuizLivesState {
        val lives = prefs.getInt(KEY_LIVES, MAX_LIVES)
        val lastRefill = prefs.getLong(KEY_LAST_REFILL, System.currentTimeMillis())
        val isUnlimited = prefs.getBoolean(KEY_IS_UNLIMITED, false)
        val invites = prefs.getInt(KEY_INVITES, 0)
        val code = prefs.getString(KEY_REFERRAL_CODE, null) ?: "vibra_${System.currentTimeMillis() % 1000000}"

        return QuizLivesState(
            remainingLives = lives.coerceIn(0, MAX_LIVES),
            nextRefillMillis = lastRefill + REFILL_INTERVAL_MILLIS,
            isUnlimited = isUnlimited,
            referralCode = code,
            invitesCount = invites,
            requiredInvitesForUnlimited = 2,
        )
    }

    @Synchronized
    fun recalculateLives() {
        val isUnlimited = prefs.getBoolean(KEY_IS_UNLIMITED, false)
        if (isUnlimited) {
            _livesState.value = _livesState.value.copy(
                remainingLives = MAX_LIVES,
                isUnlimited = true,
                nextRefillMillis = 0L,
            )
            return
        }

        val currentLives = prefs.getInt(KEY_LIVES, MAX_LIVES)
        if (currentLives >= MAX_LIVES) {
            val now = System.currentTimeMillis()
            prefs.edit().putLong(KEY_LAST_REFILL, now).apply()
            _livesState.value = _livesState.value.copy(
                remainingLives = MAX_LIVES,
                nextRefillMillis = now + REFILL_INTERVAL_MILLIS,
            )
            return
        }

        val now = System.currentTimeMillis()
        val lastRefill = prefs.getLong(KEY_LAST_REFILL, now)
        val elapsed = now - lastRefill

        if (elapsed >= REFILL_INTERVAL_MILLIS) {
            val livesGained = (elapsed / REFILL_INTERVAL_MILLIS).toInt()
            val newLives = (currentLives + livesGained).coerceAtMost(MAX_LIVES)
            val updatedLastRefill = if (newLives >= MAX_LIVES) {
                now
            } else {
                lastRefill + (livesGained * REFILL_INTERVAL_MILLIS)
            }

            prefs.edit()
                .putInt(KEY_LIVES, newLives)
                .putLong(KEY_LAST_REFILL, updatedLastRefill)
                .apply()

            _livesState.value = _livesState.value.copy(
                remainingLives = newLives,
                nextRefillMillis = if (newLives >= MAX_LIVES) 0L else updatedLastRefill + REFILL_INTERVAL_MILLIS,
            )
        } else {
            _livesState.value = _livesState.value.copy(
                remainingLives = currentLives,
                nextRefillMillis = lastRefill + REFILL_INTERVAL_MILLIS,
            )
        }
    }

    @Synchronized
    fun consumeLife(): Boolean {
        recalculateLives()
        val current = _livesState.value
        if (current.isUnlimited) return true
        if (current.remainingLives <= 0) return false

        val newLives = current.remainingLives - 1
        val now = System.currentTimeMillis()
        val lastRefill = if (current.remainingLives == MAX_LIVES) now else prefs.getLong(KEY_LAST_REFILL, now)

        prefs.edit()
            .putInt(KEY_LIVES, newLives)
            .putLong(KEY_LAST_REFILL, lastRefill)
            .apply()

        _livesState.value = current.copy(
            remainingLives = newLives,
            nextRefillMillis = lastRefill + REFILL_INTERVAL_MILLIS,
        )
        return true
    }

    fun refillAllLives() {
        val now = System.currentTimeMillis()
        prefs.edit()
            .putInt(KEY_LIVES, MAX_LIVES)
            .putLong(KEY_LAST_REFILL, now)
            .apply()

        _livesState.value = _livesState.value.copy(
            remainingLives = MAX_LIVES,
            nextRefillMillis = now + REFILL_INTERVAL_MILLIS,
        )
    }

    fun unlockUnlimited() {
        prefs.edit()
            .putBoolean(KEY_IS_UNLIMITED, true)
            .putInt(KEY_LIVES, MAX_LIVES)
            .apply()

        _livesState.value = _livesState.value.copy(
            isUnlimited = true,
            remainingLives = MAX_LIVES,
            nextRefillMillis = 0L,
        )
    }

    private fun startTicker() {
        tickerJob?.cancel()
        tickerJob = scope.launch {
            while (isActive) {
                delay(1000)
                recalculateLives()
            }
        }
    }

    companion object {
        private const val PREFS_NAME = "vibra_quiz_lives_prefs"
        private const val KEY_LIVES = "quiz_remaining_lives"
        private const val KEY_LAST_REFILL = "quiz_last_refill_timestamp"
        private const val KEY_IS_UNLIMITED = "quiz_is_unlimited"
        private const val KEY_INVITES = "quiz_invites_count"
        private const val KEY_REFERRAL_CODE = "quiz_referral_code"

        const val MAX_LIVES = 5
        const val REFILL_INTERVAL_MILLIS = 30 * 60 * 1000L // 30 minutes
    }
}
