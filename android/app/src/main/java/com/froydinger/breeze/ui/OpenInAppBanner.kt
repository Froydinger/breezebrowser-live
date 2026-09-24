package com.froydinger.breeze.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private data class NativeAppDestination(val name: String, val component: ComponentName)

/** Offer only installed handlers for this exact web URL, excluding general-purpose browsers. */
@Suppress("DEPRECATION")
private fun nativeAppFor(context: Context, uri: Uri): NativeAppDestination? {
    val manager = context.packageManager
    val flags = PackageManager.MATCH_DEFAULT_ONLY
    fun link(target: Uri) = Intent(Intent.ACTION_VIEW, target).addCategory(Intent.CATEGORY_BROWSABLE)
    val browsers = manager.queryIntentActivities(link(Uri.parse("https://example.com/")), flags)
        .map { it.activityInfo.packageName }.toSet()
    return manager.queryIntentActivities(link(uri), flags).asSequence()
        .filter { it.activityInfo.exported && it.activityInfo.enabled }
        .filter { it.activityInfo.packageName != context.packageName && it.activityInfo.packageName !in browsers }
        .sortedByDescending { it.priority }
        .firstOrNull()?.let { NativeAppDestination(it.loadLabel(manager).toString(), ComponentName(it.activityInfo.packageName, it.activityInfo.name)) }
}

/** External web links that reach Breeze may continue to a matching installed app. */
fun openExternalLinkInApp(context: Context, uri: Uri): Boolean {
    if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) return false
    val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        .addFlags(Intent.FLAG_ACTIVITY_REQUIRE_NON_BROWSER)
    return runCatching { context.startActivity(intent); true }.getOrDefault(false)
}

@Composable
fun OpenInAppBanner(url: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val uri = remember(url) { runCatching { Uri.parse(url) }.getOrNull() }
    val host = uri?.host?.lowercase() ?: return
    if (uri.scheme !in listOf("https", "http")) return
    val dismissedHosts = remember { mutableStateListOf<String>() }
    var destination by remember(url) { mutableStateOf<NativeAppDestination?>(null) }
    LaunchedEffect(url) {
        destination = withContext(Dispatchers.IO) { runCatching { nativeAppFor(context, uri) }.getOrNull() }
    }
    val app = destination ?: return
    if (host in dismissedHosts) return
    Surface(modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), tonalElevation = 4.dp, shadowElevation = 3.dp) {
        Row(Modifier.padding(start = 14.dp, top = 4.dp, bottom = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Open in ${app.name}", style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(host.removePrefix("www."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            TextButton(onClick = {
                val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE).setComponent(app.component)
                runCatching { context.startActivity(intent) }.onFailure { dismissedHosts.add(host) }
            }) { Text("Open") }
            IconButton(onClick = { dismissedHosts.add(host) }) { Icon(BreezeIcons.Close, contentDescription = "Dismiss open in app") }
        }
    }
}
