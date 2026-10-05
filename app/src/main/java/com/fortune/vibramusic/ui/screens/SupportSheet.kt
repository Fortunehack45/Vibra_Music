package com.fortune.vibramusic.ui.screens

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.AccountBalanceWallet
import androidx.compose.material.icons.rounded.Block
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Code
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.LocalCafe
import androidx.compose.material.icons.rounded.OpenInNew
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.VolunteerActivism
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.settings.SupportConfig
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics

/**
 * Voluntary supporter and tip sheet for Vibra Music.
 * Highlights privacy guarantees (no database, no tracking) and presents
 * direct supporter platforms and optional crypto addresses.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SupportSheet(
    onDismiss: () -> Unit = {},
) {
    val context = LocalContext.current
    val haptics = rememberHaptics()
    val clipboardManager = LocalClipboardManager.current
    val scrollState = rememberScrollState()

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(scrollState)
            .padding(horizontal = 20.dp, vertical = 8.dp)
            .padding(bottom = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // Hero Icon Box
        Box(
            modifier = Modifier
                .size(60.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Rounded.Favorite,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(30.dp),
            )
        }

        Spacer(Modifier.height(14.dp))

        Text(
            text = stringResource(R.string.support_vibra_header),
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onBackground,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(8.dp))

        Text(
            text = stringResource(R.string.support_vibra_description),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            lineHeight = 20.sp,
            modifier = Modifier.padding(horizontal = 8.dp),
        )

        Spacer(Modifier.height(16.dp))

        // Guarantees Badges
        FlowRow(
            horizontalArrangement = Arrangement.Center,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            SupportBadge(
                icon = Icons.Rounded.Block,
                label = stringResource(R.string.support_badge_adfree),
            )
            Spacer(Modifier.width(8.dp))
            SupportBadge(
                icon = Icons.Rounded.Security,
                label = stringResource(R.string.support_badge_privacy),
            )
            Spacer(Modifier.width(8.dp))
            SupportBadge(
                icon = Icons.Rounded.Code,
                label = stringResource(R.string.support_badge_foss),
            )
        }

        Spacer(Modifier.height(20.dp))
        HorizontalDivider(thickness = 0.5.dp, color = MaterialTheme.colorScheme.outlineVariant)
        Spacer(Modifier.height(16.dp))

        // Supporter Platforms Section
        Text(
            text = stringResource(R.string.support_platforms_title),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 12.dp),
        )

        val platforms = listOfNotNull(
            if (SupportConfig.buyMeACoffeeUrl.isNotBlank()) {
                Triple(
                    stringResource(R.string.support_buy_me_a_coffee),
                    stringResource(R.string.support_buy_me_a_coffee_sub),
                    SupportConfig.buyMeACoffeeUrl,
                )
            } else null,
            if (SupportConfig.kofiUrl.isNotBlank()) {
                Triple(
                    stringResource(R.string.support_kofi),
                    stringResource(R.string.support_kofi_sub),
                    SupportConfig.kofiUrl,
                )
            } else null,
            if (SupportConfig.githubSponsorsUrl.isNotBlank()) {
                Triple(
                    stringResource(R.string.support_github_sponsors),
                    stringResource(R.string.support_github_sponsors_sub),
                    SupportConfig.githubSponsorsUrl,
                )
            } else null,
            if (SupportConfig.patreonUrl.isNotBlank()) {
                Triple(
                    stringResource(R.string.support_patreon),
                    stringResource(R.string.support_patreon_sub),
                    SupportConfig.patreonUrl,
                )
            } else null,
            if (SupportConfig.paypalUrl.isNotBlank()) {
                Triple(
                    stringResource(R.string.support_paypal),
                    stringResource(R.string.support_paypal_sub),
                    SupportConfig.paypalUrl,
                )
            } else null,
        )

        platforms.forEach { (name, subtitle, url) ->
            SupportPlatformRow(
                icon = when {
                    name.contains("Coffee", ignoreCase = true) -> Icons.Rounded.LocalCafe
                    name.contains("GitHub", ignoreCase = true) -> Icons.Rounded.Code
                    else -> Icons.Rounded.VolunteerActivism
                },
                title = name,
                subtitle = subtitle,
                onClick = {
                    haptics.play(Haptic.Tap)
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    }
                },
            )
            Spacer(Modifier.height(8.dp))
        }

        // Crypto Wallets Section (if any configured)
        if (SupportConfig.hasAnyCrypto) {
            Spacer(Modifier.height(16.dp))
            Text(
                text = stringResource(R.string.support_crypto_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 12.dp),
            )

            val cryptoWallets = listOfNotNull(
                if (SupportConfig.usdtAddress.isNotBlank()) "USDT" to SupportConfig.usdtAddress else null,
                if (SupportConfig.btcAddress.isNotBlank()) "BTC" to SupportConfig.btcAddress else null,
                if (SupportConfig.ethAddress.isNotBlank()) "ETH" to SupportConfig.ethAddress else null,
                if (SupportConfig.solAddress.isNotBlank()) "SOL" to SupportConfig.solAddress else null,
            )

            cryptoWallets.forEach { (coin, address) ->
                CryptoWalletRow(
                    currency = coin,
                    address = address,
                    onCopy = {
                        clipboardManager.setText(AnnotatedString(address))
                        haptics.play(Haptic.Select)
                        Toast.makeText(
                            context,
                            context.getString(R.string.support_copied_to_clipboard, coin),
                            Toast.LENGTH_SHORT,
                        ).show()
                    },
                )
                Spacer(Modifier.height(8.dp))
            }
        }

        Spacer(Modifier.height(20.dp))

        Text(
            text = stringResource(R.string.support_thank_you),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SupportBadge(
    icon: ImageVector,
    label: String,
) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SupportPlatformRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.width(8.dp))
            Icon(
                imageVector = Icons.AutoMirrored.Rounded.OpenInNew,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun CryptoWalletRow(
    currency: String,
    address: String,
    onCopy: () -> Unit,
) {
    var copied by remember { mutableStateOf(false) }

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
        modifier = Modifier
            .fillMaxWidth()
            .clickable {
                copied = true
                onCopy()
            },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.6f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.AccountBalanceWallet,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSecondaryContainer,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    text = currency,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = address,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(8.dp))
            IconButton(
                onClick = {
                    copied = true
                    onCopy()
                },
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    imageVector = if (copied) Icons.Rounded.Check else Icons.Rounded.ContentCopy,
                    contentDescription = stringResource(R.string.support_copy_address),
                    tint = if (copied) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}
