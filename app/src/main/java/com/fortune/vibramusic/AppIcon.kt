package com.fortune.vibramusic

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * The home-screen icon choices. Each is an `<activity-alias>` in the manifest
 * carrying the launcher intent filter; exactly one is enabled at a time.
 *
 * Every glass icon draws the same Vibra logo as [Default]: its adaptive icon layers a
 * glass tile (`ic_*_tile`) under `ic_glass_logo_*`, which has the outline of
 * `ic_launcher_foreground`. [previewRes] images are only used as static previews.
 */
enum class AppIcon(val alias: String, val iconRes: Int, val labelRes: Int, val previewRes: Int? = null) {
    Default("LauncherDefault", R.mipmap.ic_launcher, R.string.app_icon_default),
    LiquidGlass("LauncherGlassLight", R.mipmap.ic_liquid_glass, R.string.app_icon_liquid_glass, R.mipmap.ic_liquid_glass_foreground),
    LiquidGlassDark("LauncherGlassDark", R.mipmap.ic_liquid_glass_dark, R.string.app_icon_liquid_glass_dark, R.mipmap.ic_liquid_glass_dark_foreground),
    LiquidGlassClear("LauncherGlassClear", R.mipmap.ic_liquid_glass_clear, R.string.app_icon_liquid_glass_clear, R.mipmap.ic_liquid_glass_clear_foreground),
    LiquidGlassClearDark("LauncherGlassClearDark", R.mipmap.ic_liquid_glass_clear_dark, R.string.app_icon_liquid_glass_clear_dark, R.mipmap.ic_liquid_glass_clear_dark_foreground),
    SamsungGlass("LauncherSamsungGlass", R.mipmap.ic_samsung_glass, R.string.app_icon_samsung_glass, R.mipmap.ic_samsung_glass_foreground),
    SamsungGlassDark("LauncherSamsungGlassDark", R.mipmap.ic_samsung_glass_dark, R.string.app_icon_samsung_glass_dark, R.mipmap.ic_samsung_glass_dark_foreground),
    SamsungGlassClear("LauncherSamsungGlassClear", R.mipmap.ic_samsung_glass_clear, R.string.app_icon_samsung_glass_clear, R.mipmap.ic_samsung_glass_clear_foreground),
    SamsungGlassClearDark("LauncherSamsungGlassClearDark", R.mipmap.ic_samsung_glass_clear_dark, R.string.app_icon_samsung_glass_clear_dark, R.mipmap.ic_samsung_glass_clear_dark_foreground),
    PixelGlass("LauncherPixelGlass", R.mipmap.ic_pixel_glass, R.string.app_icon_pixel_glass, R.mipmap.ic_pixel_glass_foreground),
    PixelGlassDark("LauncherPixelGlassDark", R.mipmap.ic_pixel_glass_dark, R.string.app_icon_pixel_glass_dark, R.mipmap.ic_pixel_glass_dark_foreground),
    PixelGlassClear("LauncherPixelGlassClear", R.mipmap.ic_pixel_glass_clear, R.string.app_icon_pixel_glass_clear, R.mipmap.ic_pixel_glass_clear_foreground),
    PixelGlassClearDark("LauncherPixelGlassClearDark", R.mipmap.ic_pixel_glass_clear_dark, R.string.app_icon_pixel_glass_clear_dark, R.mipmap.ic_pixel_glass_clear_dark_foreground);

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
         * Enables [icon] before disabling the rest so there is never a moment with no launcher entry.
         * Each call is guarded: one missing/unsupported alias must never crash the app.
         */
        fun apply(context: Context, icon: AppIcon) {
            val pm = context.packageManager
            runCatching {
                pm.setComponentEnabledSetting(
                    icon.component(context),
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }.onFailure { return }
            entries.filter { it != icon }.forEach {
                runCatching {
                    pm.setComponentEnabledSetting(
                        it.component(context),
                        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        PackageManager.DONT_KILL_APP,
                    )
                }
            }
        }
    }
}
