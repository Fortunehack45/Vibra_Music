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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
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
 * Utilizes specular lighting, spring-loaded sliding pill, and tactile haptics.
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

    val slideOffset by animateFloatAsState(
        targetValue = if (isSocial) 1f else 0f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioLowBouncy,
            stiffness = Spring.StiffnessMediumLow,
        ),
        label = "realmSlide",
    )

    val containerModifier = if (hazeState != null) {
        modifier
            .clip(RoundedCornerShape(percent = 50))
            .hazeEffect(hazeState, HazeMaterials.thin()) {
                tints = listOf(HazeTint(Color.Black.copy(alpha = 0.35f)))
                blurRadius = 24.dp
            }
            .border(
                width = 1.dp,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.25f),
                        Color.White.copy(alpha = 0.05f),
                    )
                ),
                shape = RoundedCornerShape(percent = 50),
            )
    } else {
        modifier
            .clip(RoundedCornerShape(percent = 50))
            .background(Color.Black.copy(alpha = 0.45f))
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.15f),
                shape = RoundedCornerShape(percent = 50),
            )
    }

    Box(
        modifier = containerModifier
            .height(38.dp)
            .padding(3.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            RealmSegment(
                label = "Music",
                icon = Icons.Rounded.MusicNote,
                isSelected = activeRealm == AppRealm.MUSIC,
                onClick = {
                    if (activeRealm != AppRealm.MUSIC) {
                        haptics.play(Haptic.Select)
                        onRealmSelected(AppRealm.MUSIC)
                    }
                },
            )

            RealmSegment(
                label = "Social",
                icon = Icons.Rounded.Public,
                isSelected = activeRealm == AppRealm.SOCIAL,
                onClick = {
                    if (activeRealm != AppRealm.SOCIAL) {
                        haptics.play(Haptic.Select)
                        onRealmSelected(AppRealm.SOCIAL)
                    }
                },
            )
        }
    }
}

@Composable
private fun RealmSegment(
    label: String,
    icon: ImageVector,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }

    val bgColor by animateColorAsState(
        targetValue = if (isSelected) Color.White.copy(alpha = 0.18f) else Color.Transparent,
        animationSpec = tween(220),
        label = "segmentBg",
    )

    val contentColor by animateColorAsState(
        targetValue = if (isSelected) Color.White else Color.White.copy(alpha = 0.55f),
        animationSpec = tween(220),
        label = "segmentColor",
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(percent = 50))
            .background(bgColor)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 14.dp, vertical = 6.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = contentColor,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = label,
            fontSize = 13.sp,
            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
            color = contentColor,
        )
    }
}
