package com.fortune.vibramusic.ui.screens

import android.app.Activity
import android.content.Context
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.backup.BackupFrequency
import com.fortune.vibramusic.data.backup.DriveAuth
import com.fortune.vibramusic.data.backup.DriveBackup
import com.fortune.vibramusic.data.backup.RemoteDevice
import com.fortune.vibramusic.data.backup.ReplaySync
import com.fortune.vibramusic.ui.icons.SfIcons
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Settings → Backup and Restore's way in: one row, with how often it syncs on the
 * right, opening [DriveBackupScreen].
 */
@Composable
internal fun DriveBackupSettingsRow(title: String, onClick: () -> Unit) {
    val settings by DriveBackup.settings.collectAsStateWithLifecycle()
    SettingsRow(
        icon = SfIcons.Cloud,
        title = title,
        subtitle = stringResource(R.string.drive_backup_row_subtitle),
        value = when {
            settings.account == null -> stringResource(R.string.off)
            settings.needsSignIn -> stringResource(R.string.drive_sign_in_again)
            settings.needsDevice -> stringResource(R.string.drive_device_not_set)
            else -> settings.frequency.label()
        },
        onClick = onClick,
    )
}

/**
 * Settings → Backup and Restore → Google Drive backup, a page of its own: the account,
 * the last sync and a progress bar while one runs, which device this phone
 * is, how often it syncs, and every device whose listening adds up in Replay.
 *
 * Pushed on the app's navigator like every other Settings page, so Back and the
 * top bar's back button leave it the same way. Its questions — disconnect,
 * remove a device, rename this one — are asked in the app's frosted alerts,
 * which need the app's blur, so they are raised to [com.fortune.vibramusic.MainActivity]
 * the way Settings raises its own.
 *
 * A sync or restore keeps going if the page is left: it runs on
 * [DriveBackup]'s own scope, and the bar picks it up again on coming back.
 */
@Composable
fun DriveBackupScreen(
    contentPadding: PaddingValues,
    /** Opens [DriveDevicesScreen]: back up as a new device, or restore as one. */
    onOpenDevices: () -> Unit,
    onConfirmDisconnect: () -> Unit,
    onConfirmRemove: (RemoteDevice) -> Unit,
    onRename: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by DriveBackup.settings.collectAsStateWithLifecycle()
    val progress by DriveBackup.progress.collectAsStateWithLifecycle()
    val devices by DriveBackup.devices.collectAsStateWithLifecycle()
    val result by DriveBackup.result.collectAsStateWithLifecycle()
    val available = remember { DriveAuth.available(context) }

    var connectError by remember { mutableStateOf<String?>(null) }
    var isUnregistered by remember { mutableStateOf(false) }
    var showSetupGuide by remember { mutableStateOf(false) }

    val sha1 = remember(context) { getCertificateFingerprint(context, "SHA-1") }
    val sha256 = remember(context) { getCertificateFingerprint(context, "SHA-256") }

    // What to do once the consent sheet is answered: connecting is its own
    // errand, but "Sync now" on a lost grant should carry on afterwards.
    var afterSignIn by remember { mutableStateOf<(() -> Unit)?>(null) }

    // After connecting: a Drive with devices in it means this phone has to be
    // told which it is, so the chooser opens straight away — once, from here,
    // rather than from an effect that would reopen it on every return.
    val afterConnect: () -> Unit = {
        if (DriveBackup.settings.value.needsDevice) onOpenDevices()
    }

    val consent = rememberLauncherForActivityResult(
        ActivityResultContracts.StartIntentSenderForResult(),
    ) { answer ->
        val then = afterSignIn
        afterSignIn = null
        // Backed out of the sheet with nothing to say: nothing to report. A
        // sheet that failed instead (an unregistered app, a network error)
        // still comes back cancelled, but with the reason in its data.
        if (answer.resultCode != Activity.RESULT_OK && answer.data == null) {
            return@rememberLauncherForActivityResult
        }
        fun handleDriveError(e: Throwable) {
            if (e is ApiException && e.statusCode == CommonStatusCodes.CANCELED) return
            val raw = e.message.orEmpty()
            val unregistered = (e is ApiException && (e.statusCode == CommonStatusCodes.DEVELOPER_ERROR || e.statusCode == CommonStatusCodes.INTERNAL_ERROR)) ||
                raw.contains("UNREGISTERED_ON_API_CONSOLE", ignoreCase = true) ||
                raw.contains("DEVELOPER_ERROR", ignoreCase = true)
            if (unregistered) {
                isUnregistered = true
                connectError = context.getString(R.string.drive_connect_unregistered)
            } else {
                connectError = raw.ifBlank { context.getString(R.string.unknown_error) }
            }
        }

        scope.launch {
            try {
                DriveBackup.finishSignIn(context, answer.data)
                then?.invoke()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                handleDriveError(e)
            }
        }
    }

    fun signIn(then: () -> Unit) {
        connectError = null
        isUnregistered = false
        fun handleDriveError(e: Throwable) {
            if (e is ApiException && e.statusCode == CommonStatusCodes.CANCELED) return
            val raw = e.message.orEmpty()
            val unregistered = (e is ApiException && (e.statusCode == CommonStatusCodes.DEVELOPER_ERROR || e.statusCode == CommonStatusCodes.INTERNAL_ERROR)) ||
                raw.contains("UNREGISTERED_ON_API_CONSOLE", ignoreCase = true) ||
                raw.contains("DEVELOPER_ERROR", ignoreCase = true)
            if (unregistered) {
                isUnregistered = true
                connectError = context.getString(R.string.drive_connect_unregistered)
            } else {
                connectError = raw.ifBlank { context.getString(R.string.unknown_error) }
            }
        }

        scope.launch {
            try {
                when (val outcome = DriveBackup.beginSignIn(context)) {
                    is DriveAuth.Outcome.Granted -> {
                        DriveBackup.signedIn(context, outcome.accessToken)
                        then()
                    }
                    is DriveAuth.Outcome.NeedsConsent -> {
                        afterSignIn = then
                        consent.launch(IntentSenderRequest.Builder(outcome.intent.intentSender).build())
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                handleDriveError(e)
            }
        }
    }

    // The device list is looked up each time the page opens, so it never
    // describes a phone that has since been removed or renamed.
    LaunchedEffect(settings.account) {
        if (settings.account != null && !settings.needsSignIn) DriveBackup.refreshDevices(context)
    }

    val running = progress != DriveBackup.Progress.Idle
    val connected = settings.account != null
    val ready = connected && !settings.needsDevice

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(contentPadding),
    ) {
        SettingsPageTitle(stringResource(R.string.drive_backup_title))

        if (!available) {
            SettingsGroup(topSpacing = 0.dp) {
                SettingsRow(icon = SfIcons.CloudOff, title = stringResource(R.string.drive_backup_unavailable))
            }
            return@Column
        }

        // ---- Last sync, and the bar while one runs --------------------------
        SettingsGroup(topSpacing = 0.dp) {
            SettingsRow(
                icon = if (settings.lastSyncAt > 0 && settings.lastError == null) SfIcons.CloudDone else SfIcons.Cloud,
                title = stringResource(R.string.drive_sync_last),
                value = if (settings.lastSyncAt > 0) {
                    formatWhen(context, settings.lastSyncAt)
                } else {
                    stringResource(R.string.drive_backup_never)
                },
                subtitle = if (running) null else when (val r = result) {
                    is DriveBackup.Result.Restored -> stringResource(
                        R.string.drive_restore_as_done,
                        r.device,
                        context.countOfMonths(r.summary.months),
                    )
                    is DriveBackup.Result.Failed -> stringResource(
                        if (r.restoring) R.string.drive_restore_failed else R.string.drive_sync_failed,
                        r.message,
                    )
                    is DriveBackup.Result.Synced -> stringResource(R.string.drive_sync_done)
                    null -> settings.lastError?.let { stringResource(R.string.drive_sync_failed, it) }
                },
            )
            if (running) {
                RowDivider()
                ProgressBlock(progress)
            }
        }

        Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 16.dp)) {
            PrimaryButton(
                text = stringResource(R.string.drive_sync_now),
                enabled = ready && !running,
                onClick = {
                    DriveBackup.clearResult()
                    if (settings.needsSignIn) {
                        signIn { DriveBackup.syncNow(context) }
                    } else {
                        DriveBackup.syncNow(context)
                    }
                },
            )
        }

        // ---- Account --------------------------------------------------------
        SettingsGroup(
            header = stringResource(R.string.drive_account_header),
            footer = connectError?.let { stringResource(R.string.drive_connect_failed, it) },
        ) {
            val account = settings.account
            when {
                account == null -> SettingsRow(
                    icon = SfIcons.Person,
                    title = stringResource(R.string.drive_connect),
                    subtitle = stringResource(R.string.drive_connect_subtitle),
                    onClick = { signIn(afterConnect) },
                )
                settings.needsSignIn -> SettingsRow(
                    icon = SfIcons.Warning,
                    title = account,
                    subtitle = stringResource(R.string.drive_sign_in_again_subtitle),
                    value = stringResource(R.string.drive_sign_in_again),
                    onClick = { signIn {} },
                )
                else -> SettingsRow(
                    icon = SfIcons.Person,
                    title = settings.accountName ?: account,
                    subtitle = account.takeIf { settings.accountName != null },
                    value = stringResource(R.string.disconnect),
                    enabled = !running,
                    onClick = onConfirmDisconnect,
                )
            }
        }

        // ---- Diagnostics & Cloud Setup Guide ---------------------------------
        if (isUnregistered || connectError != null || !connected) {
            SettingsGroup(header = stringResource(R.string.drive_setup_diagnostics)) {
                SettingsRow(
                    icon = Icons.Rounded.Info,
                    title = stringResource(R.string.drive_setup_dialog_title),
                    subtitle = stringResource(R.string.drive_setup_diagnostics_subtitle),
                    value = stringResource(R.string.drive_view_setup_guide),
                    onClick = { showSetupGuide = true },
                )
            }
        }

        // ---- This phone -----------------------------------------------------
        if (connected) {
            SettingsGroup(
                header = stringResource(R.string.drive_this_phone_header),
                footer = settings.forkedTo?.let { stringResource(R.string.drive_forked_notice, it) },
            ) {
                if (settings.needsDevice) {
                    SettingsRow(
                        icon = SfIcons.Warning,
                        title = stringResource(R.string.drive_choose_device),
                        subtitle = stringResource(R.string.drive_choose_device_subtitle),
                        enabled = !running,
                        onClick = onOpenDevices,
                    )
                } else {
                    SettingsRow(
                        icon = SfIcons.Phone,
                        title = settings.identity.deviceName,
                        subtitle = stringResource(R.string.drive_this_phone_subtitle),
                        value = stringResource(R.string.drive_rename),
                        enabled = !running,
                        onClick = {
                            DriveBackup.dismissForkNotice()
                            onRename(settings.identity.deviceName)
                        },
                    )
                }
            }
        }

        // ---- Schedule -------------------------------------------------------
        ChoiceGroup(
            header = stringResource(R.string.drive_auto_sync_header),
            options = BackupFrequency.entries,
            selected = settings.frequency,
            label = { it.label() },
            footer = stringResource(R.string.drive_auto_sync_footer),
            enabled = { ready },
            onSelect = DriveBackup::setFrequency,
        )
        SettingsGroup {
            SettingsRow(
                icon = SfIcons.SignalCellularAlt,
                title = stringResource(R.string.drive_over_cellular),
                subtitle = stringResource(R.string.drive_over_cellular_subtitle),
                enabled = ready,
                trailing = {
                    Switch(
                        checked = settings.overCellular,
                        onCheckedChange = DriveBackup::setOverCellular,
                        enabled = ready,
                        colors = SwitchDefaults.colors(
                            checkedTrackColor = MaterialTheme.colorScheme.primary,
                            checkedThumbColor = MaterialTheme.colorScheme.onPrimary,
                            checkedBorderColor = MaterialTheme.colorScheme.primary,
                            uncheckedTrackColor = Color.White.copy(alpha = 0.15f),
                            uncheckedThumbColor = Color.White.copy(alpha = 0.7f),
                            uncheckedBorderColor = Color.Transparent,
                        ),
                    )
                },
                onClick = { DriveBackup.setOverCellular(!settings.overCellular) },
            )
        }

        // ---- Devices --------------------------------------------------------
        if (connected && !settings.needsSignIn) {
            SettingsGroup(
                header = stringResource(R.string.drive_devices_header),
                footer = stringResource(R.string.drive_devices_footer),
            ) {
                when (val d = devices) {
                    DriveBackup.Devices.Unknown, DriveBackup.Devices.Checking -> SettingsRow(
                        icon = SfIcons.Cloud,
                        title = stringResource(R.string.drive_devices_checking),
                        trailing = { CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp) },
                    )
                    is DriveBackup.Devices.Failed -> SettingsRow(
                        icon = SfIcons.ErrorOutline,
                        title = stringResource(R.string.drive_devices_failed, d.message),
                        onClick = { scope.launch { DriveBackup.refreshDevices(context) } },
                    )
                    is DriveBackup.Devices.Loaded -> if (d.list.isEmpty()) {
                        SettingsRow(icon = SfIcons.Cloud, title = stringResource(R.string.drive_devices_none))
                    } else {
                        d.list.forEachIndexed { index, device ->
                            if (index > 0) RowDivider()
                            val mine = device.deviceId == settings.identity.deviceId
                            SettingsRow(
                                icon = SfIcons.Phone,
                                title = device.name,
                                subtitle = describe(device),
                                value = if (mine) stringResource(R.string.drive_this_phone) else null,
                                enabled = !running,
                                onClick = { onConfirmRemove(device) },
                            )
                        }
                    }
                }
            }
        }

        // ---- Restore --------------------------------------------------------
        SettingsGroup(
            header = stringResource(R.string.drive_restore_header),
            footer = stringResource(R.string.drive_backup_footer),
        ) {
            SettingsRow(
                icon = SfIcons.FileDownload,
                title = stringResource(R.string.drive_restore_as_title),
                subtitle = stringResource(
                    if (connected) R.string.drive_restore_as_subtitle else R.string.drive_restore_connect_first,
                ),
                enabled = connected && !settings.needsSignIn && !running,
                onClick = onOpenDevices,
            )
        }
        Spacer(Modifier.height(32.dp))
    }

    if (showSetupGuide) {
        DriveSetupGuideDialog(
            packageName = context.packageName,
            sha1 = sha1,
            sha256 = sha256,
            onDismiss = { showSetupGuide = false },
        )
    }
}

/** What is happening, in words, over a bar that fills as it goes. */
@Composable
private fun ProgressBlock(progress: DriveBackup.Progress) {
    val step = (progress as? DriveBackup.Progress.Running)?.step
    val (text, fraction) = when (step) {
        null, ReplaySync.Step.Preparing -> stringResource(R.string.drive_sync_preparing) to null
        is ReplaySync.Step.Uploading -> stringResource(
            R.string.drive_sync_uploading,
            (step.done + 1).coerceAtMost(step.total).coerceAtLeast(1),
            step.total.coerceAtLeast(1),
        ) to step.done.fractionOf(step.total)
        is ReplaySync.Step.Downloading -> stringResource(
            R.string.drive_sync_downloading,
            step.device,
            (step.done + 1).coerceAtMost(step.total),
            step.total,
        ) to step.done.fractionOf(step.total)
        ReplaySync.Step.Restoring -> stringResource(R.string.drive_backup_restoring) to null
    }
    Column(Modifier.padding(horizontal = ROW_INSET, vertical = 14.dp)) {
        Text(
            text = if (fraction != null) "$text · ${(fraction * 100).toInt()}%" else text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))
        DriveProgressBar(fraction)
    }
}

/** Drawn as Downloads draws its batch bar: thin, round-capped, no gap. */
@Composable
internal fun DriveProgressBar(fraction: Float?) {
    val modifier = Modifier
        .fillMaxWidth()
        .height(4.dp)
    val color = MaterialTheme.colorScheme.primary
    val track = MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
    if (fraction != null) {
        LinearProgressIndicator(
            progress = { fraction },
            modifier = modifier,
            color = color,
            trackColor = track,
            strokeCap = StrokeCap.Round,
            gapSize = 0.dp,
            drawStopIndicator = {},
        )
    } else {
        LinearProgressIndicator(
            modifier = modifier,
            color = color,
            trackColor = track,
            strokeCap = StrokeCap.Round,
            gapSize = 0.dp,
        )
    }
}

private fun Int.fractionOf(total: Int): Float? =
    if (total > 0) (toFloat() / total).coerceIn(0f, 1f) else null

@Composable
private fun BackupFrequency.label(): String = stringResource(
    when (this) {
        BackupFrequency.OFF -> R.string.off
        BackupFrequency.DAILY -> R.string.drive_frequency_daily
        BackupFrequency.WEEKLY -> R.string.drive_frequency_weekly
        BackupFrequency.MONTHLY -> R.string.drive_frequency_monthly
    },
)

/** "Synced 12 Nov, 21:04 · 14 months · 1.2 MB" — enough to tell devices apart. */
@Composable
internal fun describe(device: RemoteDevice): String {
    val context = LocalContext.current
    return listOfNotNull(
        device.updatedAt.takeIf { it > 0 }?.let { stringResource(R.string.drive_device_synced, formatWhen(context, it)) },
        pluralStringResource(R.plurals.listening_month_count, device.months, device.months),
        device.sizeBytes.takeIf { it > 0 }?.let { Formatter.formatShortFileSize(context, it) },
    ).joinToString(" · ")
}

internal fun formatWhen(context: Context, millis: Long): String = DateUtils.formatDateTime(
    context,
    millis,
    DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_MONTH,
)

@Composable
private fun DriveSetupGuideDialog(
    packageName: String,
    sha1: String,
    sha256: String,
    onDismiss: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    val haptics = rememberHaptics()
    var copiedItem by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = stringResource(R.string.drive_setup_dialog_title),
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    text = stringResource(R.string.drive_setup_dialog_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                // Package name card
                CredentialCopyCard(
                    label = stringResource(R.string.drive_package_name_label),
                    value = packageName,
                    copied = copiedItem == packageName,
                    onCopy = {
                        haptics.play(Haptic.Tap)
                        clipboard.setText(AnnotatedString(packageName))
                        copiedItem = packageName
                    },
                )

                // SHA-1 card
                CredentialCopyCard(
                    label = stringResource(R.string.drive_sha1_label),
                    value = sha1,
                    copied = copiedItem == sha1,
                    onCopy = {
                        haptics.play(Haptic.Tap)
                        clipboard.setText(AnnotatedString(sha1))
                        copiedItem = sha1
                    },
                )

                // SHA-256 card
                CredentialCopyCard(
                    label = stringResource(R.string.drive_sha256_label),
                    value = sha256,
                    copied = copiedItem == sha256,
                    onCopy = {
                        haptics.play(Haptic.Tap)
                        clipboard.setText(AnnotatedString(sha256))
                        copiedItem = sha256
                    },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(
                    text = stringResource(android.R.string.ok),
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.Bold,
                )
            }
        },
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(20.dp),
    )
}

@Composable
private fun CredentialCopyCard(
    label: String,
    value: String,
    copied: Boolean,
    onCopy: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f))
            .clickable(onClick = onCopy)
            .padding(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = stringResource(if (copied) R.string.drive_copied else R.string.drive_tap_to_copy),
                style = MaterialTheme.typography.labelSmall,
                color = if (copied) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

private fun getCertificateFingerprint(context: Context, algorithm: String): String {
    return try {
        val packageInfo = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            context.packageManager.getPackageInfo(
                context.packageName,
                android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(
                context.packageName,
                android.content.pm.PackageManager.GET_SIGNATURES,
            )
        }
        val signatures = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.let { si ->
                if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures
        }
        val cert = signatures?.firstOrNull()?.toByteArray() ?: return "Unavailable"
        val md = java.security.MessageDigest.getInstance(algorithm)
        val digest = md.digest(cert)
        digest.joinToString(":") { "%02X".format(it) }
    } catch (e: Exception) {
        "Unavailable: ${e.message}"
    }
}
