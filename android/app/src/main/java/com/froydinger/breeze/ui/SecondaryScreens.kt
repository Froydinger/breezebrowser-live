package com.froydinger.breeze.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.Image
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Surface
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.froydinger.breeze.BrowserState
import com.froydinger.breeze.LocalChat
import com.froydinger.breeze.SavedPage
import com.froydinger.breeze.core.HomeInputMode
import com.froydinger.breeze.core.SearchEngine
import com.froydinger.breeze.core.ThemeMode
import com.froydinger.breeze.data.BrowserImport

/** A short, alpha-only screen entrance keeps navigation calm without moving layout. */
@Composable
internal fun screenEntrance(): Modifier {
    val alpha = remember { Animatable(0f) }
    LaunchedEffect(Unit) { alpha.animateTo(1f, animationSpec = tween(durationMillis = 180)) }
    return Modifier.graphicsLayer { this.alpha = alpha.value }
}

@Composable
fun LibraryScreen(state: BrowserState, initialFilter: String = state.historyInitialFilter) {
    val isHistory = state.screen == "history"
    val isChats = state.screen == "chats"
    val title = when { isHistory -> "History"; isChats -> "Recent chats"; else -> "Library" }
    val filters = when { isHistory -> listOf("All", "Web", "Chats"); isChats -> listOf("Chats"); else -> listOf("All", "Bookmarks", "Web", "Chats") }
    var filter by remember(state.screen, initialFilter) {
        mutableStateOf(initialFilter.takeIf { it in filters } ?: if (isHistory || !isChats) "All" else "Chats")
    }
    var query by remember(state.screen) { mutableStateOf("") }
    var searchOpen by remember(state.screen) { mutableStateOf(isChats) }
    val q = query.trim()
    val bookmarkMatches = state.bookmarks.filter { q.isEmpty() || it.title.contains(q, true) || it.url.contains(q, true) }
    val historyMatches = state.history.filter { q.isEmpty() || it.title.contains(q, true) || it.url.contains(q, true) }
    val chatMatches = state.chats.filter { chat ->
        q.isEmpty() || chat.title.contains(q, true) || chat.messages.any { it.second.contains(q, true) } ||
            chat.sources.any { it.first.contains(q, true) || it.second.contains(q, true) }
    }
    val mergedHistory = (historyMatches.map { HistoryFeedItem(it.time, "web-${it.id}", page = it) } +
        chatMatches.map { HistoryFeedItem(it.time, "chat-${it.id}", chat = it) })
        .sortedByDescending { it.time }
    val historySections = historyMatches.groupBy { historyDateGroup(it.time) }
    val dark = MaterialTheme.colorScheme.background.luminance() < .4f
    val line = if (dark) Color(0xFF383A3F) else Color(0xFFD7D9DD)
    val ink = MaterialTheme.colorScheme.onSurface
    val muted = MaterialTheme.colorScheme.onSurfaceVariant

    Column(Modifier.fillMaxSize().then(screenEntrance())) {
        Row(Modifier.fillMaxWidth().height(60.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { state.screen = "browser" }) { Icon(BreezeIcons.ArrowBack, "Back") }
            Text(title, Modifier.weight(1f).padding(start = 8.dp), style = MaterialTheme.typography.headlineSmall, color = ink)
            IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) query = "" }) {
                Icon(BreezeIcons.Search, if (searchOpen) "Close search" else "Search")
            }
            if (isHistory) {
                var more by remember { mutableStateOf(false) }
                var confirmClear by remember { mutableStateOf(false) }
                Box {
                    IconButton(onClick = { more = true }) { Icon(BreezeIcons.MoreVert, "History options") }
                    DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                        DropdownMenuItem(
                            text = { Text("Clear history") },
                            leadingIcon = { Icon(BreezeIcons.Delete, null) },
                            onClick = { more = false; confirmClear = true },
                        )
                    }
                }
                if (confirmClear) AlertDialog(
                    onDismissRequest = { confirmClear = false }, title = { Text("Clear web history?") },
                    text = { Text("All saved web visits on this device will be removed. Bookmarks and chats will stay.") },
                    confirmButton = { TextButton(onClick = { confirmClear = false; state.history.clear(); state.persist() }) { Text("Clear history") } },
                    dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
                )
            }
        }
        if (searchOpen) LibrarySearchBar(query = query, onQuery = { query = it })
        if (!isChats) {
            if (isHistory) {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    LibrarySegments(filters, filter, onSelect = { filter = it }, modifier = Modifier.weight(1f))
                    if (state.history.isNotEmpty()) {
                        Spacer(Modifier.width(10.dp))
                        LibraryClearHistoryAction { state.history.clear(); state.persist() }
                    }
                }
            } else {
                LibrarySegments(filters, filter, onSelect = { filter = it }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }

        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 120.dp),
            verticalArrangement = Arrangement.spacedBy(if (isChats) 0.dp else 10.dp),
        ) {
            val showHistory = (isHistory && filter != "Chats") || filter == "Web" || (filter == "All" && !isChats && !isHistory)
            val showBookmarks = !isHistory && !isChats && (filter == "Bookmarks" || filter == "All")
            val showChats = isChats || filter == "Chats" || (filter == "All" && !isHistory)

            if (showHistory) {
                if (isHistory && filter == "All") {
                    if (mergedHistory.isEmpty()) item(key = "history-all-empty") { LibraryEmpty("No recent history yet.") }
                    else mergedHistory.groupBy { historyDateGroup(it.time) }.forEach { (dateGroup, entries) ->
                        item(key = "history-all-heading-$dateGroup") { LibraryDateHeading(dateGroup) }
                        items(entries, key = { "history-all-${it.key}" }) { entry ->
                            entry.page?.let { page ->
                                HistoryPageRow(page, dark, line, ink, muted,
                                    onOpen = { state.navigate(page.url, new = true) },
                                    onDelete = { state.history.remove(page); state.persist() })
                            }
                            entry.chat?.let { chat ->
                                HistoryChatRow(chat, muted, line,
                                    onOpen = { state.openChat(chat) },
                                    onDelete = { removeChat(state, chat) })
                            }
                        }
                    }
                } else if (historyMatches.isNotEmpty()) {
                    historySections.forEach { (dateGroup, pages) ->
                        item(key = "web-history-heading-$dateGroup") { LibraryDateHeading(dateGroup) }
                        items(pages, key = { "history-${it.id}" }) { page ->
                            HistoryPageRow(page, dark, line, ink, muted, onOpen = { state.navigate(page.url, new = true) },
                                onDelete = { state.history.remove(page); state.persist() })
                        }
                    }
                } else if (filter == "Web") {
                    item(key = "history-empty") { LibraryEmpty("No saved web visits yet.") }
                }
            }

            if (showBookmarks) {
                item(key = "bookmarks-heading") { LibraryDateHeading("Bookmarks") }
                if (bookmarkMatches.isEmpty()) item(key = "bookmarks-empty") { LibraryEmpty(if (q.isEmpty()) "Pages you save will appear here." else "No matching bookmarks.") }
                else items(bookmarkMatches, key = { "bookmark-${it.id}" }) { page ->
                    HistoryPageRow(page, dark, line, ink, muted, isBookmark = true,
                        onOpen = { state.navigate(page.url, new = true) },
                        onDelete = { state.bookmarks.remove(page); state.persist() },
                        onEdit = { updated ->
                            val index = state.bookmarks.indexOfFirst { it.id == updated.id }
                            if (index >= 0) { state.bookmarks[index] = updated; state.persist() }
                        })
                }
            }

            if (showChats && !isHistory) {
                if (!isChats) item(key = "chats-heading") { LibraryDateHeading("Recent chats") }
                if (chatMatches.isEmpty()) item(key = "chats-empty") { LibraryEmpty(if (q.isBlank()) "Saved conversations will appear here." else "No matching chats.") }
                else items(chatMatches, key = { "chat-${it.id}" }) { chat ->
                    RecentChatRow(chat, muted, line, onOpen = { state.openChat(chat) }, onDelete = { removeChat(state, chat) })
                }
            }
            if (isHistory && filter == "Chats") {
                if (chatMatches.isEmpty()) item(key = "history-chats-empty") { LibraryEmpty("No saved chats yet.") }
                else items(chatMatches, key = { "history-chat-${it.id}" }) { chat ->
                    HistoryChatRow(chat, muted, line, onOpen = { state.openChat(chat) }, onDelete = { removeChat(state, chat) })
                }
            }
        }

        if (isChats) {
            Surface(
                modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 18.dp, end = 18.dp, top = 12.dp, bottom = 84.dp).height(54.dp).clickable { state.startChat() },
                shape = RoundedCornerShape(50), color = Color.Transparent, border = androidx.compose.foundation.BorderStroke(1.dp, line),
            ) {
                Row(horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Icon(BreezeIcons.Add, null, tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(10.dp)); Text("New chat", color = ink)
                }
            }
        }
    }
}

@Composable
private fun LibrarySegments(options: List<String>, selected: String, modifier: Modifier = Modifier, onSelect: (String) -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier.clip(RoundedCornerShape(50)).border(1.dp, muted.copy(alpha=.22f), RoundedCornerShape(50)).background(MaterialTheme.colorScheme.surface.copy(alpha=.45f)), horizontalArrangement = Arrangement.spacedBy(0.dp)) {
        options.forEach { option ->
            Column(Modifier.weight(1f).clickable { onSelect(option) }.padding(top = 7.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(option, color = if (selected == option) MaterialTheme.colorScheme.onSurface else muted,
                    style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(8.dp))
                Box(Modifier.fillMaxWidth().height(2.dp).background(if (selected == option) accent else Color.Transparent))
            }
        }
    }
}

@Composable
private fun LibraryDateHeading(label: String) {
    Text(label, Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 4.dp), color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.titleMedium)
}

private fun historyDateGroup(time: Long): String {
    val now = java.util.Calendar.getInstance()
    val visit = java.util.Calendar.getInstance().apply { timeInMillis = time }
    val today = now.get(java.util.Calendar.YEAR) == visit.get(java.util.Calendar.YEAR) && now.get(java.util.Calendar.DAY_OF_YEAR) == visit.get(java.util.Calendar.DAY_OF_YEAR)
    if (today) return "Today"
    now.add(java.util.Calendar.DAY_OF_YEAR, -1)
    val yesterday = now.get(java.util.Calendar.YEAR) == visit.get(java.util.Calendar.YEAR) && now.get(java.util.Calendar.DAY_OF_YEAR) == visit.get(java.util.Calendar.DAY_OF_YEAR)
    return if (yesterday) "Yesterday" else "Earlier"
}

private data class HistoryFeedItem(
    val time: Long,
    val key: String,
    val page: SavedPage? = null,
    val chat: LocalChat? = null,
)

@Composable
private fun HistoryPageRow(
    page: SavedPage, dark: Boolean, line: Color, ink: Color, muted: Color,
    isBookmark: Boolean = false, onOpen: () -> Unit, onDelete: () -> Unit, onEdit: ((SavedPage) -> Unit)? = null,
) {
    var menu by remember { mutableStateOf(false) }
    var confirmDelete by remember(page.id) { mutableStateOf(false) }
    val surface = if (dark) Color.Black else Color(0xFFFAFAF9)
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(surface).border(1.dp, line, shape).clickable(onClick = onOpen).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(Modifier.size(54.dp), shape = RoundedCornerShape(13.dp), color = if (dark) Color.Black else Color.White, border = androidx.compose.foundation.BorderStroke(1.dp, line)) {
            Box(contentAlignment = Alignment.Center) {
                Icon(if (isBookmark) BreezeIcons.Bookmark else BreezeIcons.Language, null, tint = if (isBookmark) MaterialTheme.colorScheme.primary else muted, modifier = Modifier.size(26.dp))
            }
        }
        Column(Modifier.weight(1f).padding(start = 12.dp, end = 6.dp)) {
            Text(page.title.ifBlank { page.url }, color = ink, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(runCatching { java.net.URI(page.url).host }.getOrNull() ?: page.url, color = muted, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (!isBookmark) Text(
            java.text.SimpleDateFormat(if (historyDateGroup(page.time) == "Today") "h:mm a" else "MMM d", java.util.Locale.getDefault()).format(java.util.Date(page.time)),
            color = muted, style = MaterialTheme.typography.bodySmall, maxLines = 1,
        )
        Box {
            IconButton(onClick = { menu = true }) { Icon(BreezeIcons.MoreVert, "Options for ${page.title}", tint = muted) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (onEdit != null) DropdownMenuItem(text = { Text("Edit bookmark") }, onClick = { menu = false; onEdit(page) })
                DropdownMenuItem(text = { Text("Delete") }, leadingIcon = { Icon(BreezeIcons.Delete, null) }, onClick = { menu = false; confirmDelete = true })
            }
        }
    }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false }, title = { Text(if (isBookmark) "Delete bookmark?" else "Delete visit?") },
        text = { Text("This item will be removed from this device.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

@Composable
private fun HistoryChatRow(chat: LocalChat, muted: Color, line: Color, onOpen: () -> Unit, onDelete: () -> Unit) {
    RecentChatRow(chat, muted, line, onOpen, onDelete, historyStyle = true)
}

@Composable
private fun RecentChatRow(chat: LocalChat, muted: Color, line: Color, onOpen: () -> Unit, onDelete: () -> Unit, historyStyle: Boolean = false) {
    val preview = chat.messages.lastOrNull { it.first == "assistant" || it.first == "user" }?.second.orEmpty()
    var menu by remember(chat.id) { mutableStateOf(false) }
    var confirmDelete by remember(chat.id) { mutableStateOf(false) }
    val rowShape = RoundedCornerShape(18.dp)
    val rowSurface = if (MaterialTheme.colorScheme.background.luminance() < .4f) Color.Black else Color(0xFFFAFAF9)
    Row(Modifier.fillMaxWidth().then(if (historyStyle) Modifier.clip(rowShape).background(rowSurface).border(1.dp,line,rowShape) else Modifier).clickable(onClick = onOpen).then(if (historyStyle) Modifier.padding(10.dp) else Modifier.padding(vertical=15.dp)), verticalAlignment = Alignment.CenterVertically) {
        Surface(Modifier.size(if (historyStyle) 54.dp else 50.dp), shape = RoundedCornerShape(14.dp), color = if (MaterialTheme.colorScheme.background.luminance() < .4f) Color.Black else Color(0xFFFAFAFA), border = androidx.compose.foundation.BorderStroke(1.dp, line)) {
            Box(contentAlignment = Alignment.Center) { Icon(BreezeIcons.ChatBubbleOutline, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(24.dp)) }
        }
        Column(Modifier.weight(1f).padding(start = 14.dp, end = 8.dp)) {
            Text(chat.title, color = MaterialTheme.colorScheme.onSurface, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (historyStyle) "Breeze chat" else preview.ifBlank { "Conversation saved on this device" }, color = muted, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (historyStyle) Text(java.text.SimpleDateFormat(if (historyDateGroup(chat.time) == "Earlier") "MMM d" else "h:mm a", java.util.Locale.getDefault()).format(java.util.Date(chat.time)), color=muted, style=MaterialTheme.typography.bodySmall, maxLines=1)
        Box {
            IconButton(onClick = { menu = true }) { Icon(BreezeIcons.MoreVert, "Options for ${chat.title}", tint = muted) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Delete chat") }, leadingIcon = { Icon(BreezeIcons.Delete, null) }, onClick = { menu = false; confirmDelete = true })
            }
        }
    }
    if (!historyStyle) androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(1.dp)) { drawLine(line, androidx.compose.ui.geometry.Offset(0f, 0f), androidx.compose.ui.geometry.Offset(size.width, 0f), 1.dp.toPx()) }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false }, title = { Text("Delete chat?") },
        text = { Text("This conversation will be removed from this device.") },
        confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}

private fun removeChat(state: BrowserState, chat: LocalChat) {
    chat.job?.cancel()
    state.chats.remove(chat)
    if (state.activeChat?.id == chat.id) {
        state.activeChat = null
        if (state.screen == "chat") state.screen = "browser"
    }
    state.persist()
}

@Composable
private fun LibraryEmpty(text: String) {
    GlassCard(Modifier.fillMaxWidth()) { Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

@Composable
fun SettingsScreen(state: BrowserState) {
    var backgroundPicker by remember { mutableStateOf(false) }
    if (backgroundPicker) BackgroundPickerScreen(state, onBack = { backgroundPicker = false })
    else SettingsContent(state, onBack = { state.screen = "browser" }, onChooseBackground = { backgroundPicker = true })
}

@Composable
private fun SettingsContent(state: BrowserState, onBack: () -> Unit, onChooseBackground: () -> Unit) {
    val context = LocalContext.current
    var importMessage by remember { mutableStateOf<String?>(null) }
    val bookmarkImporter = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            runCatching {
                val text = readBookmarkImportText(context, uri)
                BrowserImport.bookmarksHtml(text)
            }.onSuccess { imported ->
                val existing = state.bookmarks.mapTo(mutableSetOf()) { it.url }
                val additions = imported.filter { existing.add(it.url) }
                state.bookmarks.addAll(0, additions)
                state.persist()
                importMessage = "Imported ${additions.size} bookmarks."
            }.onFailure { importMessage = it.message ?: "Bookmarks could not be imported." }
        }
    }
    Column(Modifier.fillMaxSize().then(screenEntrance())) {
        SettingsHeader("Settings", onBack)
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { SettingSectionTitle("Appearance") }
            item { ThemeSettingsCard(state) }
            item { SettingSectionTitle("Search") }
            item { SearchSettingsCard(state) }
            item { SettingSectionTitle("New tab") }
            item { BackgroundSettingsCard(state, onChooseBackground) }
            item { SettingSectionTitle("Your stuff") }
            item { PersonalSettingsCard(state) }
            item { SettingsActionCard(BreezeIcons.Bookmark, "Import bookmarks", "Choose a browser bookmarks HTML export", "Import", line = MaterialTheme.colorScheme.outline) { bookmarkImporter.launch(arrayOf("text/html", "text/plain", "application/octet-stream")) } }
            if (importMessage != null) item { Text(importMessage!!, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            item { SettingSectionTitle("Privacy & security") }
            item { PrivacySettingsCard(state) }
            item { SettingSectionTitle("General") }
            item { GeneralSettingsCard(state) }
            item { SettingSectionTitle("Passwords") }
            item { SettingsActionCard(BreezeIcons.Lock, "Password vault", "Encrypted on this device", "Open", line = MaterialTheme.colorScheme.outline) { state.screen = "passwords" } }
            item { SettingSectionTitle("Cloud sync") }
            item { CloudSyncCard() }
            item { SettingSectionTitle("More home options") }
            item { HomeOptionsCard(state) }
        }
    }
}

private fun readBookmarkImportText(context: android.content.Context, uri: android.net.Uri): String {
    val limit = 8 * 1024 * 1024
    val input = context.contentResolver.openInputStream(uri) ?: error("File could not be opened.")
    val output = java.io.ByteArrayOutputStream()
    input.use { stream ->
        val buffer = ByteArray(8192)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit) { "File is too large to import." }
            output.write(buffer, 0, count)
        }
    }
    require(output.size() > 0) { "File is empty." }
    return output.toString(Charsets.UTF_8.name())
}

@Composable
private fun PersonalSettingsCard(state: BrowserState) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp))) {
        SettingsActionRow(BreezeIcons.Notifications, "Reminders", "Scheduled on this phone", null, MaterialTheme.colorScheme.outline) { state.screen = "reminders" }
        SettingsDivider()
        SettingsActionRow(BreezeIcons.Download, "Downloads", "", null, MaterialTheme.colorScheme.outline) { state.screen = "downloads" }
        SettingsDivider()
        SettingsActionRow(BreezeIcons.Bookmark, "Bookmarks", "", null, MaterialTheme.colorScheme.outline) {
            state.historyInitialFilter = "Bookmarks"
            state.screen = "library"
        }
    }
}

@Composable
private fun SettingsHeader(title: String, onBack: () -> Unit, trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().height(62.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(BreezeIcons.ArrowBack, "Back") }
        Text(title, Modifier.weight(1f).padding(start = 8.dp), style = MaterialTheme.typography.headlineSmall)
        trailing?.invoke()
    }
}

@Composable
private fun SettingSectionTitle(text: String) {
    Text(text, Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 1.dp), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
}

@Composable
private fun ThemeSettingsCard(state: BrowserState) {
    val line = MaterialTheme.colorScheme.outline
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, line, RoundedCornerShape(17.dp)).padding(12.dp)) {
        val selectorShape = RoundedCornerShape(15.dp)
        Row(
            Modifier.fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .18f), selectorShape)
                .border(1.dp, line, selectorShape)
                // Inset each segment slightly so its selected outline and glow remain visible.
                .padding(2.dp),
        ) {
            ThemeOption("System", BreezeIcons.Settings, state.theme == ThemeMode.SYSTEM, Modifier.weight(1f)) { state.theme = ThemeMode.SYSTEM; state.persist() }
            ThemeOption("Light", BreezeIcons.LightMode, state.theme == ThemeMode.LIGHT, Modifier.weight(1f)) { state.theme = ThemeMode.LIGHT; state.persist() }
            ThemeOption("Dark", BreezeIcons.DarkMode, state.theme == ThemeMode.DARK, Modifier.weight(1f)) { state.theme = ThemeMode.DARK; state.persist() }
        }
        Text(when (state.theme) {
            ThemeMode.SYSTEM -> "Follows your device setting"
            ThemeMode.LIGHT -> "Light appearance"
            ThemeMode.DARK -> "Dark appearance"
        }, Modifier.padding(start = 2.dp, top = 10.dp, bottom = 8.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ThemeOption(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
    val shape = RoundedCornerShape(12.dp)
    Column(modifier
        .shadow(
            elevation = if (selected) 5.dp else 0.dp,
            shape = shape,
            clip = false,
            ambientColor = MaterialTheme.colorScheme.primary.copy(alpha = if (selected) .24f else 0f),
            spotColor = MaterialTheme.colorScheme.primary.copy(alpha = if (selected) .2f else 0f),
        )
        .clip(shape)
        .background(if (selected) MaterialTheme.colorScheme.primary.copy(alpha = .12f) else Color.Transparent)
        .border(if (selected) 1.dp else 0.dp, if (selected) MaterialTheme.colorScheme.primary else Color.Transparent, shape)
        .clickable(onClick = onClick).padding(vertical = 11.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(25.dp))
        Spacer(Modifier.height(5.dp))
        Text(label, color = tint, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun SearchSettingsCard(state: BrowserState) {
    var engineMenu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp))) {
        Box {
            SettingsActionRow(BreezeIcons.Search, "Search engine", "Change default search", state.engine.displayName, MaterialTheme.colorScheme.outline) { engineMenu = true }
            DropdownMenu(expanded = engineMenu, onDismissRequest = { engineMenu = false }) {
                SearchEngine.entries.forEach { engine ->
                    DropdownMenuItem(text = { Text(engine.displayName) }, leadingIcon = { if (state.engine == engine) Icon(BreezeIcons.Check, null) }, onClick = {
                        state.engine = engine; state.persist(); engineMenu = false
                    })
                }
            }
        }
    }
}

@Composable
private fun BackgroundSettingsCard(state: BrowserState, onChoose: () -> Unit) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .4f
    val resource = LocalContext.current.resources.getIdentifier(state.wallpaper + if (dark) "_dark" else "_light", "drawable", LocalContext.current.packageName)
    Row(Modifier.fillMaxWidth().height(92.dp).clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface)
        .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp)).clickable(onClick = onChoose).padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
        if (resource != 0) Image(painterResource(resource), "Current home background", Modifier.width(112.dp).fillMaxHeight().clip(RoundedCornerShape(12.dp)), contentScale = ContentScale.Crop)
        Column(Modifier.weight(1f).padding(start = 13.dp)) {
            Text("Home background", style = MaterialTheme.typography.bodyLarge)
            Text(BACKGROUNDS.firstOrNull { it.first == state.wallpaper }?.second ?: "Teal Facets", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text("Choose", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Icon(BreezeIcons.ChevronRight, null, modifier = Modifier.size(23.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun BackgroundPickerScreen(state: BrowserState, onBack: () -> Unit) {
    val dark = MaterialTheme.colorScheme.background.luminance() < .4f
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().then(screenEntrance())) {
        SettingsHeader("Home background", onBack, trailing = { TextButton(onClick = onBack) { Text("Done") } })
        Text("Choose a look for your new tab page", Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 14.dp), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        LazyVerticalGrid(
            columns = GridCells.Fixed(2), modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 120.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            items(BACKGROUNDS, key = { it.first }) { (id, label) ->
                val resource = remember(id, dark) { context.resources.getIdentifier(id + if (dark) "_dark" else "_light", "drawable", context.packageName) }
                Column(Modifier.clickable {
                    state.wallpaper = id; state.persist()
                }) {
                    Box {
                        if (resource != 0) Image(painterResource(resource), label, Modifier.fillMaxWidth().aspectRatio(.82f).clip(RoundedCornerShape(17.dp))
                            .border(if (state.wallpaper == id) 2.dp else 1.dp, if (state.wallpaper == id) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp)), contentScale = ContentScale.Crop)
                        if (state.wallpaper == id) Surface(Modifier.align(Alignment.TopEnd).padding(10.dp).size(32.dp), shape = CircleShape, color = MaterialTheme.colorScheme.primary) {
                            Box(contentAlignment = Alignment.Center) { Icon(BreezeIcons.Check, null, tint = Color.White, modifier = Modifier.size(20.dp)) }
                        }
                    }
                    Text(label, Modifier.padding(start = 5.dp, top = 8.dp), style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
        Text("Text and controls stay readable in every theme.", Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 16.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun PrivacySettingsCard(state: BrowserState) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp))) {
        SettingsToggleRow(BreezeIcons.Shield, "Known ad and tracker blocking", "Blocks known ad and tracker requests", state.trackingProtection, onChange = { state.updateProtection(it) })
        SettingsDivider()
        SettingsToggleRow(BreezeIcons.Lock, "Third-party tracking cookies", "Reject cookies from known trackers", state.cookieProtection, onChange = { state.updateCookieProtection(it) })
        SettingsDivider()
        SettingsToggleRow(BreezeIcons.Lock, "Block all cookies", "May sign you out or break site features", state.blockAllCookies, onChange = { state.updateBlockAllCookies(it) })
        SettingsDivider()
        SettingsToggleRow(BreezeIcons.AutoAwesome, "Nav cloud access", "Prompts and selected context go to Breeze Cloud and OpenAI", state.cloudDisclosureAccepted, onChange = { if (it) state.requestCloudDisclosure() else state.revokeCloudDisclosure() })
        SettingsDivider()
        SettingsToggleRow(BreezeIcons.Lock, "HTTPS upgrades", "", state.httpsOnly, onChange = { state.updateHttpsOnly(it) })
    }
}

@Composable
private fun GeneralSettingsCard(state: BrowserState) {
    var confirmClear by remember { mutableStateOf(false) }
    var showAbout by remember { mutableStateOf(false) }
    var clearHistory by remember { mutableStateOf(true) }
    var clearCache by remember { mutableStateOf(true) }
    var clearSiteData by remember { mutableStateOf(true) }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp))) {
        SettingsActionRow(BreezeIcons.Delete, "Clear browsing data", "History, cookies, and cache", null, MaterialTheme.colorScheme.outline) { confirmClear = true }
        SettingsDivider()
        SettingsActionRow(BreezeIcons.Info, "About Breeze", "App version and information", null, MaterialTheme.colorScheme.outline) { showAbout = true }
    }
    if (confirmClear) AlertDialog(
        onDismissRequest = { confirmClear = false }, title = { Text("Clear browsing data?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Choose what to clear. Bookmarks, saved passwords, and chats will stay.")
                val allSelected = clearHistory && clearCache && clearSiteData
                val someSelected = clearHistory || clearCache || clearSiteData
                Row(
                    Modifier.fillMaxWidth().clickable {
                        val next = !allSelected
                        clearHistory = next; clearCache = next; clearSiteData = next
                    }.padding(vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(checked = allSelected, onCheckedChange = null,
                        modifier = Modifier.padding(end = 8.dp),
                        )
                    Text("All three", style = MaterialTheme.typography.titleSmall)
                }
                androidx.compose.material3.HorizontalDivider()
                listOf(
                    "Browsing history" to clearHistory,
                    "Cache" to clearCache,
                    "Cookies & site data" to clearSiteData,
                ).forEach { (label, checked) ->
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            when (label) {
                                "Browsing history" -> clearHistory = !clearHistory
                                "Cache" -> clearCache = !clearCache
                                else -> clearSiteData = !clearSiteData
                            }
                        }.padding(vertical = 1.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(
                            checked = checked,
                            onCheckedChange = null,
                            modifier = Modifier.padding(end = 8.dp),
                        )
                        Text(label)
                    }
                }
                if (someSelected && !allSelected) Text("Select All three to check every option.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = { confirmClear = false; state.clearBrowsingData(clearHistory, clearCache, clearSiteData) }, enabled = clearHistory || clearCache || clearSiteData) { Text("Clear data") } },
        dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
    )
    if (showAbout) {
        val context = LocalContext.current
        val version = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "Development build" }
        AlertDialog(
            onDismissRequest = { showAbout = false },
            title = { Row(verticalAlignment = Alignment.CenterVertically) { BreezeLogo(28.dp); Spacer(Modifier.width(10.dp)); Text("Breeze for Android") } },
            text = { Text("Version ${version}\nEarly development build") },
            confirmButton = { TextButton(onClick = { showAbout = false }) { Text("Done") } },
        )
    }
}

@Composable
private fun HomeOptionsCard(state: BrowserState) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp))) {
        SettingsToggleRow(BreezeIcons.AutoAwesome, "Home field", "Choose whether the new tab field asks Nav or searches", checked = state.homeMode == HomeInputMode.ASK, onLabel = "Ask", onChange = {
            state.homeMode = if (it) HomeInputMode.ASK else HomeInputMode.SEARCH
            state.persist()
        })
        SettingsDivider()
        SettingsToggleRow(BreezeIcons.Palette, "Liquid glass", "Use translucent glass surfaces", state.glass, onChange = {
            state.glass = it; state.persist()
        })
    }
}

@Composable
private fun CloudSyncCard() {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp)).background(MaterialTheme.colorScheme.surface).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(17.dp)).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(BreezeIcons.Cloud, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(27.dp))
        Column(Modifier.weight(1f).padding(start = 14.dp)) {
            Text("Cloud sync", style = MaterialTheme.typography.bodyLarge)
            Text("Bookmarks, history, and chats stay on this device.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text("Coming soon", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
private fun SettingsActionCard(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String, actionLabel: String?, line: Color, onClick: () -> Unit) {
    SettingsActionRow(icon, title, subtitle, actionLabel, line, onClick)
}

@Composable
private fun SettingsActionRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String, value: String?, line: Color, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(26.dp))
        Column(Modifier.weight(1f).padding(start = 15.dp, end = 6.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!value.isNullOrBlank()) Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Icon(BreezeIcons.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(23.dp))
    }
}

@Composable
private fun SettingsToggleRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, description: String, checked: Boolean, onLabel: String? = null, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(26.dp))
        Column(Modifier.weight(1f).padding(start = 15.dp, end = 10.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (description.isNotBlank()) Text(description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (onLabel == null) Switch(checked = checked, onCheckedChange = onChange, colors = androidx.compose.material3.SwitchDefaults.colors(checkedThumbColor=Color.White, checkedTrackColor=BreezeTeal, checkedBorderColor=Color.Transparent, uncheckedThumbColor=Color(0xFFB8BCBF), uncheckedTrackColor=MaterialTheme.colorScheme.surfaceVariant, uncheckedBorderColor=MaterialTheme.colorScheme.outline))
        else {
            Row(Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.background).border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(50))) {
                listOf("Ask", "Search").forEach { label ->
                    val selected = (label == "Ask") == checked
                    Text(label, Modifier.clip(RoundedCornerShape(50)).background(if (selected) MaterialTheme.colorScheme.primary.copy(alpha = .14f) else Color.Transparent)
                        .clickable { onChange(label == "Ask") }.padding(horizontal = 12.dp, vertical = 7.dp),
                        color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}

@Composable
private fun SettingsDivider() {
    Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(1.dp).background(MaterialTheme.colorScheme.outline.copy(alpha = .75f)))
}

private val BACKGROUNDS = listOf(
    "night_coast" to "Night Coast",
    "teal_facets" to "Teal Facets",
    "quiet_dunes" to "Quiet Dunes",
    "aurora" to "Aurora",
)
