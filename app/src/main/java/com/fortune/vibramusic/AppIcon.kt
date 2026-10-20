package com.fortune.vibramusic

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import androidx.annotation.DrawableRes

/**
 * Launcher icon choices for Vibra Music.
 * Each corresponds to an <activity-alias> in AndroidManifest.xml.
 */
enum class AppIcon(
    val alias: String,
    @DrawableRes val iconRes: Int,
    val title: String,
) {
    Default("LauncherDefault", R.mipmap.ic_launcher, "Vibra Purple (Default)"),
    LiquidGlassDark("LauncherGlassDark", R.mipmap.ic_launcher_dark, "Dark Liquid Glass"),
    LiquidGlassLight("LauncherGlassLight", R.mipmap.ic_launcher_light, "Light Liquid Glass");

    private fun component(context: Context) =
        ComponentName(context.packageName, "com.fortune.vibramusic.$alias")

    companion object {
        fun current(context: Context): AppIcon {
            val pm = context.packageManager
            return entries.firstOrNull {
                pm.getComponentEnabledSetting(it.component(context)) ==
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } ?: Default
        }

        /**
         * Enables the chosen alias first and disables the rest with DONT_KILL_APP
         * so the launcher entry is reliably transitioned without losing the icon.
         */
        fun apply(context: Context, icon: AppIcon) {
            val pm = context.packageManager
            pm.setComponentEnabledSetting(
                icon.component(context),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            entries.filter { it != icon }.forEach {
                pm.setComponentEnabledSetting(
                    it.component(context),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }
}
