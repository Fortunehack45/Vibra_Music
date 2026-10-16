package com.fortune.vibramusic.ui.quiz

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.quiz.QuizGameState
import com.fortune.vibramusic.data.quiz.QuizQuestion
import com.fortune.vibramusic.ui.components.ArtistAvatar
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource

@Composable
fun ActiveQuizScreen(
    viewModel: QuizViewModel,
    onAbandon: () -> Unit,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val gameState by viewModel.gameState.collectAsStateWithLifecycle()
    val countdownNumber by viewModel.countdownNumber.collectAsStateWithLifecycle()
    val currentQuestion by viewModel.currentQuestion.collectAsStateWithLifecycle()
    val questionIndex by viewModel.currentQuestionIndex.collectAsStateWithLifecycle()
    val totalQuestions by viewModel.totalQuestions.collectAsStateWithLifecycle()
    val elapsedMillis by viewModel.elapsedQuestionMillis.collectAsStateWithLifecycle()
    val totalTimerMillis by viewModel.totalTimerMillis.collectAsStateWithLifecycle()
    val selectedOptionIndex by viewModel.selectedOptionIndex.collectAsStateWithLifecycle()
    val currentArtist by viewModel.currentArtist.collectAsStateWithLifecycle()

    val formattedTotalTime = "%02d:%02d.%03d".format(
        totalTimerMillis / 60000,
        (totalTimerMillis % 60000) / 1000,
        totalTimerMillis % 1000,
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .hazeSource(hazeState)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        when (gameState) {
            QuizGameState.COUNTDOWN -> {
                // 3-2-1 Animated Countdown Overlay
                CountdownPhase(countdownNumber = countdownNumber)
            }

            QuizGameState.QUESTION_ACTIVE, QuizGameState.QUESTION_ANSWERED -> {
                // Active Quiz Question View
                currentQuestion?.let { question ->
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        // Top Navigation & Stats Bar
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconButton(onClick = onAbandon) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Abandon Quiz",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }

                            // Question Index Pill
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                                    .border(1.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(14.dp))
                                    .padding(horizontal = 14.dp, vertical = 6.dp),
                            ) {
                                Text(
                                    text = "Question ${questionIndex + 1} of $totalQuestions",
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                            }

                            // Live Millisecond Timer
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.15f))
                                    .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Timer,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = formattedTotalTime,
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.primary,
                                )
                            }
                        }

                        Spacer(Modifier.height(8.dp))

                        // Question Timer Progress Bar (15s countdown)
                        val progressFraction = (1f - (elapsedMillis.toFloat() / 15000f)).coerceIn(0f, 1f)
                        LinearProgressIndicator(
                            progress = { progressFraction },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(4.dp)
                                .clip(RoundedCornerShape(2.dp)),
                            color = if (progressFraction > 0.3f) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                            trackColor = MaterialTheme.colorScheme.surfaceVariant,
                            strokeCap = StrokeCap.Round,
                        )

                        Spacer(Modifier.height(20.dp))

                        // Artist Name Header
                        Text(
                            text = currentArtist?.name ?: "Artist Quiz",
                            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )

                        Text(
                            text = "Which song is playing?",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )

                        Spacer(Modifier.height(24.dp))

                        // Spinning Mystery Vinyl Disc with Sound Waves
                        MysteryVinylPlayer(
                            isPlaying = gameState == QuizGameState.QUESTION_ACTIVE,
                            artistName = currentArtist?.name ?: "Artist",
                            artistArtworkUrl = currentArtist?.artworkUrl,
                        )

                        Spacer(Modifier.height(32.dp))

                        // 4 Multiple Choice Song Options
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            question.options.forEachIndexed { index, optionTitle ->
                                val isSelected = selectedOptionIndex == index
                                val isCorrect = index == question.correctOptionIndex
                                val isAnswered = gameState == QuizGameState.QUESTION_ANSWERED

                                QuizOptionCard(
                                    title = optionTitle,
                                    index = index,
                                    isSelected = isSelected,
                                    isCorrect = isCorrect,
                                    isAnswered = isAnswered,
                                    onClick = {
                                        if (gameState == QuizGameState.QUESTION_ACTIVE) {
                                            viewModel.selectOption(index)
                                        }
                                    },
                                )
                            }
                        }
                    }
                }
            }

            else -> Unit
        }
    }
}

@Composable
private fun CountdownPhase(countdownNumber: Int) {
    val scale by animateFloatAsState(
        targetValue = 1.2f,
        animationSpec = tween(500, easing = FastOutSlowInEasing),
        label = "countdownScale",
    )

    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(160.dp)
                .scale(scale)
                .clip(CircleShape)
                .background(
                    Brush.sweepGradient(
                        listOf(
                            MaterialTheme.colorScheme.primary.copy(alpha = 0.4f),
                            MaterialTheme.colorScheme.secondary.copy(alpha = 0.6f),
                            MaterialTheme.colorScheme.primary.copy(alpha = 0.4f),
                        ),
                    ),
                )
                .border(2.dp, Color.White.copy(alpha = 0.2f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = if (countdownNumber > 0) countdownNumber.toString() else "GO!",
                style = MaterialTheme.typography.displayLarge.copy(
                    fontWeight = FontWeight.Black,
                    fontSize = if (countdownNumber > 0) 64.sp else 44.sp,
                ),
                color = MaterialTheme.colorScheme.onPrimary,
            )
        }
    }
}

@Composable
private fun MysteryVinylPlayer(
    isPlaying: Boolean,
    artistName: String,
    artistArtworkUrl: String?,
) {
    val infiniteTransition = rememberInfiniteTransition(label = "vinylSpin")
    val rotation by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(4000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "rotation",
    )

    Box(
        modifier = Modifier
            .size(170.dp)
            .clip(CircleShape)
            .background(Color(0xFF141416))
            .border(4.dp, Color.White.copy(alpha = 0.12f), CircleShape)
            .rotate(if (isPlaying) rotation else 0f),
        contentAlignment = Alignment.Center,
    ) {
        // Grooves
        Box(
            modifier = Modifier
                .size(130.dp)
                .clip(CircleShape)
                .border(1.dp, Color.White.copy(alpha = 0.08f), CircleShape),
        )

        // Center Album Art
        ArtistAvatar(
            artistName = artistName,
            artworkUrl = artistArtworkUrl,
            size = 76.dp,
            modifier = Modifier.border(2.dp, MaterialTheme.colorScheme.primary, CircleShape),
        )
    }
}

@Composable
private fun QuizOptionCard(
    title: String,
    index: Int,
    isSelected: Boolean,
    isCorrect: Boolean,
    isAnswered: Boolean,
    onClick: () -> Unit,
) {
    val optionLetters = listOf("A", "B", "C", "D")

    val backgroundColor by animateColorAsState(
        targetValue = when {
            isAnswered && isCorrect -> Color(0xFF10B981).copy(alpha = 0.25f) // Emerald green
            isAnswered && isSelected && !isCorrect -> Color(0xFFEF4444).copy(alpha = 0.25f) // Crimson red
            else -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        },
        label = "optionBg",
    )

    val borderColor by animateColorAsState(
        targetValue = when {
            isAnswered && isCorrect -> Color(0xFF10B981)
            isAnswered && isSelected && !isCorrect -> Color(0xFFEF4444)
            isSelected -> MaterialTheme.colorScheme.primary
            else -> Color.White.copy(alpha = 0.08f)
        },
        label = "optionBorder",
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(backgroundColor)
            .border(1.5.dp, borderColor, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            // Letter Indicator (A, B, C, D)
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            isAnswered && isCorrect -> Color(0xFF10B981)
                            isAnswered && isSelected && !isCorrect -> Color(0xFFEF4444)
                            else -> MaterialTheme.colorScheme.surface.copy(alpha = 0.8f)
                        },
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (isAnswered && isCorrect) {
                    Icon(
                        imageVector = Icons.Rounded.CheckCircle,
                        contentDescription = "Correct",
                        tint = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                } else if (isAnswered && isSelected && !isCorrect) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Incorrect",
                        tint = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                } else {
                    Text(
                        text = optionLetters.getOrElse(index) { "?" },
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }

            Spacer(Modifier.width(14.dp))

            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge.copy(
                    fontWeight = if (isSelected || (isAnswered && isCorrect)) FontWeight.Bold else FontWeight.Medium,
                ),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
    }
}
