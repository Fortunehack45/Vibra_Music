package com.fortune.vibramusic.ui.components

import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.util.lerp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.settings.AppSettings
import kotlin.math.roundToInt

@Immutable
data class IosMenuColors(
    val dark: Boolean,
    val fill: Color,
    val rim: Color,
    val label: Color,
    val secondaryLabel: Color,
    val separator: Color,
    val pressed: Color,
)

private val DarkMenu = IosMenuColors(
    dark = true,
    fill = Color(0xEB1C1C1E),
    rim = Color.White.copy(alpha = 0.12f),
    label = Color.White,
    secondaryLabel = Color.White.copy(alpha = 0.70f),
    separator = Color.White.copy(alpha = 0.10f),
    pressed = Color.White.copy(alpha = 0.10f),
)

private val LightMenu = IosMenuColors(
    dark = false,
    fill = Color(0xF2F6F6F7),
    rim = Color.Black.copy(alpha = 0.08f),
    label = Color(0xFF1A1A1A),
    secondaryLabel = Color(0xFF1A1A1A).copy(alpha = 0.55f),
    separator = Color.Black.copy(alpha = 0.09f),
    pressed = Color.Black.copy(alpha = 0.07f),
)

@Composable
fun iosMenuColors(): IosMenuColors =
    if (MaterialTheme.colorScheme.background.luminance() < 0.5f) DarkMenu else LightMenu

val IosMenuShape: CornerBasedShape = RoundedCornerShape(26.dp)
val IosMenuWidth = 260.dp

@Composable
fun Modifier.iosMenuPanel(
    colors: IosMenuColors = iosMenuColors(),
    shape: CornerBasedShape = IosMenuShape,
): Modifier {
    val reduceDynamicBlur by AppSettings.reduceDynamicBlur.collectAsStateWithLifecycle()
    val isGlass = LocalLiquidGlassEnabled.current && isGlassSupported() && !reduceDynamicBlur
    return if (isGlass) {
        this.liquidGlass(shape)
    } else {
        this.clip(shape)
            .background(colors.fill)
            .border(0.5.dp, colors.rim, shape)
    }
}

fun Modifier.iosMenuShadow(shape: Shape = IosMenuShape): Modifier = shadow(
    elevation = 20.dp,
    shape = shape,
    ambientColor = Color.Black.copy(alpha = 0.35f),
    spotColor = Color.Black.copy(alpha = 0.35f),
)

@Composable
fun IosMenuSeparator(colors: IosMenuColors = iosMenuColors()) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(14.dp)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(0.5.dp)
                .background(colors.separator),
        )
    }
}

@Composable
fun IosMenuRow(
    label: String,
    icon: ImageVector?,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    description: String? = null,
    value: String? = null,
    iconTint: Color? = null,
    labelColor: Color? = null,
    valueColor: Color? = null,
    enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
) {
    val colors = iosMenuColors()
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val alpha = if (enabled) 1f else 0.4f
    val foreground = labelColor ?: colors.label
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (pressed) colors.pressed else Color.Transparent)
            .then(
                if (onClick != null) {
                    Modifier.clickable(
                        interactionSource = interaction,
                        indication = null,
                        enabled = enabled,
                        onClick = onClick,
                    )
                } else {
                    Modifier
                },
            )
            .heightIn(min = 44.dp)
            .padding(start = 12.dp, end = 14.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
            if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = (iconTint ?: foreground).copy(alpha = alpha),
                    modifier = Modifier.size(21.dp),
                )
            }
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = label,
                color = foreground.copy(alpha = alpha),
                style = MaterialTheme.typography.bodyLarge.copy(
                    fontSize = 16.sp,
                    lineHeight = 20.sp,
                    letterSpacing = (-0.2).sp,
                ),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (description != null) {
                Text(
                    text = description,
                    color = colors.secondaryLabel.copy(alpha = colors.secondaryLabel.alpha * alpha),
                    fontSize = 13.sp,
                    lineHeight = 16.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (value != null) {
            Spacer(Modifier.width(10.dp))
            Text(
                text = value,
                color = (valueColor ?: colors.secondaryLabel).copy(alpha = alpha),
                fontSize = 14.sp,
                maxLines = 1,
            )
        }
        trailing?.invoke()
    }
}

/**
 * Floating Liquid Glass popup anchored to a button (e.g. three-dots).
 */
@Composable
fun <T : Any> IosMenuPopover(
    item: T?,
    anchor: Rect?,
    onDismiss: () -> Unit,
    content: @Composable (T) -> Unit,
) {
    var last by remember { mutableStateOf<Pair<T, Rect?>?>(null) }
    val requested = item?.let { it to anchor }
    if (requested != null && requested.first != last?.first) {
        SideEffect { last = requested }
    }
    val shown = requested ?: last ?: return
    val (menuItem, menuAnchor) = shown
    val open = item != null

    val context = LocalContext.current
    val appReduceAnimation by AppSettings.reduceAnimation.collectAsStateWithLifecycle()
    val systemAnimationsOff = remember(context) {
        runCatching {
            Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        }.getOrDefault(false)
    }
    val reduceMotion = appReduceAnimation || systemAnimationsOff

    val progress = remember { Animatable(0f) }
    LaunchedEffect(open) {
        if (open) {
            progress.animateTo(
                1f,
                if (reduceMotion) {
                    tween(durationMillis = 120, easing = LinearEasing)
                } else {
                    spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 600f)
                },
            )
        } else {
            progress.animateTo(0f, tween(durationMillis = if (reduceMotion) 100 else 160, easing = FastOutSlowInEasing))
            last = null
        }
    }

    BackHandler(enabled = open, onBack = onDismiss)

    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val scrim = Color.Black.copy(alpha = if (dark) 0.32f else 0.16f)
    val insets = WindowInsets.safeDrawing
    var overlayOffset by remember { mutableStateOf(Offset.Zero) }

    Layout(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { overlayOffset = it.positionInWindow() },
        content = {
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer { alpha = progress.value.coerceIn(0f, 1f) }
                    .background(scrim)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        enabled = open,
                        onClick = onDismiss,
                    ),
            )
            Box(Modifier.iosMenuShadow(IosMenuShape))
            Box(
                Modifier
                    .pointerInput(Unit) {}
                    .iosMenuPanel(),
                propagateMinConstraints = true,
            ) {
                Column(
                    Modifier
                        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                        .padding(vertical = 8.dp),
                ) {
                    content(menuItem)
                }
            }
        },
    ) { measurables, constraints ->
        val width = constraints.maxWidth
        val height = constraints.maxHeight
        val margin = 14.dp.roundToPx()
        val top = insets.getTop(this) + 8.dp.roundToPx()
        val bottom = height - insets.getBottom(this) - 12.dp.roundToPx()

        val scrimPlaceable = measurables[0].measure(Constraints.fixed(width, height))
        val panelWidth = IosMenuWidth.roundToPx().coerceAtMost(width - margin * 2)
        val panel = measurables[2].measure(
            Constraints(minWidth = panelWidth, maxWidth = panelWidth, maxHeight = (bottom - top).coerceAtLeast(0)),
        )
        val shadowPlate = measurables[1].measure(Constraints.fixed(panel.width, panel.height))
        val anchorBounds = menuAnchor?.translate(-overlayOffset)
        val right = anchorBounds?.right?.roundToInt() ?: (width - margin)
        val panelX = (right - panel.width)
            .coerceIn(margin, (width - margin - panel.width).coerceAtLeast(margin))
        val lowest = (bottom - panel.height).coerceAtLeast(top)
        val hangsDown = anchorBounds != null && anchorBounds.center.y < height / 2f
        val panelY = if (hangsDown) anchorBounds.top.roundToInt().coerceIn(top, lowest) else lowest

        val growth: GraphicsLayerScope.() -> Unit = {
            val p = progress.value
            alpha = (p * 2.5f).coerceIn(0f, 1f)
            if (!reduceMotion) {
                transformOrigin = TransformOrigin(1f, if (hangsDown) 0f else 1f)
                val scale = lerp(0.35f, 1f, p)
                scaleX = scale
                scaleY = scale
            }
        }
        layout(width, height) {
            scrimPlaceable.place(0, 0)
            shadowPlate.placeWithLayer(panelX, panelY, layerBlock = growth)
            panel.placeWithLayer(panelX, panelY) {
                growth()
                compositingStrategy = CompositingStrategy.Offscreen
            }
        }
    }
}
