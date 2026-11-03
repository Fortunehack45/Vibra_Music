package com.fortune.vibramusic.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.ScrollableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.CARD_ART_PX
import com.fortune.vibramusic.data.model.TopPick
import com.fortune.vibramusic.data.model.TopPickKind
import com.fortune.vibramusic.data.model.TopPickMood
import com.fortune.vibramusic.ui.components.PAGE_GUTTER
import com.fortune.vibramusic.ui.components.SHELF_CARD_WIDTH
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.sin

private const val TOP_PICK_RATIO = 0.75f
private const val TOP_PICK_FRACTION = 0.60f
private val TOP_PICK_MAX_WIDTH = 280.dp
private val TopPickShape = RoundedCornerShape(12.dp)
private const val MOTION_FRAME_GAP_MS = 16L
private val LIBRARY_GRID_SPACING = 16.dp
private const val HEADER_ART_PX = 800

private fun topPickWidth(available: Dp): Dp = minOf(available * TOP_PICK_FRACTION, TOP_PICK_MAX_WIDTH)

private fun Modifier.thumbnailBorder(shape: Shape = RoundedCornerShape(12.dp)): Modifier =
    this.border(1.dp, Color.White.copy(alpha = 0.08f), shape)

@Composable
internal fun TopPicksShelf(
    picks: List<TopPick>,
    listenerName: String?,
    onClick: (TopPick, String) -> Unit,
    onLongPress: ((TopPick) -> Unit)?,
) {
    if (picks.isEmpty()) return
    val rowState = rememberLazyListState()
    Column(Modifier.padding(bottom = 26.dp)) {
        SectionHeader(stringResource(R.string.top_picks_for_you))
        BoxWithConstraints {
            val cardWidth = topPickWidth(maxWidth)
            PausedWhileScrolling(rowState) {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    state = rowState,
                ) {
                    itemsIndexed(picks, key = { index, pick -> "$index:${pick.kind}:${pick.title}" }) { _, pick ->
                        TopPickCard(
                            pick = pick,
                            listenerName = listenerName,
                            onClick = onClick,
                            onLongPress = onLongPress?.takeIf { pick.kind == TopPickKind.LATEST_RELEASE },
                            modifier = Modifier.width(cardWidth),
                        )
                    }
                }
            }
        }
    }
}

fun LazyListScope.topPicksSkeleton() {
    item(key = "skeleton:top-picks") {
        Column(Modifier.padding(bottom = 26.dp)) {
            SectionHeader(stringResource(R.string.top_picks_for_you))
            BoxWithConstraints {
                val cardWidth = topPickWidth(maxWidth)
                LazyRow(
                    contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    userScrollEnabled = false,
                ) {
                    items(2) {
                        Box(
                            modifier = Modifier
                                .width(cardWidth)
                                .aspectRatio(TOP_PICK_RATIO)
                                .clip(TopPickShape)
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
                        )
                    }
                }
            }
        }
    }
}

private class CardText(val eyebrow: String, val title: String, val subtitle: String)

@Composable
private fun cardText(pick: TopPick, listenerName: String?): CardText {
    val artist = pick.artistName.orEmpty()
    return when (pick.kind) {
        TopPickKind.LATEST_RELEASE -> CardText(
            eyebrow = stringResource(R.string.top_pick_new_from, artist),
            title = pick.title,
            subtitle = pick.subtitle,
        )
        TopPickKind.PERSONAL_STATION -> CardText(
            eyebrow = stringResource(R.string.top_pick_made_for_you),
            title = listenerName?.substringBefore(' ')?.takeIf { it.isNotBlank() }
                ?.let { stringResource(R.string.top_pick_named_station, it) }
                ?: stringResource(R.string.top_pick_your_station),
            subtitle = "",
        )
        TopPickKind.MOOD -> {
            val mood = pick.mood ?: TopPickMood.FEEL_GOOD
            CardText(
                eyebrow = stringResource(R.string.top_pick_mood_for_you),
                title = stringResource(mood.titleRes()),
                subtitle = stringResource(mood.lineRes()),
            )
        }
        TopPickKind.ARTIST_AND_SIMILAR -> CardText(
            eyebrow = stringResource(R.string.top_pick_featuring, artist),
            title = stringResource(R.string.top_pick_and_similar, artist),
            subtitle = "",
        )
        TopPickKind.FEATURED_ARTIST -> CardText(
            eyebrow = stringResource(R.string.top_pick_featuring, artist),
            title = pick.title,
            subtitle = pick.subtitle,
        )
        TopPickKind.NEW_RELEASE_MIX -> CardText(
            eyebrow = stringResource(R.string.top_pick_made_for_you),
            title = pick.title,
            subtitle = pick.subtitle,
        )
        TopPickKind.DISCOVERY_STATION -> CardText(
            eyebrow = stringResource(R.string.top_pick_made_for_you),
            title = stringResource(R.string.top_pick_discovery_station),
            subtitle = "",
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TopPickCard(
    pick: TopPick,
    listenerName: String?,
    onClick: (TopPick, String) -> Unit,
    onLongPress: ((TopPick) -> Unit)?,
    modifier: Modifier,
) {
    val text = cardText(pick, listenerName)
    val longPress = onLongPress?.let { { it(pick) } }
    Box(
        modifier = modifier
            .aspectRatio(TOP_PICK_RATIO)
            .clip(TopPickShape)
            .thumbnailBorder(TopPickShape)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .combinedClickable(
                onClick = { onClick(pick, text.title) },
                onLongClick = longPress,
            ),
    ) {
        val eyebrowColor: Color
        val branded: Boolean
        when (pick.kind) {
            TopPickKind.PERSONAL_STATION -> {
                PersonalStationArt(Modifier.fillMaxSize())
                eyebrowColor = Color(0xFFFFD2DA)
                branded = true
            }
            TopPickKind.DISCOVERY_STATION -> {
                DiscoveryStationArt(Modifier.fillMaxSize())
                eyebrowColor = Color(0xFFCDBDFF)
                branded = true
            }
            TopPickKind.MOOD -> {
                val style = (pick.mood ?: TopPickMood.FEEL_GOOD).style()
                MoodArt(pick.mood ?: TopPickMood.FEEL_GOOD, style, Modifier.fillMaxSize())
                eyebrowColor = style.eyebrow
                branded = true
            }
            TopPickKind.ARTIST_AND_SIMILAR -> {
                val palette = collagePalette(pick.artistName.orEmpty())
                ArtistCollageArt(pick.images, palette, Modifier.fillMaxSize())
                eyebrowColor = palette.eyebrow
                branded = true
            }
            TopPickKind.LATEST_RELEASE, TopPickKind.NEW_RELEASE_MIX -> {
                ReleaseArt(pick.images.firstOrNull(), Modifier.fillMaxSize())
                eyebrowColor = PhotoEyebrow
                branded = false
            }
            TopPickKind.FEATURED_ARTIST -> {
                AsyncImage(
                    model = pick.images.firstOrNull().croppedAt(HEADER_ART_PX * 3 / 4, HEADER_ART_PX),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                0.45f to Color.Transparent,
                                0.72f to Color.Black.copy(alpha = 0.45f),
                                1f to Color.Black.copy(alpha = 0.82f),
                            ),
                        ),
                )
                eyebrowColor = PhotoEyebrow
                branded = false
            }
        }
        if (branded) {
            Icon(
                painter = painterResource(R.drawable.ic_logo),
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 12.dp, end = 12.dp)
                    .height(15.dp)
                    .aspectRatio(730f / 484f),
            )
        }
        CardCaption(text, eyebrowColor, Modifier.align(Alignment.BottomStart).padding(16.dp))
    }
}

@Composable
private fun CardCaption(text: CardText, eyebrowColor: Color, modifier: Modifier) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = text.eyebrow.uppercase(),
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold, fontSize = 11.sp, lineHeight = 16.sp),
            color = eyebrowColor,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = text.title,
            style = MaterialTheme.typography.titleMedium.copy(
                fontSize = 17.sp,
                lineHeight = 21.sp,
                fontWeight = FontWeight.SemiBold,
            ),
            color = Color.White,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (text.subtitle.isNotBlank()) {
            Text(
                text = text.subtitle,
                style = MaterialTheme.typography.bodyMedium.copy(fontSize = 13.sp, lineHeight = 16.sp),
                color = Color.White.copy(alpha = 0.86f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private val PhotoEyebrow = Color.White.copy(alpha = 0.62f)

@Composable
private fun ReleaseArt(url: String?, modifier: Modifier) {
    Box(modifier.background(Color.Black)) {
        AsyncImage(
            model = url.croppedAt(HEADER_ART_PX),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f),
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.5f to Color.Transparent,
                        0.75f to Color.Black.copy(alpha = 0.5f),
                        1f to Color.Black.copy(alpha = 0.85f),
                    ),
                ),
        )
    }
}

val LocalArtworkMotion = compositionLocalOf { true }
val LocalArtworkScrolling = staticCompositionLocalOf<() -> Boolean> { { false } }

@Composable
internal fun PausedWhileScrolling(state: ScrollableState, content: @Composable () -> Unit) {
    val outer = LocalArtworkScrolling.current
    val scrolling = remember(outer, state) { { outer() || state.isScrollInProgress } }
    CompositionLocalProvider(LocalArtworkScrolling provides scrolling, content = content)
}

private const val STATION_PERIOD_MS = 9_000

@Composable
private fun loopPhase(periodMs: Int): State<Float> {
    val phase = remember { mutableFloatStateOf(0f) }
    val running = LocalArtworkMotion.current
    val scrolling = LocalArtworkScrolling.current
    LaunchedEffect(running, periodMs, scrolling) {
        if (!running) return@LaunchedEffect
        var last = Long.MIN_VALUE
        while (true) {
            if (scrolling()) {
                snapshotFlow { scrolling() }.first { !it }
                last = Long.MIN_VALUE
            }
            withFrameNanos { now ->
                if (last != Long.MIN_VALUE) {
                    phase.floatValue = (phase.floatValue + (now - last) / (periodMs * 1_000_000f)) % 1f
                }
                last = now
            }
            delay(MOTION_FRAME_GAP_MS)
        }
    }
    return phase
}

private val RetainedArt = Modifier.graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }

private fun wave(phase: Float, offset: Float): Float = sin(2f * PI.toFloat() * (phase + offset))

private class SizeCache<T : Any>(private val build: (Size) -> T) {
    private var size = Size.Unspecified
    private var value: T? = null

    fun get(current: Size): T {
        val cached = value
        if (cached != null && current == size) return cached
        size = current
        return build(current).also { value = it }
    }
}

private val PersonalLayers = listOf(
    Triple(1.00f, Color(0xFFFE5E83), Color(0xFFFA6196)),
    Triple(0.66f, Color(0xFFFE5065), Color(0xFFFC657C)),
    Triple(0.43f, Color(0xFFFB594C), Color(0xFFFC776D)),
    Triple(0.21f, Color(0xFFFB6729), Color(0xFFF98A48)),
)

private class PersonalBrushes(val background: Brush, val layers: List<Brush>)

@Composable
private fun PersonalStationArt(modifier: Modifier) {
    val phase by loopPhase(STATION_PERIOD_MS)
    val path = remember { Path() }
    val brushes = remember {
        SizeCache { size ->
            PersonalBrushes(
                background = Brush.horizontalGradient(
                    0f to Color(0xFFF7334F),
                    0.38f to Color(0xFFFA6094),
                    0.75f to Color(0xFFF02A4A),
                    1f to Color(0xFFEE213D),
                ),
                layers = PersonalLayers.map { (rest, deep, light) ->
                    Brush.horizontalGradient(listOf(deep, light), startX = 0f, endX = size.width * rest)
                },
            )
        }
    }
    Canvas(modifier.then(RetainedArt)) {
        val w = size.width
        val h = size.height
        val cached = brushes.get(size)
        drawRect(cached.background)
        PersonalLayers.forEachIndexed { index, (rest, _, _) ->
            val tip = if (index == 0) rest else rest + 0.07f * wave(phase, index * 0.19f)
            path.reset()
            path.moveTo(0f, 0f)
            path.lineTo(w * tip, h / 2f)
            path.lineTo(0f, h)
            path.close()
            drawPath(path, cached.layers[index])
        }
    }
}

private val DiscoveryTopColors = listOf(
    Color(0xFF3A2496), Color(0xFF2F4FB0), Color(0xFF3B30A0),
    Color(0xFF2E7FB8), Color(0xFF27988A), Color(0xFF3C8DA8),
)
private val DiscoveryBottomColors = listOf(
    Color(0xFF3A2496), Color(0xFF333EA4), Color(0xFF2F62B6),
    Color(0xFF288B99), Color(0xFF3477BA), Color(0xFF42A296),
)

private val DiscoveryEdges = listOf(0f, 0.24f, 0.44f, 0.62f, 0.78f, 0.91f, 1.02f)

private class DiscoveryBrushes(val background: Brush, val top: List<Brush>, val bottom: List<Brush>, val arrow: Brush)

@Composable
private fun DiscoveryStationArt(modifier: Modifier) {
    val phase by loopPhase(STATION_PERIOD_MS)
    val path = remember { Path() }
    val brushes = remember {
        SizeCache { size ->
            val apex = Offset(size.width, size.height / 2f)
            fun shards(edgeY: Float, colors: List<Color>) = (0 until DiscoveryEdges.lastIndex).map { i ->
                val mid = size.width * (DiscoveryEdges[i] + DiscoveryEdges[i + 1]) / 2f
                val base = colors[i % colors.size]
                Brush.linearGradient(listOf(lerp(base, Color.White, 0.10f), base), start = apex, end = Offset(mid, edgeY))
            }
            DiscoveryBrushes(
                background = Brush.linearGradient(
                    listOf(Color(0xFF2A869F), Color(0xFF3477BA)),
                    Offset.Zero,
                    Offset(size.width, size.height),
                ),
                top = shards(0f, DiscoveryTopColors),
                bottom = shards(size.height, DiscoveryBottomColors),
                arrow = Brush.horizontalGradient(
                    0f to Color(0xFF502798),
                    0.55f to Color(0xFF421C88),
                    1f to Color(0xFF4A2292),
                ),
            )
        }
    }
    Canvas(modifier.then(RetainedArt)) {
        val w = size.width
        val h = size.height
        val cached = brushes.get(size)
        drawRect(cached.background)
        fun fan(edgeY: Float, shards: List<Brush>, offset: Float) {
            var previous = DiscoveryEdges[0]
            for (i in 1..DiscoveryEdges.lastIndex) {
                val rest = DiscoveryEdges[i]
                val edge = if (i == DiscoveryEdges.lastIndex) rest else rest + 0.06f * wave(phase, offset + i * 0.11f)
                path.reset()
                path.moveTo(w, h / 2f)
                path.lineTo(w * previous, edgeY)
                path.lineTo(w * edge, edgeY)
                path.close()
                drawPath(path, shards[i - 1])
                previous = edge
            }
        }
        fan(0f, cached.top, 0f)
        fan(h, cached.bottom, 0.5f)

        path.reset()
        path.moveTo(0f, 0f)
        path.lineTo(w, h / 2f)
        path.lineTo(0f, h)
        path.close()
        drawPath(path, cached.arrow)
        val inner = 0.08f + 0.04f * wave(phase, 0.25f)
        path.reset()
        path.moveTo(0f, h * inner)
        path.lineTo(w * (0.9f - inner), h / 2f)
        path.lineTo(0f, h * (1f - inner))
        path.close()
        drawPath(path, DiscoveryInnerArrow)
    }
}

private val DiscoveryInnerArrow = Color(0xFF3C1981).copy(alpha = 0.35f)

private class MoodStyle(
    val background: Color,
    val stroke: Color,
    val periodMs: Int,
    val eyebrow: Color = stroke,
)

private fun TopPickMood.style(): MoodStyle = when (this) {
    TopPickMood.ENERGY -> MoodStyle(Color(0xFF1EBD38), Color(0xFFE2F6A2), 3_000, Color(0xFFE8FF9C))
    TopPickMood.RELAX -> MoodStyle(Color(0xFF31AFF3), Color(0xFFB4E9FF), 5_600, Color(0xFFD6F3FF))
    TopPickMood.FEELING_BLUE -> MoodStyle(Color(0xFF1E6CFF), Color(0xFFB5D4FF), 5_000, Color(0xFFD0E3FF))
    TopPickMood.FEEL_GOOD -> MoodStyle(Color(0xFFFF9500), Color(0xFFFFE1B0), 4_000, Color(0xFFFFF0D0))
    TopPickMood.FOCUS -> MoodStyle(Color(0xFF4C873D), Color(0xFFCFEAC5), 6_000, Color(0xFFE2F4DB))
    TopPickMood.HEARTBREAK -> MoodStyle(Color(0xFFFF2D55), Color(0xFFFFB5C4), 4_800, Color(0xFFFFD4DE))
    TopPickMood.LOVE -> MoodStyle(Color(0xFFFF3358), Color(0xFFFFC0CE), 2_600, Color(0xFFFFDEE6))
    TopPickMood.AFTER_HOURS -> MoodStyle(Color(0xFF4A1E99), Color(0xFFDCC8FF), 4_000)
    TopPickMood.ALONE_TIME -> MoodStyle(Color(0xFF5A7280), Color(0xFFDDE7EE), 4_000)
    TopPickMood.CHILL -> MoodStyle(Color(0xFF2C8C99), Color(0xFFC2F1F8), 6_000)
    TopPickMood.COMMUTING -> MoodStyle(Color(0xFF705244), Color(0xFFE7DDD8), 2_000)
    TopPickMood.EATING_COOKING -> MoodStyle(Color(0xFFB85D19), Color(0xFFFFDAC0), 3_600)
    TopPickMood.EVENING -> MoodStyle(Color(0xFF8A3B64), Color(0xFFFFCEE3), 4_500)
    TopPickMood.FITNESS -> MoodStyle(Color(0xFFD92B2B), Color(0xFFFFC6C6), 2_200)
    TopPickMood.GAMING -> MoodStyle(Color(0xFF6B35B8), Color(0xFFE2CCFF), 4_000)
    TopPickMood.HOME -> MoodStyle(Color(0xFF8A6B3D), Color(0xFFF3E5D0), 4_000)
    TopPickMood.MORNING -> MoodStyle(Color(0xFFD4820A), Color(0xFFFFE8C2), 5_000)
    TopPickMood.MOTIVATION -> MoodStyle(Color(0xFFC73E1D), Color(0xFFFFCFBE), 2_500)
    TopPickMood.OUTDOORS -> MoodStyle(Color(0xFF387A4A), Color(0xFFC6ECCF), 6_000)
    TopPickMood.PARTY -> MoodStyle(Color(0xFFA82482), Color(0xFFFFCBEF), 2_400)
    TopPickMood.SLEEP -> MoodStyle(Color(0xFF2A3E66), Color(0xFFC8D7F5), 6_000)
    TopPickMood.SOCIAL -> MoodStyle(Color(0xFFBF3958), Color(0xFFFFC8D5), 2_800)
    TopPickMood.SPORTS -> MoodStyle(Color(0xFF1C6CD0), Color(0xFFB8D8FF), 3_000)
    TopPickMood.SUMMERTIME -> MoodStyle(Color(0xFFFF8C00), Color(0xFFFFE6A8), 8_000)
    TopPickMood.HOLIDAY -> MoodStyle(Color(0xFFC62828), Color(0xFFFFC8C8), 8_000)
    TopPickMood.WEEKEND -> MoodStyle(Color(0xFF7A3CC2), Color(0xFFE2CCFF), 2_400)
    TopPickMood.WELLBEING -> MoodStyle(Color(0xFF36A98A), Color(0xFFC6F7E6), 5_000)
    TopPickMood.WORK -> MoodStyle(Color(0xFF3E63C9), Color(0xFFC4D2FF), 2_000)
}

fun TopPickMood.titleRes(): Int = when (this) {
    TopPickMood.ENERGY -> R.string.mood_energy
    TopPickMood.RELAX -> R.string.mood_relax
    TopPickMood.FEELING_BLUE -> R.string.mood_feeling_blue
    TopPickMood.FEEL_GOOD -> R.string.mood_feel_good
    TopPickMood.FOCUS -> R.string.mood_focus
    TopPickMood.HEARTBREAK -> R.string.mood_heartbreak
    TopPickMood.LOVE -> R.string.mood_love
    TopPickMood.AFTER_HOURS -> R.string.mood_after_hours
    TopPickMood.ALONE_TIME -> R.string.mood_alone_time
    TopPickMood.CHILL -> R.string.mood_chill
    TopPickMood.COMMUTING -> R.string.mood_commuting
    TopPickMood.EATING_COOKING -> R.string.mood_eating_cooking
    TopPickMood.EVENING -> R.string.mood_evening
    TopPickMood.FITNESS -> R.string.mood_fitness
    TopPickMood.GAMING -> R.string.mood_gaming
    TopPickMood.HOME -> R.string.mood_home
    TopPickMood.MORNING -> R.string.mood_morning
    TopPickMood.MOTIVATION -> R.string.mood_motivation
    TopPickMood.OUTDOORS -> R.string.mood_outdoors
    TopPickMood.PARTY -> R.string.mood_party
    TopPickMood.SLEEP -> R.string.mood_sleep
    TopPickMood.SOCIAL -> R.string.mood_social
    TopPickMood.SPORTS -> R.string.mood_sports
    TopPickMood.SUMMERTIME -> R.string.mood_summertime
    TopPickMood.HOLIDAY -> R.string.mood_holiday
    TopPickMood.WEEKEND -> R.string.mood_weekend
    TopPickMood.WELLBEING -> R.string.mood_wellbeing
    TopPickMood.WORK -> R.string.mood_work
}

fun TopPickMood.lineRes(): Int = when (this) {
    TopPickMood.ENERGY -> R.string.mood_energy_line
    TopPickMood.RELAX -> R.string.mood_relax_line
    TopPickMood.FEELING_BLUE -> R.string.mood_feeling_blue_line
    TopPickMood.FEEL_GOOD -> R.string.mood_feel_good_line
    TopPickMood.FOCUS -> R.string.mood_focus_line
    TopPickMood.HEARTBREAK -> R.string.mood_heartbreak_line
    TopPickMood.LOVE -> R.string.mood_love_line
    TopPickMood.AFTER_HOURS -> R.string.mood_after_hours_line
    TopPickMood.ALONE_TIME -> R.string.mood_alone_time_line
    TopPickMood.CHILL -> R.string.mood_chill_line
    TopPickMood.COMMUTING -> R.string.mood_commuting_line
    TopPickMood.EATING_COOKING -> R.string.mood_eating_cooking_line
    TopPickMood.EVENING -> R.string.mood_evening_line
    TopPickMood.FITNESS -> R.string.mood_fitness_line
    TopPickMood.GAMING -> R.string.mood_gaming_line
    TopPickMood.HOME -> R.string.mood_home_line
    TopPickMood.MORNING -> R.string.mood_morning_line
    TopPickMood.MOTIVATION -> R.string.mood_motivation_line
    TopPickMood.OUTDOORS -> R.string.mood_outdoors_line
    TopPickMood.PARTY -> R.string.mood_party_line
    TopPickMood.SLEEP -> R.string.mood_sleep_line
    TopPickMood.SOCIAL -> R.string.mood_social_line
    TopPickMood.SPORTS -> R.string.mood_sports_line
    TopPickMood.SUMMERTIME -> R.string.mood_summertime_line
    TopPickMood.HOLIDAY -> R.string.mood_holiday_line
    TopPickMood.WEEKEND -> R.string.mood_weekend_line
    TopPickMood.WELLBEING -> R.string.mood_wellbeing_line
    TopPickMood.WORK -> R.string.mood_work_line
}

private class Frame(val left: Float, val top: Float, val side: Float) {
    fun x(f: Float) = left + side * f
    fun y(f: Float) = top + side * f
    fun at(x: Float, y: Float) = Offset(x(x), y(y))
    val center get() = Offset(x(0.5f), y(0.5f))
}

@Composable
private fun MoodArt(
    mood: TopPickMood,
    style: MoodStyle,
    modifier: Modifier,
    square: Boolean = false,
    still: Boolean = false,
) {
    val loop = if (still) null else loopPhase(style.periodMs)
    val cache = remember(mood) { EmblemCache() }
    Canvas(if (still) modifier else modifier.then(RetainedArt)) {
        drawRect(style.background)
        val w = size.width
        val h = size.height
        val f = if (square) {
            val side = w * 0.70f
            Frame(left = (w - side) / 2f, top = (h - side) / 2f, side = side)
        } else {
            val side = minOf(w * 0.84f, h * 0.62f)
            Frame(left = (w - side) / 2f, top = h * 0.37f - side / 2f, side = side)
        }
        val stroke = cache.stroke((if (square) 2.dp else 2.5.dp).toPx())
        drawEmblem(mood, f, loop?.value ?: mood.stillPhase(), style.stroke, stroke, cache)
    }
}

private fun TopPickMood.stillPhase(): Float = when (this) {
    TopPickMood.FITNESS -> 0.55f
    TopPickMood.WORK -> 0.6f
    else -> 0f
}

private val TAU = 2f * PI.toFloat()

private class EmblemCache {
    private var builtFor = Size.Unspecified
    private val outline = Path()
    val scratch = Path()
    val segment = Path()
    val measure = PathMeasure()
    var length = 0f
        private set
    private var strokeWidth = -1f
    private var strokeStyle = Stroke()

    fun outline(size: Size, measured: Boolean = false, build: (Path) -> Unit): Path {
        if (size != builtFor) {
            outline.reset()
            build(outline)
            if (measured) {
                measure.setPath(outline, false)
                length = measure.length
            }
            builtFor = size
        }
        return outline
    }

    fun stroke(width: Float): Stroke {
        if (width != strokeWidth) {
            strokeWidth = width
            strokeStyle = Stroke(width = width, cap = StrokeCap.Round, join = StrokeJoin.Round)
        }
        return strokeStyle
    }
}

private fun DrawScope.drawEmblem(
    mood: TopPickMood,
    f: Frame,
    phase: Float,
    color: Color,
    stroke: Stroke,
    cache: EmblemCache,
) {
    val side = f.side
    val path = cache.scratch
    val segment = cache.segment
    when (mood) {
        TopPickMood.ENERGY -> {
            val p = cache.outline(size) { bolt(it, f) }
            val t = (phase - 0.28f) / 0.26f
            val flash = if (t in 0f..1f) sin(PI.toFloat() * t) else 0f
            if (flash > 0f) {
                translate(left = side * 0.07f * flash) { drawPath(p, color.copy(alpha = 0.55f * flash), style = stroke) }
                translate(left = -side * 0.05f * flash) { drawPath(p, color.copy(alpha = 0.35f * flash), style = stroke) }
            }
            drawPath(p, color, style = stroke)
        }
        TopPickMood.RELAX -> {
            val stones = listOf(
                Triple(0.17f, 0.44f, 0.18f),
                Triple(0.38f, 0.68f, 0.28f),
                Triple(0.66f, 0.84f, 0.36f),
            )
            stones.forEachIndexed { index, (cy, width, height) ->
                val sway = wave(phase, index * 0.22f)
                val center = Offset(f.x(0.5f + 0.015f * sway), f.y(cy))
                rotate(degrees = 4f * sway, pivot = center) {
                    drawOval(
                        color = color,
                        topLeft = Offset(center.x - side * width / 2f, center.y - side * height / 2f),
                        size = Size(side * width, side * height),
                        style = stroke,
                    )
                }
            }
        }
        TopPickMood.FEELING_BLUE -> {
            cache.outline(size, measured = true) { spiral(it, f) }
            val length = cache.length
            val from: Float
            val to: Float
            when {
                phase < 0.35f -> { from = 0f; to = length }
                phase < 0.8f -> { from = length * easeInOut((phase - 0.35f) / 0.45f); to = length }
                else -> { from = 0f; to = length * easeInOut((phase - 0.8f) / 0.2f) }
            }
            segment.reset()
            cache.measure.getSegment(from, to, segment, true)
            drawPath(segment, color, style = stroke)
        }
        TopPickMood.FEEL_GOOD -> {
            val p = cache.outline(size) { star(it, f) }
            val turn = 8f * sin(TAU * phase)
            val twist = 0.85f + 0.15f * (0.5f + 0.5f * cos(TAU * phase))
            withTransform({
                rotate(turn, f.center)
                scale(twist, 1f / twist, f.center)
            }) { drawPath(p, color, style = stroke) }
        }
        TopPickMood.FOCUS -> {
            for (i in 0 until 4) {
                val r = (i + phase) / 4
                val radius = side * 0.45f * (1f - r)
                drawCircle(color.copy(alpha = edgeFade(r)), radius = radius, center = f.center, style = stroke)
            }
        }
        TopPickMood.HEARTBREAK -> {
            val p = cache.outline(size, measured = true) { heart(it, f) }
            val length = cache.length
            val dash = length * 0.045f
            val space = length * 0.035f
            val shift = phase * (dash + space)
            drawPath(
                p,
                color,
                style = Stroke(
                    width = stroke.width,
                    pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(dash, space), shift),
                ),
            )
        }
        TopPickMood.LOVE -> {
            val p = cache.outline(size) { heart(it, f) }
            fun bump(at: Float): Float {
                val d = (phase - at) / 0.06f
                return exp(-d * d)
            }
            val beat = 1f + 0.07f * (bump(0.15f) + 0.7f * bump(0.38f))
            scale(beat, beat, f.center) { drawPath(p, color, style = stroke) }
        }
        TopPickMood.AFTER_HOURS -> {
            drawPath(cache.outline(size) { crescent(it, f, 0.42f, 0.52f, 0.34f) }, color, style = stroke)
            listOf(Triple(0.80f, 0.22f, 0.07f), Triple(0.86f, 0.58f, 0.05f), Triple(0.68f, 0.82f, 0.04f))
                .forEachIndexed { index, (x, y, r) ->
                    val twinkle = 0.25f + 0.75f * (0.5f + 0.5f * wave(phase, index / 3f))
                    sparkle(path, f.at(x, y), side * r)
                    drawPath(path, color.copy(alpha = twinkle), style = stroke)
                }
        }
        TopPickMood.ALONE_TIME -> {
            val center = f.at(0.5f, 0.55f)
            for (i in 0 until 4) {
                val share = (i + phase) / 4
                val rx = side * 0.5f * share
                drawOval(
                    color.copy(alpha = edgeFade(share)),
                    topLeft = Offset(center.x - rx, center.y - rx * 0.42f),
                    size = Size(rx * 2f, rx * 0.84f),
                    style = stroke,
                )
            }
        }
        TopPickMood.CHILL -> {
            clipRect(f.left, f.top, f.x(1f), f.y(1f)) {
                listOf(0.32f, 0.5f, 0.68f).forEachIndexed { row, y ->
                    path.reset()
                    for (k in 0..80) {
                        val u = k / 80f
                        val py = y + 0.05f * sin(TAU * (u / 0.33f - phase - row * 0.15f))
                        if (k == 0) path.moveTo(f.x(u), f.y(py)) else path.lineTo(f.x(u), f.y(py))
                    }
                    drawPath(path, color, style = stroke)
                }
            }
        }
        TopPickMood.COMMUTING -> {
            drawLine(color, f.at(0.06f, 0.95f), f.at(0.44f, 0.14f), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.94f, 0.95f), f.at(0.56f, 0.14f), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.15f, 0.14f), f.at(0.85f, 0.14f), stroke.width, StrokeCap.Round)
            for (k in 0 until 5) {
                val u = (k / 5f + phase) % 1f
                val y0 = 0.18f + 0.77f * u * u
                val y1 = (y0 + 0.02f + 0.08f * u).coerceAtMost(0.95f)
                drawLine(color.copy(alpha = edgeFade(u)), f.at(0.5f, y0), f.at(0.5f, y1), stroke.width, StrokeCap.Round)
            }
        }
        TopPickMood.EATING_COOKING -> {
            path.reset()
            path.arcTo(Rect(f.x(0.12f), f.y(0.25f), f.x(0.88f), f.y(0.95f)), 0f, 180f, true)
            drawPath(path, color, style = stroke)
            drawLine(color, f.at(0.05f, 0.6f), f.at(0.95f, 0.6f), stroke.width, StrokeCap.Round)
            listOf(0.36f, 0.5f, 0.64f).forEachIndexed { index, x ->
                val rise = (phase + index / 3f) % 1f
                path.reset()
                for (k in 0..30) {
                    val u = k / 30f
                    val px = x + 0.035f * sin(TAU * (u * 1.2f + rise))
                    val py = 0.5f - 0.3f * u - 0.1f * rise
                    if (k == 0) path.moveTo(f.x(px), f.y(py)) else path.lineTo(f.x(px), f.y(py))
                }
                drawPath(path, color.copy(alpha = sin(PI.toFloat() * rise)), style = stroke)
            }
        }
        TopPickMood.EVENING -> {
            val horizon = 0.62f
            val sink = 0.1f * (0.5f - 0.5f * cos(TAU * phase))
            clipRect(f.left - side, f.top - side, f.x(2f), f.y(horizon)) {
                drawCircle(color, radius = side * 0.26f, center = f.at(0.5f, horizon - 0.02f + sink), style = stroke)
            }
            drawLine(color, f.at(0.04f, horizon), f.at(0.96f, horizon), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.2f, horizon + 0.11f), f.at(0.8f, horizon + 0.11f), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.36f, horizon + 0.22f), f.at(0.64f, horizon + 0.22f), stroke.width, StrokeCap.Round)
        }
        TopPickMood.FITNESS -> {
            val trace = cache.outline(size, measured = true) { out ->
                listOf(0f to 0.55f, 0.28f to 0.55f, 0.36f to 0.42f, 0.44f to 0.76f, 0.52f to 0.18f, 0.6f to 0.84f, 0.67f to 0.55f, 1f to 0.55f)
                    .forEachIndexed { index, (x, y) -> if (index == 0) out.moveTo(f.x(x), f.y(y)) else out.lineTo(f.x(x), f.y(y)) }
            }
            drawPath(trace, color.copy(alpha = 0.3f), style = stroke)
            val length = cache.length
            val head = phase * 1.4f * length
            segment.reset()
            cache.measure.getSegment((head - 0.45f * length).coerceAtLeast(0f), head.coerceAtMost(length), segment, true)
            drawPath(segment, color, style = stroke)
        }
        TopPickMood.GAMING -> {
            listOf(0.9f, 0.62f, 0.34f).forEachIndexed { index, sz ->
                val turn = (if (index % 2 == 0) 1f else -1f) * phase * 90f
                rotate(turn, f.center) {
                    drawRect(
                        color,
                        topLeft = f.at(0.5f - sz / 2f, 0.5f - sz / 2f),
                        size = Size(side * sz, side * sz),
                        style = stroke,
                    )
                }
            }
        }
        TopPickMood.HOME -> {
            val house = cache.outline(size) { out ->
                listOf(0.5f to 0.1f, 0.94f to 0.5f, 0.82f to 0.5f, 0.82f to 0.92f, 0.18f to 0.92f, 0.18f to 0.5f, 0.06f to 0.5f)
                    .forEachIndexed { index, (x, y) -> if (index == 0) out.moveTo(f.x(x), f.y(y)) else out.lineTo(f.x(x), f.y(y)) }
                out.close()
            }
            drawPath(house, color, style = stroke)
            drawRect(color, topLeft = f.at(0.41f, 0.66f), size = Size(side * 0.18f, side * 0.26f), style = stroke)
            val glow = 0.5f + 0.5f * wave(phase, 0f)
            drawRect(color.copy(alpha = 0.15f + 0.45f * glow), topLeft = f.at(0.27f, 0.56f), size = Size(side * 0.1f, side * 0.1f))
            drawRect(color, topLeft = f.at(0.27f, 0.56f), size = Size(side * 0.1f, side * 0.1f), style = stroke)
        }
        TopPickMood.MORNING -> {
            val horizon = 0.72f
            val sun = f.at(0.5f, horizon - 0.03f - 0.05f * (0.5f + 0.5f * wave(phase, 0f)))
            clipRect(f.left - side, f.top - side, f.x(2f), f.y(horizon)) {
                drawCircle(color, radius = side * 0.2f, center = sun, style = stroke)
                for (k in 0 until 9) {
                    val angle = PI.toFloat() + (k + 0.5f) * PI.toFloat() / 9f + phase * 0.35f
                    val a = Offset(sun.x + side * 0.28f * cos(angle), sun.y + side * 0.28f * sin(angle))
                    val b = Offset(sun.x + side * 0.38f * cos(angle), sun.y + side * 0.38f * sin(angle))
                    drawLine(color, a, b, stroke.width, StrokeCap.Round)
                }
            }
            drawLine(color, f.at(0.04f, horizon), f.at(0.96f, horizon), stroke.width, StrokeCap.Round)
        }
        TopPickMood.MOTIVATION -> {
            for (k in 0 until 3) {
                val u = (k / 3f + phase) % 1f
                val y = 0.82f - 0.66f * u
                path.reset()
                path.moveTo(f.x(0.22f), f.y(y + 0.17f))
                path.lineTo(f.x(0.5f), f.y(y))
                path.lineTo(f.x(0.78f), f.y(y + 0.17f))
                drawPath(path, color.copy(alpha = sin(PI.toFloat() * u)), style = stroke)
            }
        }
        TopPickMood.OUTDOORS -> {
            val ridge = cache.outline(size) { out ->
                listOf(0.02f to 0.86f, 0.36f to 0.36f, 0.55f to 0.62f, 0.7f to 0.44f, 0.98f to 0.86f)
                    .forEachIndexed { index, (x, y) -> if (index == 0) out.moveTo(f.x(x), f.y(y)) else out.lineTo(f.x(x), f.y(y)) }
            }
            drawPath(ridge, color, style = stroke)
            drawLine(color, f.at(0.02f, 0.86f), f.at(0.98f, 0.86f), stroke.width, StrokeCap.Round)
            drawCircle(color, radius = side * 0.09f, center = f.at(0.78f + 0.02f * wave(phase, 0.25f), 0.2f + 0.02f * wave(phase, 0f)), style = stroke)
        }
        TopPickMood.PARTY -> {
            listOf(
                Triple(0.24f, 0.24f, 0.14f), Triple(0.72f, 0.18f, 0.11f), Triple(0.52f, 0.5f, 0.17f),
                Triple(0.2f, 0.72f, 0.1f), Triple(0.8f, 0.66f, 0.13f), Triple(0.56f, 0.88f, 0.08f),
            ).forEachIndexed { index, (x, y, r) ->
                val pop = 0.85f + 0.15f * wave(phase, index / 6f)
                val spin = (if (index % 2 == 0) 1f else -1f) * phase * 360f
                fivePointStar(path, f.at(x, y), side * r)
                withTransform({
                    rotate(spin, f.at(x, y))
                    scale(pop, pop, f.at(x, y))
                }) { drawPath(path, color, style = stroke) }
            }
        }
        TopPickMood.SLEEP -> {
            path.reset()
            path.arcTo(Rect(f.x(0.12f), f.y(0.24f), f.x(0.88f), f.y(0.76f)), 0f, 180f, true)
            drawPath(path, color, style = stroke)
            for (k in 0..5) {
                val angle = PI.toFloat() * (k / 5f)
                val bx = 0.5f + 0.38f * cos(angle)
                val by = 0.5f + 0.26f * sin(angle)
                val breath = 0.03f * (0.5f + 0.5f * wave(phase, 0f))
                drawLine(
                    color,
                    f.at(bx, by),
                    f.at(bx + (0.07f + breath) * cos(angle), by + (0.07f + breath) * sin(angle)),
                    stroke.width,
                    StrokeCap.Round,
                )
            }
        }
        TopPickMood.SOCIAL -> {
            val gap = 0.18f * (0.5f + 0.5f * wave(phase, 0f))
            drawCircle(color, radius = side * 0.27f, center = f.at(0.5f - gap, 0.5f), style = stroke)
            drawCircle(color, radius = side * 0.27f, center = f.at(0.5f + gap, 0.5f), style = stroke)
        }
        TopPickMood.SPORTS -> {
            val r = side * 0.44f
            drawCircle(color, radius = r, center = f.center, style = stroke)
            path.reset()
            path.addOval(Rect(f.center, r))
            clipPath(path) {
                rotate(phase * 360f, f.center) {
                    drawCircle(color, radius = r * 0.95f, center = Offset(f.center.x - r * 1.25f, f.center.y), style = stroke)
                    drawCircle(color, radius = r * 0.95f, center = Offset(f.center.x + r * 1.25f, f.center.y), style = stroke)
                }
            }
        }
        TopPickMood.SUMMERTIME -> {
            drawCircle(color, radius = side * 0.22f, center = f.center, style = stroke)
            rotate(phase * 30f, f.center) {
                for (k in 0 until 12) {
                    val angle = k * TAU / 12f
                    drawLine(
                        color,
                        Offset(f.center.x + side * 0.31f * cos(angle), f.center.y + side * 0.31f * sin(angle)),
                        Offset(f.center.x + side * 0.46f * cos(angle), f.center.y + side * 0.46f * sin(angle)),
                        stroke.width,
                        StrokeCap.Round,
                    )
                }
            }
        }
        TopPickMood.HOLIDAY -> {
            rotate(phase * 60f, f.center) {
                for (k in 0 until 6) {
                    val angle = k * TAU / 6f
                    val dir = Offset(cos(angle), sin(angle))
                    fun point(d: Float) = Offset(f.center.x + side * d * dir.x, f.center.y + side * d * dir.y)
                    drawLine(color, f.center, point(0.46f), stroke.width, StrokeCap.Round)
                    listOf(0.22f, 0.34f).forEach { d ->
                        val base = point(d)
                        listOf(-0.785f, 0.785f).forEach { turn ->
                            val a = angle + turn
                            drawLine(color, base, Offset(base.x + side * 0.1f * cos(a), base.y + side * 0.1f * sin(a)), stroke.width, StrokeCap.Round)
                        }
                    }
                }
            }
        }
        TopPickMood.WEEKEND -> {
            drawCircle(color, radius = side * 0.46f, center = f.center, style = stroke)
            drawCircle(color, radius = side * 0.16f, center = f.center, style = stroke)
            drawCircle(color, radius = side * 0.025f, center = f.center)
            rotate(phase * 360f, f.center) {
                listOf(0.36f, 0.27f).forEach { r ->
                    val box = Rect(f.center, side * r)
                    drawArc(color, 200f, 70f, false, box.topLeft, box.size, style = stroke)
                    drawArc(color, 20f, 70f, false, box.topLeft, box.size, style = stroke)
                }
            }
        }
        TopPickMood.WELLBEING -> {
            val open = 0.85f + 0.15f * wave(phase, 0f)
            val base = f.at(0.5f, 0.84f)
            listOf(-62f, -31f, 0f, 31f, 62f).forEach { angle ->
                rotate(angle * open, base) {
                    path.reset()
                    path.moveTo(base.x, base.y)
                    path.quadraticTo(f.x(0.66f), f.y(0.52f), f.x(0.5f), f.y(0.14f + (1f - open) * 0.3f))
                    path.quadraticTo(f.x(0.34f), f.y(0.52f), base.x, base.y)
                    drawPath(path, color, style = stroke)
                }
            }
        }
        TopPickMood.WORK -> {
            drawRoundRect(
                color,
                topLeft = f.at(0.16f, 0.18f),
                size = Size(side * 0.68f, side * 0.48f),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(side * 0.03f),
                style = stroke,
            )
            drawLine(color, f.at(0.04f, 0.78f), f.at(0.96f, 0.78f), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.16f, 0.66f), f.at(0.04f, 0.78f), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.84f, 0.66f), f.at(0.96f, 0.78f), stroke.width, StrokeCap.Round)
            val typed = 0.28f + 0.36f * (phase * 1.25f).coerceAtMost(1f)
            drawLine(color, f.at(0.28f, 0.36f), f.at(0.64f, 0.36f), stroke.width, StrokeCap.Round)
            drawLine(color, f.at(0.28f, 0.48f), f.at(typed, 0.48f), stroke.width, StrokeCap.Round)
            if ((phase * 4f).toInt() % 2 == 0) {
                drawLine(color, f.at(typed + 0.04f, 0.43f), f.at(typed + 0.04f, 0.53f), stroke.width, StrokeCap.Round)
            }
        }
    }
}

private fun edgeFade(share: Float): Float = when {
    share > 0.85f -> (1f - share) / 0.15f
    share < 0.15f -> share / 0.15f
    else -> 1f
}.coerceIn(0f, 1f)

private fun easeInOut(t: Float): Float = 0.5f - 0.5f * cos(PI.toFloat() * t.coerceIn(0f, 1f))

private fun bolt(path: Path, f: Frame) {
    val points = listOf(
        0.486f to 0.123f, 0.886f to 0.123f, 0.532f to 0.509f, 0.877f to 0.509f,
        0.114f to 0.895f, 0.409f to 0.614f, 0.105f to 0.614f,
    )
    path.reset()
    points.forEachIndexed { index, (x, y) ->
        if (index == 0) path.moveTo(f.x(x), f.y(y)) else path.lineTo(f.x(x), f.y(y))
    }
    path.close()
}

private fun star(path: Path, f: Frame) {
    path.reset()
    path.moveTo(f.x(0.5f), f.y(0.06f))
    path.quadraticTo(f.x(0.56f), f.y(0.44f), f.x(0.94f), f.y(0.5f))
    path.quadraticTo(f.x(0.56f), f.y(0.56f), f.x(0.5f), f.y(0.94f))
    path.quadraticTo(f.x(0.44f), f.y(0.56f), f.x(0.06f), f.y(0.5f))
    path.quadraticTo(f.x(0.44f), f.y(0.44f), f.x(0.5f), f.y(0.06f))
    path.close()
}

private fun sparkle(path: Path, center: Offset, r: Float) {
    path.reset()
    path.moveTo(center.x, center.y - r)
    path.quadraticTo(center.x + r * 0.12f, center.y - r * 0.12f, center.x + r, center.y)
    path.quadraticTo(center.x + r * 0.12f, center.y + r * 0.12f, center.x, center.y + r)
    path.quadraticTo(center.x - r * 0.12f, center.y + r * 0.12f, center.x - r, center.y)
    path.quadraticTo(center.x - r * 0.12f, center.y - r * 0.12f, center.x, center.y - r)
    path.close()
}

private fun fivePointStar(path: Path, center: Offset, r: Float) {
    path.reset()
    for (i in 0 until 10) {
        val radius = if (i % 2 == 0) r else r * 0.45f
        val angle = i * PI.toFloat() / 5f - PI.toFloat() / 2f
        val x = center.x + radius * cos(angle)
        val y = center.y + radius * sin(angle)
        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
    }
    path.close()
}

private fun crescent(path: Path, f: Frame, cx: Float, cy: Float, r: Float) {
    val disc = Path().apply { addOval(Rect(f.at(cx, cy), f.side * r)) }
    val bite = Path().apply { addOval(Rect(f.at(cx + r * 0.5f, cy - r * 0.3f), f.side * r * 0.88f)) }
    path.reset()
    path.op(disc, bite, PathOperation.Difference)
}

private fun heart(path: Path, f: Frame) {
    val r = 0.24f
    path.reset()
    path.moveTo(f.x(0.5f), f.y(0.92f))
    path.lineTo(f.x(0.28f - r * 0.707f), f.y(0.30f + r * 0.707f))
    path.arcTo(Rect(f.x(0.28f - r), f.y(0.30f - r), f.x(0.28f + r), f.y(0.30f + r)), 135f, 195f, false)
    path.arcTo(Rect(f.x(0.72f - r), f.y(0.30f - r), f.x(0.72f + r), f.y(0.30f + r)), 210f, 195f, false)
    path.close()
}

private fun spiral(path: Path, f: Frame) {
    val turns = 5.5f
    val steps = 320
    path.reset()
    for (k in 0..steps) {
        val t = k.toFloat() / steps
        val angle = PI.toFloat() + t * turns * TAU
        val rx = 0.38f * (1f - 0.72f * t)
        val ry = 0.075f * (1f - 0.55f * t)
        val x = f.x(0.5f + rx * cos(angle))
        val y = f.y(0.10f + 0.78f * t + ry * sin(angle))
        if (k == 0) path.moveTo(x, y) else path.lineTo(x, y)
    }
}

@Composable
internal fun FindYourMoodShelf(onClick: (TopPickMood, String) -> Unit, onShowAll: () -> Unit) {
    val rowState = rememberLazyListState()
    Column(Modifier.padding(bottom = 26.dp)) {
        SectionHeader(stringResource(R.string.find_your_mood), onShowAll = onShowAll)
        LazyRow(
            contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            state = rowState,
        ) {
            items(TopPickMood.entries.filter { it.isCoreMood }, key = { it.name }) { mood ->
                MoodTile(mood, onClick, Modifier.width(SHELF_CARD_WIDTH))
            }
        }
    }
}

@Composable
fun MoodGridPage(
    gridState: LazyGridState,
    onClick: (TopPickMood, String) -> Unit,
    contentPadding: PaddingValues = PaddingValues(0.dp),
) {
    Column(Modifier.fillMaxSize()) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 100.dp),
            state = gridState,
            contentPadding = contentPadding,
            horizontalArrangement = Arrangement.spacedBy(LIBRARY_GRID_SPACING),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier.padding(horizontal = PAGE_GUTTER),
        ) {
            gridItems(TopPickMood.entries, key = { it.name }) { mood ->
                MoodTile(mood, onClick, Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun MoodTile(mood: TopPickMood, onClick: (TopPickMood, String) -> Unit, modifier: Modifier) {
    val title = stringResource(mood.titleRes())
    Column(modifier.clickable { onClick(mood, title) }) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(12.dp))
                .thumbnailBorder(RoundedCornerShape(12.dp)),
        ) {
            MoodArt(mood, mood.style(), Modifier.fillMaxSize(), square = true, still = true)
            Icon(
                painter = painterResource(R.drawable.ic_logo),
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 8.dp, end = 8.dp)
                    .height(11.dp)
                    .aspectRatio(730f / 484f),
            )
        }
        Spacer(Modifier.height(10.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private class CollagePalette(val top: Color, val bottom: Color, val eyebrow: Color)

private val CollagePalettes = listOf(
    CollagePalette(Color(0xFF8F3F00), Color(0xFFFF6A0F), Color(0xFFFFC48A)),
    CollagePalette(Color(0xFF2D8A20), Color(0xFF4FD22C), Color(0xFFCBFFA3)),
    CollagePalette(Color(0xFF173E9E), Color(0xFF2F7BFF), Color(0xFFC0D8FF)),
    CollagePalette(Color(0xFF4A1E99), Color(0xFF8A4BFF), Color(0xFFDCC8FF)),
    CollagePalette(Color(0xFF0B6E6E), Color(0xFF14B8A6), Color(0xFFB5FFF3)),
    CollagePalette(Color(0xFF8E1426), Color(0xFFF0364F), Color(0xFFFFC4CC)),
)

private fun collagePalette(name: String): CollagePalette = CollagePalettes[abs(name.hashCode()) % CollagePalettes.size]

@Composable
private fun ArtistCollageArt(
    images: List<String>,
    palette: CollagePalette,
    modifier: Modifier,
) {
    BoxWithConstraints(
        modifier.background(Brush.verticalGradient(listOf(palette.top, palette.bottom))),
    ) {
        val w = maxWidth
        val h = maxHeight
        val slots = when (images.size) {
            0 -> emptyList()
            1 -> listOf(Triple(0.5f, 0.34f, 0.66f))
            2 -> listOf(Triple(0.40f, 0.28f, 0.60f), Triple(0.72f, 0.52f, 0.36f))
            else -> listOf(Triple(0.37f, 0.257f, 0.594f), Triple(0.76f, 0.48f, 0.333f), Triple(0.457f, 0.608f, 0.29f))
        }
        slots.zip(images).forEach { (slot, url) ->
            val (cx, cy, d) = slot
            val diameter = w * d
            val circle = Modifier
                .offset(x = w * cx - diameter / 2, y = h * cy - diameter / 2)
                .size(diameter)
                .clip(CircleShape)
            AsyncImage(
                model = url.croppedAt(if (d > 0.5f) HEADER_ART_PX else CARD_ART_PX),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = circle.background(Color.Black.copy(alpha = 0.18f)),
            )
        }
    }
}

private val GOOGLE_SIZE_SUFFIX = Regex("""=w\d+-h\d+[^/?]*$""")

private fun String?.croppedAt(width: Int, height: Int = width): String? {
    if (this == null) return null
    if (contains("mzstatic.com")) {
        return replace(Regex("""/\d+x\d+bb\."""), "/${width}x${height}bb.")
    }
    if (GOOGLE_SIZE_SUFFIX.containsMatchIn(this)) {
        return replace(GOOGLE_SIZE_SUFFIX, "=w$width-h$height-p")
    }
    return this
}
