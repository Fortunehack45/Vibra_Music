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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.DynamicFeed
import androidx.compose.material.icons.rounded.EmojiEvents
import androidx.compose.material.icons.rounded.Forum
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.settings.AppSettings
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import dev.chrisbanes.haze.materials.HazeMaterials

enum class SocialTab(val label: String, val icon: ImageVector) {
    FEED("Feed", Icons.Rounded.DynamicFeed),
    TWIN("Twin", Icons.Rounded.AutoAwesome),
    QUIZ("Quiz", Icons.Rounded.EmojiEvents),
    MESSAGES("Chat", Icons.Rounded.Forum),
    PROFILE("Profile", Icons.Rounded.AccountCircle),
}

/**
 * Dedicated liquid-glass bottom navigation bar for the Vibra Social realm.
 * Adopts the exact materials, spring physics, and frosted blur of the Music bar.
 */
@OptIn(ExperimentalHazeMaterialsApi::class)
@Composable
fun SocialBottomBar(
    selectedTab: SocialTab,
    onTabSelected: (SocialTab) -> Unit,
    modifier: Modifier = Modifier,
    hazeState: HazeState? = null,
) {
    val haptics = rememberHaptics()
    val reduceDynamicBlur by AppSettings.reduceDynamicBlur.collectAsStateWithLifecycle()
    val shape = remember { RoundedCornerShape(percent = 50) }

    val containerModifier = if (hazeState != null && !reduceDynamicBlur) {
        modifier
            .clip(shape)
            .optimizedHazeEffect(hazeState, HazeMaterials.thin()) {
                tints = listOf(HazeTint(Color.Black.copy(alpha = 0.50f)))
                blurRadius = 24.dp
            }
            .border(
                width = 1.dp,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.25f),
                        Color.White.copy(alpha = 0.08f),
                    )
                ),
                shape = shape,
            )
    } else {
        modifier
            .clip(shape)
            .background(Color(0xFF14171E))
            .border(
                width = 1.dp,
                color = Color.White.copy(alpha = 0.14f),
                shape = shape,
            )
    }

    Box(
        modifier = containerModifier
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            SocialTab.values().forEach { tab ->
                val isSelected = tab == selectedTab
                SocialBarItem(
                    tab = tab,
                    isSelected = isSelected,
                    onClick = {
                        if (!isSelected) {
                            haptics.play(Haptic.Select)
                            onTabSelected(tab)
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun SocialBarItem(
    tab: SocialTab,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }

    val scale by animateFloatAsState(
        targetValue = if (isSelected) 1.08f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "socialTabScale",
    )

    val contentColor by animateColorAsState(
        targetValue = if (isSelected) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.50f),
        animationSpec = tween(200),
        label = "socialTabColor",
    )

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clip(RoundedCornerShape(percent = 50))
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 14.dp, vertical = 4.dp),
    ) {
        Icon(
            imageVector = tab.icon,
            contentDescription = tab.label,
            tint = contentColor,
            modifier = Modifier
                .size(24.dp)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                },
        )
        Spacer(Modifier.height(3.dp))
        Text(
            text = tab.label,
            fontSize = 11.sp,
            color = contentColor,
        )
    }
}
