package com.froydinger.breeze.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.froydinger.breeze.SavedPage

@Composable
fun LibrarySearchBar(query: String, onQuery: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).height(52.dp)
            .clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.surface)
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(50)).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(BreezeIcons.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(23.dp))
        Spacer(Modifier.width(14.dp))
        androidx.compose.foundation.text.BasicTextField(
            value = query,
            onValueChange = onQuery,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
            decorationBox = { inner ->
                if (query.isEmpty()) Text("Search", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyLarge)
                inner()
            },
        )
    }
}

@Composable
fun LibraryItemActions(onDelete: () -> Unit) {
    var confirmDelete by remember { mutableStateOf(false) }
    IconButton(onClick = { confirmDelete = true }) {
        Icon(BreezeIcons.Delete, contentDescription = "Delete item")
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this item?") },
            text = { Text("This saved item will be removed from this device.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun LibraryClearHistoryAction(onClear: () -> Unit) {
    var confirmClear by remember { mutableStateOf(false) }
    Surface(
        onClick = { confirmClear = true }, shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
    ) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(BreezeIcons.Delete, contentDescription = null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.width(7.dp)); Text("Clear history", style = MaterialTheme.typography.labelLarge)
        }
    }
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Clear web history?") },
            text = { Text("All saved web visits on this device will be removed. Bookmarks and chats will stay.") },
            confirmButton = {
                TextButton(onClick = { confirmClear = false; onClear() }) { Text("Clear history") }
            },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun LibraryEditBookmarkAction(page: SavedPage, onSave: (SavedPage) -> Unit) {
    var editing by remember(page.id) { mutableStateOf(false) }
    IconButton(onClick = { editing = true }) {
        Icon(BreezeIcons.Edit, contentDescription = "Edit bookmark")
    }
    if (editing) BookmarkEditor(page = page, onDismiss = { editing = false }) { updated ->
        onSave(updated)
        editing = false
    }
}

@Composable
private fun BookmarkEditor(page: SavedPage, onDismiss: () -> Unit, onSave: (SavedPage) -> Unit) {
    var title by remember(page.id) { mutableStateOf(page.title) }
    var url by remember(page.id) { mutableStateOf(page.url) }
    val trimmedUrl = url.trim()
    val parsed = remember(trimmedUrl) { runCatching { java.net.URI(trimmedUrl) }.getOrNull() }
    val scheme = parsed?.scheme?.lowercase()
    val validUrl = (scheme == "https" || scheme == "http") && !parsed?.host.isNullOrBlank()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit bookmark") },
        text = {
            Column {
                OutlinedTextField(value = title, onValueChange = { title = it }, label = { Text("Title") }, singleLine = true)
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    label = { Text("Web address") },
                    singleLine = true,
                    isError = trimmedUrl.isNotEmpty() && !validUrl,
                    supportingText = if (trimmedUrl.isNotEmpty() && !validUrl) ({ Text("Enter a valid HTTP or HTTPS address.") }) else null,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = title.isNotBlank() && validUrl,
                onClick = { onSave(page.copy(title = title.trim(), url = trimmedUrl)) },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
