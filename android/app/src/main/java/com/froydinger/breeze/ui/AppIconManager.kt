package com.froydinger.breeze.ui

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/** Keep the single Breeze launcher mark in sync with the app's light or dark theme. */
object AppIconManager {
    private const val DARK_ALIAS = "IconClassicDarkActivity"
    private const val LIGHT_ALIAS = "IconClassicLightActivity"

    fun applyTheme(context: Context, dark: Boolean): Boolean {
        val manager = context.packageManager
        val target = component(context, if (dark) DARK_ALIAS else LIGHT_ALIAS)
        val other = component(context, if (dark) LIGHT_ALIAS else DARK_ALIAS)
        return try {
            manager.setComponentEnabledSetting(target, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
            manager.setComponentEnabledSetting(other, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun component(context: Context, alias: String) =
        ComponentName(context.packageName, "${context.packageName}.$alias")
}
