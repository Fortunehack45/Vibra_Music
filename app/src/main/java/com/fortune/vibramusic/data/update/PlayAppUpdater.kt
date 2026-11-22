package com.fortune.vibramusic.data.update

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import com.google.android.play.core.appupdate.AppUpdateInfo
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Manages Google Play in-app updates so users are notified directly when a new
 * version of the app is available on Google Play.
 */
object PlayAppUpdater {
    private const val TAG = "PlayAppUpdater"
    const val REQUEST_CODE_APP_UPDATE = 8372

    private var appUpdateManager: AppUpdateManager? = null
    private var installListener: InstallStateUpdatedListener? = null

    private val _isUpdateDownloaded = MutableStateFlow(false)
    val isUpdateDownloaded = _isUpdateDownloaded.asStateFlow()

    private val _updateAvailable = MutableStateFlow(false)
    val updateAvailable = _updateAvailable.asStateFlow()

    fun init(context: Context) {
        try {
            val manager = AppUpdateManagerFactory.create(context.applicationContext)
            appUpdateManager = manager

            val listener = InstallStateUpdatedListener { state ->
                if (state.installStatus() == InstallStatus.DOWNLOADED) {
                    _isUpdateDownloaded.value = true
                    Log.i(TAG, "Update downloaded and ready to install")
                }
            }
            installListener = listener
            manager.registerListener(listener)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to initialize AppUpdateManager", e)
        }
    }

    /**
     * Checks for updates silently in the background on startup.
     * If a flexible update is available, it can be prompted to the user.
     */
    fun checkForUpdate(activity: Activity? = null, autoPromptFlexible: Boolean = true) {
        val manager = appUpdateManager ?: return
        try {
            manager.appUpdateInfo.addOnSuccessListener { info ->
                if (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE) {
                    _updateAvailable.value = true
                    Log.i(TAG, "New app update available: version code ${info.availableVersionCode()}")

                    if (activity != null && autoPromptFlexible && info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)) {
                        try {
                            manager.startUpdateFlowForResult(
                                info,
                                activity,
                                AppUpdateOptions.defaultOptions(AppUpdateType.FLEXIBLE),
                                REQUEST_CODE_APP_UPDATE,
                            )
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to start flexible update flow", e)
                        }
                    }
                } else if (info.installStatus() == InstallStatus.DOWNLOADED) {
                    _isUpdateDownloaded.value = true
                } else {
                    _updateAvailable.value = false
                }
            }.addOnFailureListener { e ->
                Log.w(TAG, "Failed to check for Google Play update", e)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Exception during checkForUpdate", e)
        }
    }

    /**
     * Manually triggers an update check (e.g. from Settings -> "Check for updates").
     * If an update is available on Google Play, the official Google Play update sheet
     * is launched directly. If no in-app update is reported or on failure, falls back
     * to launching the Play Store store page.
     */
    fun requestUpdate(activity: Activity, onNoUpdate: () -> Unit = {}) {
        val manager = appUpdateManager
        if (manager == null) {
            openPlayStore(activity)
            return
        }

        try {
            manager.appUpdateInfo.addOnSuccessListener { info ->
                if (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE) {
                    _updateAvailable.value = true
                    val updateType = when {
                        info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE) -> AppUpdateType.FLEXIBLE
                        info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE) -> AppUpdateType.IMMEDIATE
                        else -> null
                    }

                    if (updateType != null) {
                        try {
                            manager.startUpdateFlowForResult(
                                info,
                                activity,
                                AppUpdateOptions.defaultOptions(updateType),
                                REQUEST_CODE_APP_UPDATE,
                            )
                            return@addOnSuccessListener
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to launch in-app update flow, opening Play Store", e)
                        }
                    }
                    openPlayStore(activity)
                } else {
                    onNoUpdate()
                }
            }.addOnFailureListener {
                openPlayStore(activity)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Exception requesting update", e)
            openPlayStore(activity)
        }
    }

    /**
     * When a flexible update has completed downloading in the background, completes
     * the install and restarts the app.
     */
    fun completeUpdate() {
        try {
            appUpdateManager?.completeUpdate()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to complete update", e)
        }
    }

    /**
     * Resumes in-progress updates if the app was suspended while an update was running.
     */
    fun onResume(activity: Activity) {
        val manager = appUpdateManager ?: return
        try {
            manager.appUpdateInfo.addOnSuccessListener { info ->
                if (info.installStatus() == InstallStatus.DOWNLOADED) {
                    _isUpdateDownloaded.value = true
                } else if (info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS) {
                    try {
                        manager.startUpdateFlowForResult(
                            info,
                            activity,
                            AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE),
                            REQUEST_CODE_APP_UPDATE,
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to resume in-progress update flow", e)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error in onResume update check", e)
        }
    }

    fun openPlayStore(context: Context) {
        try {
            val playStoreIntent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse("market://details?id=${context.packageName}"),
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            context.startActivity(playStoreIntent)
        } catch (e: Exception) {
            try {
                val webIntent = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://play.google.com/store/apps/details?id=${context.packageName}"),
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(webIntent)
            } catch (e2: Exception) {
                Log.w(TAG, "Failed to open Play Store url", e2)
            }
        }
    }
}
