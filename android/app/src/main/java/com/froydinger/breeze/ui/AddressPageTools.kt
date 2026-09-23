package com.froydinger.breeze.ui

import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.content.pm.PackageManager
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon as ComposeIcon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.froydinger.breeze.BrowserState

/** Finger-friendly page actions menu for the address bar. */
@Composable
fun AddressPageTools(state: BrowserState, modifier: Modifier = Modifier) {
    var expanded by remember { mutableStateOf(false) }
    var confirmClearSite by remember { mutableStateOf(false) }
    var bookmarkRemovalUrl by remember { mutableStateOf<String?>(null) }
    var showHiddenItems by remember { mutableStateOf(false) }
    var privacyExpanded by remember { mutableStateOf(false) }
    var librarySettingsExpanded by remember { mutableStateOf(false) }
    val menuScrollState = rememberScrollState()
    val context = LocalContext.current
    androidx.compose.runtime.SideEffect { state.pageToolsOpen = expanded }
    androidx.compose.runtime.DisposableEffect(state) {
        onDispose { state.pageToolsOpen = false }
    }
    val page = state.selected
    val url = page?.url.orEmpty()
    val existingBookmark = state.bookmarks.firstOrNull { it.url == url }
    val validWebPage = runCatching {
        val uri = Uri.parse(url)
        uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()
    }.getOrDefault(false)
    val canCreateHomeShortcut = validWebPage && page?.private != true
    val associatedAppTargets = remember(url, context.packageName) { findAssociatedAppTargets(context, url) }
    val hiddenItems = state.hiddenPageElements(url)

    androidx.compose.foundation.layout.Box {
        IconButton(
            onClick = { expanded = true },
            modifier = modifier.size(48.dp).clip(RoundedCornerShape(15.dp)),
        ) {
            ComposeIcon(BreezeIcons.Tune, contentDescription = "Page tools", modifier = Modifier.size(22.dp))
        }
        val glassEnabled = LocalGlassEnabled.current
        val menuShape = RoundedCornerShape(22.dp)
        val menuBorder = BorderStroke(.7.dp, MaterialTheme.colorScheme.outline.copy(alpha = if (glassEnabled) .42f else .24f))
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            shape = menuShape,
            containerColor = MaterialTheme.colorScheme.surface.copy(alpha = if (glassEnabled) .94f else 1f),
            tonalElevation = 3.dp,
            shadowElevation = 12.dp,
            border = menuBorder,
        ) {
            val menuContentModifier = Modifier
                .widthIn(min = 292.dp, max = 340.dp)
                .heightIn(max = 560.dp)
                .then(if (privacyExpanded || librarySettingsExpanded) Modifier.verticalScroll(menuScrollState) else Modifier)
                .padding(vertical = 5.dp)
            Column(menuContentModifier) {
                PageZoomRow(
                    percent = page?.zoomPercent ?: 100,
                    enabled = validWebPage,
                    onDecrease = { state.adjustPageZoom(-10) },
                    onReset = { state.resetPageZoom() },
                    onIncrease = { state.adjustPageZoom(10) },
                )
                PageMenuSection("PAGE")
                PageAction("Find on page", BreezeIcons.Search) { expanded = false; state.showFind = true }
                PageAction("Desktop site", BreezeIcons.Computer) { expanded = false; state.toggleDesktop() }
                PageAction(if (existingBookmark != null) "Bookmarked" else "Bookmark page", if (existingBookmark != null) BreezeIcons.BookmarkFilled else BreezeIcons.Bookmark) {
                    expanded = false
                    if (existingBookmark != null) bookmarkRemovalUrl = existingBookmark.url else state.bookmark()
                }
                PageAction("Share link", BreezeIcons.Share) { expanded = false; state.share()?.let(context::startActivity) }

                PageMenuDivider()
                PrivacySectionHeader(expanded = privacyExpanded, onClick = { privacyExpanded = !privacyExpanded })
                if (privacyExpanded) {
                    PageAction(if (state.isSiteProtectionEnabled(url)) "Turn off ad and tracker blocking" else "Turn on ad and tracker blocking", BreezeIcons.Shield, enabled = validWebPage) {
                        expanded = false
                        state.setSiteProtectionEnabled(url, !state.isSiteProtectionEnabled(url))
                    }
                    PageAction("Hide a banner or page item", BreezeIcons.VisibilityOff, enabled = validWebPage) {
                        expanded = false
                        state.requestHidePageElement()
                    }
                    PageAction("Manage hidden items (${hiddenItems.size})", BreezeIcons.Visibility, enabled = validWebPage && hiddenItems.isNotEmpty()) {
                        expanded = false
                        showHiddenItems = true
                    }
                    PageAction("Clear site cookies and data", BreezeIcons.Delete, enabled = validWebPage) { expanded = false; confirmClearSite = true }
                }

                PageMenuDivider()
                LibrarySettingsSectionHeader(
                    expanded = librarySettingsExpanded,
                    onClick = { librarySettingsExpanded = !librarySettingsExpanded },
                )
                if (librarySettingsExpanded) {
                    PageAction("Bookmarks & library", BreezeIcons.Bookmark) { expanded = false; state.screen = "library" }
                    PageAction("History", BreezeIcons.History) { expanded = false; state.screen = "history" }
                    PageAction("Settings", BreezeIcons.Settings) { expanded = false; state.screen = "settings" }
                }

                PageMenuDivider()
                PageMenuSection("SHORTCUTS")
                if (associatedAppTargets.isNotEmpty()) {
                    PageAction("Open in app", BreezeIcons.OpenInNew) { expanded = false; openCurrentInApp(context, state) }
                }
                PageAction("Add to Home screen", BreezeIcons.Add, enabled = canCreateHomeShortcut) {
                    expanded = false
                    requestHomeShortcut(context, state)
                }

            }
        }
    }
    bookmarkRemovalUrl?.let { savedUrl ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { bookmarkRemovalUrl = null },
            title = { Text("Remove bookmark?") },
            text = { Text("Remove this page from your bookmarks?") },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { bookmarkRemovalUrl = null; state.removeBookmark(savedUrl) }) { Text("Remove") }
            },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { bookmarkRemovalUrl = null }) { Text("Cancel") } },
        )
    }
    if (confirmClearSite) {
        val host = Uri.parse(url).host.orEmpty()
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmClearSite = false },
            title = { Text("Clear data for $host?") },
            text = { Text("This removes cookies and saved site data for this host. You may be signed out.") },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { confirmClearSite = false; state.clearCurrentSiteData() }) { Text("Clear site data") } },
            dismissButton = { androidx.compose.material3.TextButton(onClick = { confirmClearSite = false }) { Text("Cancel") } },
        )
    }
    if (showHiddenItems) {
        val host = Uri.parse(url).host.orEmpty()
        AlertDialog(
            onDismissRequest = { showHiddenItems = false },
            title = { Text("Hidden items on $host") },
            text = {
                Column(Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
                    hiddenItems.forEachIndexed { index, selector ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Page item ${index + 1}", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                            IconButton(onClick = { state.removeHiddenPageElement(url, selector) }) {
                                ComposeIcon(BreezeIcons.Delete, contentDescription = "Show page item again")
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showHiddenItems = false }) { Text("Done") } },
        )
    }
}

@Composable
private fun PageZoomRow(
    percent: Int,
    enabled: Boolean,
    onDecrease: () -> Unit,
    onReset: () -> Unit,
    onIncrease: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().height(44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
    ) {
        IconButton(onClick = onDecrease, enabled = enabled && percent > 50, modifier = Modifier.size(40.dp)) {
            Text("−", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface)
        }
        androidx.compose.material3.TextButton(
            onClick = onReset,
            enabled = enabled,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 10.dp, vertical = 0.dp),
        ) {
            Text("${percent}%", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurface)
        }
        IconButton(onClick = onIncrease, enabled = enabled && percent < 200, modifier = Modifier.size(40.dp)) {
            Text("+", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
private fun PrivacySectionHeader(expanded: Boolean, onClick: () -> Unit) {
    CollapsibleMenuSectionHeader(label = "PRIVACY", expanded = expanded, onClick = onClick)
}

@Composable
private fun LibrarySettingsSectionHeader(expanded: Boolean, onClick: () -> Unit) {
    CollapsibleMenuSectionHeader(label = "LIBRARY & SETTINGS", expanded = expanded, onClick = onClick)
}

@Composable
private fun CollapsibleMenuSectionHeader(label: String, expanded: Boolean, onClick: () -> Unit) {
    val sectionName = if (label == "PRIVACY") "privacy" else "Library and settings"
    androidx.compose.material3.TextButton(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().padding(start = 2.dp, end = 8.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 8.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                label,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.1.sp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            ComposeIcon(
                imageVector = BreezeIcons.ExpandMore,
                contentDescription = if (expanded) "Collapse $sectionName" else "Expand $sectionName",
                modifier = Modifier.size(18.dp).then(if (expanded) Modifier.graphicsLayer { rotationZ = 180f } else Modifier),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun PageMenuSection(label: String) {
    Text(
        label,
        modifier = Modifier.fillMaxWidth().padding(start = 18.dp, end = 16.dp, top = 8.dp, bottom = 3.dp),
        style = MaterialTheme.typography.labelSmall.copy(letterSpacing = 1.1.sp),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun PageMenuDivider() {
    Spacer(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 5.dp).height(1.dp).clip(RoundedCornerShape(1.dp)).then(
        Modifier.background(MaterialTheme.colorScheme.outline.copy(alpha = .48f)),
    ))
}

@Composable
private fun PageAction(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean = true, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, style = MaterialTheme.typography.bodyLarge) },
        leadingIcon = { ComposeIcon(icon, contentDescription = null, modifier = Modifier.size(22.dp)) },
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.heightIn(min = 48.dp),
    )
}

private fun requestHomeShortcut(context: android.content.Context, state: BrowserState) {
    val page = state.selected ?: return
    if (page.private) {
        state.notice = "Private pages can’t be added to the Home screen."
        return
    }
    val uri = runCatching { Uri.parse(page.url) }.getOrNull()
    if (uri == null || uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
        state.notice = "Open a website before adding it to the Home screen."
        return
    }
    val manager = context.getSystemService(ShortcutManager::class.java)
    if (manager == null || !manager.isRequestPinShortcutSupported) {
        state.notice = "This launcher doesn’t support Home screen shortcuts."
        return
    }
    val title = page.title.ifBlank { uri.host.orEmpty() }.take(40)
    val intent = Intent(Intent.ACTION_VIEW, uri).apply {
        setClass(context, com.froydinger.breeze.MainActivity::class.java)
        addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
    val shortcut = ShortcutInfo.Builder(context, "breeze-page-${page.url.hashCode()}")
        .setShortLabel(title.take(25))
        .setLongLabel(title)
        .setIcon(Icon.createWithResource(context, com.froydinger.breeze.R.drawable.breeze_logo_flat))
        .setIntent(intent)
        .build()
    state.notice = if (manager.requestPinShortcut(shortcut, null)) "Home screen shortcut requested." else "Couldn’t request a Home screen shortcut."
}

private fun findAssociatedAppTargets(context: android.content.Context, url: String): List<Intent> {
    val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return emptyList()
    if (uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) return emptyList()
    val base = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
    return runCatching {
        context.packageManager.queryIntentActivities(base, PackageManager.MATCH_DEFAULT_ONLY)
            .filter { item ->
                val packageName = item.activityInfo?.packageName
                val filter = item.filter ?: return@filter false
                val matchCategory = item.match and android.content.IntentFilter.MATCH_CATEGORY_MASK
                val hasHostSpecificFilter = (0 until filter.countDataAuthorities()).any { index ->
                    val host = filter.getDataAuthority(index).host
                    host != "*" && filter.hasDataAuthority(uri)
                }
                packageName != null && packageName != context.packageName &&
                    matchCategory >= android.content.IntentFilter.MATCH_CATEGORY_HOST && hasHostSpecificFilter
            }
            .mapNotNull { item ->
                val packageName = item.activityInfo?.packageName ?: return@mapNotNull null
                val activityName = item.activityInfo?.name ?: return@mapNotNull null
                Intent(base).setClassName(packageName, activityName)
            }
            .distinctBy { it.component }
    }.getOrDefault(emptyList())
}

private fun openCurrentInApp(context: android.content.Context, state: BrowserState) {
    val targets = findAssociatedAppTargets(context, state.selected?.url.orEmpty())
    if (targets.isEmpty()) {
        state.notice = "No associated app is available for this link."
        return
    }
    runCatching {
        val chooser = Intent.createChooser(targets.first(), "Open this link with")
        if (targets.size > 1) chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, targets.drop(1).take(8).toTypedArray())
        context.startActivity(chooser)
    }.onFailure { state.notice = "Couldn’t open an installed app for this link." }
}
