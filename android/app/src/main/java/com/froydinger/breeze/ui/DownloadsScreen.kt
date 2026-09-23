package com.froydinger.breeze.ui

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.froydinger.breeze.BrowserState
import java.text.DateFormat
import java.util.Date

@Composable
fun DownloadsScreen(state: BrowserState) {
    val context = LocalContext.current
    val dateFormat = remember { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT) }
    val dark = MaterialTheme.colorScheme.background.red < .3f
    val cardColor = if (dark) Color.Black else Color(0xFFFAF9F7)
    val cardBorder = MaterialTheme.colorScheme.onSurface.copy(alpha = if (dark) .14f else .18f)

    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 10.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { state.screen = "settings" }) {
                Icon(BreezeIcons.ArrowBack, contentDescription = "Back to settings", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.width(6.dp))
            Text("Downloads", style = MaterialTheme.typography.headlineSmall)
        }

        if (state.downloads.isEmpty()) {
            Column(
                Modifier.weight(1f).fillMaxWidth().padding(bottom = 52.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    Modifier.size(72.dp).clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .6f))
                        .border(1.dp, cardBorder, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(BreezeIcons.Download, contentDescription = null, modifier = Modifier.size(29.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.height(17.dp))
                Text("No downloads yet", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp))
                Text("Files you save from pages will show up here.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(top = 14.dp, bottom = 20.dp),
                verticalArrangement = Arrangement.spacedBy(11.dp),
            ) {
                items(state.downloads, key = { it.id }) { entry ->
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        color = cardColor,
                        shape = RoundedCornerShape(19.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, cardBorder),
                    ) {
                        Row(Modifier.padding(start = 14.dp, end = 8.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                Modifier.size(42.dp).clip(RoundedCornerShape(13.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .66f)),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(BreezeIcons.FileText, contentDescription = null, modifier = Modifier.size(21.dp), tint = MaterialTheme.colorScheme.primary)
                            }
                            Spacer(Modifier.width(13.dp))
                            Column(Modifier.weight(1f)) {
                                Text(entry.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Spacer(Modifier.height(3.dp))
                                Text("Saved ${dateFormat.format(Date(entry.time))}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                            }
                            IconButton(onClick = { state.openDownload(entry) }, modifier = Modifier.size(40.dp)) {
                                Icon(BreezeIcons.OpenInNew, contentDescription = "Open ${entry.name}", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(19.dp))
                            }
                            IconButton(onClick = {
                                runCatching {
                                    val uri = Uri.parse(entry.uri)
                                    val mime = context.contentResolver.getType(uri) ?: "*/*"
                                    val send = Intent(Intent.ACTION_SEND).apply {
                                        type = mime
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        clipData = ClipData.newUri(context.contentResolver, entry.name, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    context.startActivity(Intent.createChooser(send, "Share download"))
                                }.onFailure {
                                    state.notice = "This download could not be shared. It may have moved, or need another app."
                                }
                            }, modifier = Modifier.size(40.dp)) {
                                Icon(BreezeIcons.Share, contentDescription = "Share ${entry.name}", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(19.dp))
                            }
                            IconButton(onClick = { state.removeDownload(entry.id) }, modifier = Modifier.size(40.dp)) {
                                Icon(BreezeIcons.Delete, contentDescription = "Remove ${entry.name} from download history", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(19.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}
