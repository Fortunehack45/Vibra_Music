package com.fortune.vibramusic.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Public
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import com.fortune.vibramusic.ui.realm.AppRealm
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import dev.chrisbanes.haze.materials.HazeMaterials

/**
 * Hyper-fluid liquid-glass Realm Switcher capsule.
 * Lets the listener smoothly toggle between the Music Layer and the Social Layer.
 *
 * Utilizes specular refraction, sliding spring-physics pill, and tactile haptics.
 */
@OptIn(ExperimentalHazeMaterialsApi::class)
@Composable
fun RealmSwitcher(
    activeRealm: AppRealm,
    onRealmSelected: (AppRealm) -> Unit,
    modifier: Modifier = Modifier,
    hazeState: HazeState? = null,
) {
    val haptics = rememberHaptics()
    val isSocial = activeRealm == AppRealm.SOCIAL

    val slideProgress by animateFloatAsState(
        targetValue = if (isSocial) 1f else 0f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioLowBouncy,
            stiffness = Spring.StiffnessMediumLow,
        ),
        label = "realmSlideProgress",
    )

    val isDark = MaterialTheme.colorScheme.surface.let {
        (it.red * 0.299f + it.green * 0.587f + it.blue * 0.114f) < 0.5f
    }

    val glassTint = if (isDark) {
        Color(0x80181A22)
    } else {
        Color.White.copy(alpha = 0.75f)
    }

    val shape = RoundedCornerShape(percent = 50)
    val useLiquidGlass = LocalLiquidGlassEnabled.current && isGlassSupported()

    val containerModifier = modifier
        .shadow(
            elevation = if (isDark) 8.dp else 4.dp,
            shape = shape,
            spotColor = Color.Black.copy(alpha = 0.35f),
        )
        .clip(shape)
        .then(
            if (useLiquidGlass) {
                Modifier.liquidGlass(shape)
            } else if (hazeState != null) {
                Modifier.hazeEffect(hazeState, HazeMaterials.thin()) {
                    tints = listOf(HazeTint(glassTint))
                    blurRadius = 28.dp
                }
            } else {
                Modifier
            }
        )
        .background(
            Brush.verticalGradient(
                if (isDark) listOf(Color(0xB31E222E), Color(0xCC12141A))
                else listOf(Color.White.copy(alpha = 0.95f), Color(0xEEEDEEF2))
            )
        )
        .border(
            width = 1.dp,
            brush = Brush.verticalGradient(
                colors = if (isDark) listOf(
                    Color.White.copy(alpha = 0.50f),
                    Color.White.copy(alpha = 0.15f),
                ) else listOf(
                    Color.White.copy(alpha = 0.90f),
                    Color.Black.copy(alpha = 0.10f),
                ),
            ),
            shape = shape,
        )

    BoxWithConstraints(
        modifier = containerModifier
            .width(180.dp)
            .height(38.dp)
            .padding(3.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        val totalWidth = maxWidth
        val segmentWidth = totalWidth / 2

        // Liquid-glass active sliding pill
        Box(
            modifier = Modifier
                .width(segmentWidth)
                .fillMaxHeight()
                .offset(x = segmentWidth * slideProgress)
                .shadow(
                    elevation = if (isDark) 6.dp else 4.dp,
                    shape = RoundedCornerShape(percent = 50),
                    spotColor = if (isDark) Color.Black.copy(alpha = 0.5f) else Color.Black.copy(alpha = 0.15f),
                )
                .clip(RoundedCornerShape(percent = 50))
                .background(
                    Brush.verticalGradient(
                        colors = if (isDark) listOf(
                            Color.White.copy(alpha = 0.35f),
                            Color.White.copy(alpha = 0.18f),
                        ) else listOf(
                            Color.White,
                            Color(0xFFE8E9F0),
                        ),
                    )
                )
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        colors = if (isDark) listOf(
                            Color.White.copy(alpha = 0.65f),
                            Color.White.copy(alpha = 0.20f),
                        ) else listOf(
                            Color.White,
                            Color.Black.copy(alpha = 0.08f),
                        ),
                    ),
                    shape = RoundedCornerShape(percent = 50),
                ),
        )

        // Interactive Tap Targets and Labels
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RealmSegment(
                label = "Music",
                icon = Icons.Rounded.MusicNote,
                isSelected = activeRealm == AppRealm.MUSIC,
                isDark = isDark,
                onClick = {
                    if (activeRealm != AppRealm.MUSIC) {
                        haptics.play(Haptic.Select)
                        onRealmSelected(AppRealm.MUSIC)
                    }
                },
                modifier = Modifier.weight(1f),
            )

            RealmSegment(
                label = "Social",
                icon = Icons.Rounded.Public,
                isSelected = activeRealm == AppRealm.SOCIAL,
                isDark = isDark,
                onClick = {
                    if (activeRealm != AppRealm.SOCIAL) {
                        haptics.play(Haptic.Select)
                        onRealmSelected(AppRealm.SOCIAL)
                    }
                },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun RealmSegment(
    label: String,
    icon: ImageVector,
    isSelected: Boolean,
    isDark: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }

    val activeColor = if (isDark) Color.White else Color(0xFF111318)
    val inactiveColor = if (isDark) Color.White.copy(alpha = 0.55f) else Color(0xFF111318).copy(alpha = 0.50f)

    val contentColor by animateColorAsState(
        targetValue = if (isSelected) activeColor else inactiveColor,
        animationSpec = tween(200),
        label = "segmentColor",
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        modifier = modifier
            .fillMaxHeight()
            .clip(RoundedCornerShape(percent = 50))
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 12.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = contentColor,
            modifier = Modifier.size(15.dp),
        )
        Spacer(Modifier.width(5.dp))
        Text(
            text = label,
            fontSize = 13.sp,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
            color = contentColor,
        )
    }
}
