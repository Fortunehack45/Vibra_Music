package com.fortune.vibramusic.ui.social

import android.content.Context
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

class VoiceRecorderManager(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.Main)
    private var mediaRecorder: MediaRecorder? = null
    private var currentRecordFile: File? = null
    private var timerJob: Job? = null

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _recordingDurationSeconds = MutableStateFlow(0)
    val recordingDurationSeconds: StateFlow<Int> = _recordingDurationSeconds.asStateFlow()

    // Playback
    private var mediaPlayer: MediaPlayer? = null
    private var playbackTickerJob: Job? = null
    private val _currentlyPlayingUrl = MutableStateFlow<String?>(null)
    val currentlyPlayingUrl: StateFlow<String?> = _currentlyPlayingUrl.asStateFlow()

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    private val _playbackProgress = MutableStateFlow(0f)
    val playbackProgress: StateFlow<Float> = _playbackProgress.asStateFlow()

    private val _playbackPositionMs = MutableStateFlow(0)
    val playbackPositionMs: StateFlow<Int> = _playbackPositionMs.asStateFlow()

    private val _playbackDurationMs = MutableStateFlow(0)
    val playbackDurationMs: StateFlow<Int> = _playbackDurationMs.asStateFlow()

    fun startRecording(): Boolean {
        return try {
            val audioDir = File(context.cacheDir, "voice_notes").apply { mkdirs() }
            val outputFile = File(audioDir, "vn_${UUID.randomUUID()}.m4a")
            currentRecordFile = outputFile

            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128000)
                setAudioSamplingRate(44100)
                setOutputFile(outputFile.absolutePath)
                prepare()
                start()
            }

            _isRecording.value = true
            _recordingDurationSeconds.value = 0

            timerJob?.cancel()
            timerJob = scope.launch {
                while (isActive && _isRecording.value) {
                    delay(1000)
                    _recordingDurationSeconds.value += 1
                }
            }
            true
        } catch (e: Exception) {
            Log.e("VoiceRecorder", "Failed to start recording", e)
            cancelRecording()
            false
        }
    }

    fun stopRecording(): File? {
        if (!_isRecording.value) return null
        return try {
            timerJob?.cancel()
            mediaRecorder?.apply {
                stop()
                release()
            }
            mediaRecorder = null
            _isRecording.value = false
            currentRecordFile
        } catch (e: Exception) {
            Log.e("VoiceRecorder", "Failed to stop recording", e)
            cancelRecording()
            null
        }
    }

    fun cancelRecording() {
        timerJob?.cancel()
        try {
            mediaRecorder?.apply {
                reset()
                release()
            }
        } catch (_: Exception) {}
        mediaRecorder = null
        currentRecordFile?.delete()
        currentRecordFile = null
        _isRecording.value = false
        _recordingDurationSeconds.value = 0
    }

    fun playAudio(urlOrPath: String) {
        if (_currentlyPlayingUrl.value == urlOrPath && _isPlaying.value) {
            pauseAudio()
            return
        }

        stopAudio()
        try {
            mediaPlayer = MediaPlayer().apply {
                setDataSource(urlOrPath)
                setOnPreparedListener {
                    start()
                    _isPlaying.value = true
                    _currentlyPlayingUrl.value = urlOrPath
                    val dur = duration
                    _playbackDurationMs.value = dur
                    startPlaybackTicker()
                }
                setOnCompletionListener {
                    _isPlaying.value = false
                    _currentlyPlayingUrl.value = null
                    _playbackProgress.value = 0f
                    _playbackPositionMs.value = 0
                    playbackTickerJob?.cancel()
                }
                prepareAsync()
            }
        } catch (e: Exception) {
            Log.e("VoiceRecorder", "Failed to play audio: $urlOrPath", e)
            _isPlaying.value = false
            _currentlyPlayingUrl.value = null
            _playbackProgress.value = 0f
            playbackTickerJob?.cancel()
        }
    }

    private fun startPlaybackTicker() {
        playbackTickerJob?.cancel()
        playbackTickerJob = scope.launch {
            while (isActive && _isPlaying.value) {
                val current = mediaPlayer?.currentPosition ?: 0
                val dur = mediaPlayer?.duration ?: 0
                _playbackPositionMs.value = current
                _playbackDurationMs.value = dur
                _playbackProgress.value = if (dur > 0) (current.toFloat() / dur.toFloat()).coerceIn(0f, 1f) else 0f
                delay(60)
            }
        }
    }

    fun pauseAudio() {
        mediaPlayer?.pause()
        _isPlaying.value = false
        playbackTickerJob?.cancel()
    }

    fun stopAudio() {
        playbackTickerJob?.cancel()
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
        _isPlaying.value = false
        _currentlyPlayingUrl.value = null
        _playbackProgress.value = 0f
        _playbackPositionMs.value = 0
    }

    fun stopPlayback() {
        stopAudio()
    }

    fun release() {
        cancelRecording()
        stopAudio()
    }
}
