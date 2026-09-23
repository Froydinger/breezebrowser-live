package com.froydinger.breeze.ui

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.froydinger.breeze.BrowserState
import com.froydinger.breeze.LocalReminder
import com.froydinger.breeze.notifications.ReminderRepeat
import com.froydinger.breeze.notifications.ReminderScheduler
import java.text.DateFormat
import java.util.Calendar

@Composable
fun ReminderManagerScreen(state: BrowserState) {
    var showComposer by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val line = MaterialTheme.colorScheme.outline
    val ink = MaterialTheme.colorScheme.onSurface
    val muted = MaterialTheme.colorScheme.onSurfaceVariant

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(62.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { state.screen = "settings" }) { Icon(BreezeIcons.ArrowBack, "Back") }
            Text("Reminders", Modifier.weight(1f).padding(start = 8.dp), style = MaterialTheme.typography.headlineSmall, color = ink)
            IconButton(onClick = { showComposer = true }) { Icon(BreezeIcons.Add, "New reminder", tint = MaterialTheme.colorScheme.primary) }
        }

        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 10.dp, bottom = 130.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp))
                        .background(MaterialTheme.colorScheme.surface.copy(alpha = .8f))
                        .border(1.dp, line, RoundedCornerShape(18.dp))
                        .padding(16.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(BreezeIcons.Notifications, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(22.dp))
                        Spacer(Modifier.width(10.dp))
                        Text("On this phone", style = MaterialTheme.typography.titleMedium, color = ink)
                    }
                    Spacer(Modifier.height(6.dp))
                    Text("Reminders are encrypted and scheduled on this device. Cloud sync is coming soon.", style = MaterialTheme.typography.bodyMedium, color = muted)
                    if (!ReminderScheduler.notificationsAllowed(context)) {
                        Spacer(Modifier.height(10.dp))
                        OutlinedButton(onClick = {
                            context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                        }) { Text("Turn on notifications") }
                    }
                }
            }
            val upcoming = state.reminders.filter { it.deliveredAt == null }.sortedBy { it.dueAt }
            val completed = state.reminders.filter { it.deliveredAt != null }.sortedByDescending { it.deliveredAt }
            if (upcoming.isEmpty() && completed.isEmpty()) {
                item {
                    Column(Modifier.fillMaxWidth().padding(top = 38.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(BreezeIcons.Clock, null, tint = muted, modifier = Modifier.size(34.dp))
                        Spacer(Modifier.height(12.dp))
                        Text("No reminders yet", style = MaterialTheme.typography.titleMedium, color = ink)
                        Text("Ask Breeze to remind you, or add one here.", style = MaterialTheme.typography.bodyMedium, color = muted)
                        Spacer(Modifier.height(18.dp))
                        Button(onClick = { showComposer = true }, shape = RoundedCornerShape(50)) {
                            Icon(BreezeIcons.Add, null); Spacer(Modifier.width(8.dp)); Text("New reminder")
                        }
                    }
                }
            } else {
                if (upcoming.isNotEmpty()) {
                    item { Text("Upcoming", style = MaterialTheme.typography.titleMedium, color = ink, modifier = Modifier.padding(top = 8.dp, bottom = 2.dp)) }
                    items(upcoming, key = { it.id }) { reminder ->
                        ReminderRow(reminder, line, ink, muted) { state.removeReminder(reminder.id) }
                    }
                }
                item {
                    OutlinedButton(onClick = { showComposer = true }, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(50)) {
                        Icon(BreezeIcons.Add, null); Spacer(Modifier.width(8.dp)); Text("New reminder")
                    }
                }
                if (completed.isNotEmpty()) {
                    item { Text("Sent", style = MaterialTheme.typography.titleMedium, color = ink, modifier = Modifier.padding(top = 10.dp, bottom = 2.dp)) }
                    items(completed, key = { it.id }) { reminder ->
                        ReminderRow(reminder, line, ink, muted) { state.removeReminder(reminder.id) }
                    }
                }
            }
        }
    }

    if (showComposer) {
        ReminderComposerDialog(
            initialText = "",
            onDismiss = { showComposer = false },
            onSave = { title, dueAt, repeat -> state.addReminder(title, dueAt, repeat); showComposer = false },
            onNotificationsDenied = { state.notice = "Reminder saved, but Android notifications are off. Turn them on in Reminders settings." },
        )
    }
}

@Composable
private fun ReminderRow(reminder: LocalReminder, line: Color, ink: Color, muted: Color, onDelete: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(17.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = .86f))
            .border(1.dp, line, RoundedCornerShape(17.dp))
            .padding(start = 14.dp, top = 12.dp, end = 6.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(38.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary.copy(alpha = .12f)), contentAlignment = Alignment.Center) {
            Icon(BreezeIcons.Clock, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(19.dp))
        }
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(reminder.title, color = ink, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(3.dp))
            Text(
                if (reminder.deliveredAt != null) "Sent ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(reminder.deliveredAt)}"
                else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(reminder.dueAt) +
                    if (reminder.repeat == ReminderRepeat.NONE) "" else " · ${reminder.repeat.label}",
                color = muted,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        IconButton(onClick = onDelete) { Icon(BreezeIcons.Close, if (reminder.deliveredAt != null) "Delete reminder record" else "Cancel reminder", tint = muted) }
    }
}

@Composable
fun ReminderComposerDialog(
    initialText: String,
    onDismiss: () -> Unit,
    onSave: (String, Long, ReminderRepeat) -> Unit,
    onNotificationsDenied: () -> Unit,
    initialDueAt: Long? = null,
    initialRepeat: ReminderRepeat = ReminderRepeat.NONE,
) {
    val context = LocalContext.current
    var title by remember(initialText) { mutableStateOf(initialText.removePrefix("/remind ").trim()) }
    var dueAt by remember(initialText, initialDueAt) { mutableLongStateOf(initialDueAt ?: defaultReminderTime()) }
    var repeat by remember(initialText, initialRepeat) { mutableStateOf(initialRepeat) }
    var repeatMenu by remember { mutableStateOf(false) }
    var savingAfterPermission by remember { mutableStateOf(false) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (savingAfterPermission) {
            if (!granted) onNotificationsDenied()
            onSave(title.trim(), dueAt, repeat)
            savingAfterPermission = false
        }
    }
    fun save() {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            savingAfterPermission = true
            permissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        } else {
            if (!ReminderScheduler.notificationsAllowed(context)) onNotificationsDenied()
            onSave(title.trim(), dueAt, repeat)
        }
    }
    val selected = Calendar.getInstance().apply { timeInMillis = dueAt }

    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(BreezeIcons.Notifications, null, tint = MaterialTheme.colorScheme.primary) },
        title = { Text("Set a reminder") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text("What should Breeze remind you?") },
                    singleLine = false,
                    minLines = 1,
                    maxLines = 3,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        modifier = Modifier.weight(1f),
                        onClick = {
                            val current = Calendar.getInstance().apply { timeInMillis = dueAt }
                            DatePickerDialog(context, { _, year, month, day ->
                                val next = Calendar.getInstance().apply {
                                    timeInMillis = dueAt
                                    set(Calendar.YEAR, year); set(Calendar.MONTH, month); set(Calendar.DAY_OF_MONTH, day)
                                }
                                dueAt = next.timeInMillis
                            }, current.get(Calendar.YEAR), current.get(Calendar.MONTH), current.get(Calendar.DAY_OF_MONTH)).show()
                        },
                    ) { Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(dueAt), maxLines = 1) }
                    OutlinedButton(
                        modifier = Modifier.weight(1f),
                        onClick = {
                            val current = Calendar.getInstance().apply { timeInMillis = dueAt }
                            TimePickerDialog(context, { _, hour, minute ->
                                val next = Calendar.getInstance().apply {
                                    timeInMillis = dueAt
                                    set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, minute); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
                                }
                                dueAt = next.timeInMillis
                            }, current.get(Calendar.HOUR_OF_DAY), current.get(Calendar.MINUTE), android.text.format.DateFormat.is24HourFormat(context)).show()
                        },
                    ) { Text(DateFormat.getTimeInstance(DateFormat.SHORT).format(dueAt), maxLines = 1) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    listOf(1L, 5L, 15L).forEach { minutes ->
                        OutlinedButton(
                            onClick = { dueAt = System.currentTimeMillis() + minutes * 60_000L },
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 5.dp),
                        ) { Text("${minutes} min") }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Repeat", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                    Box {
                        OutlinedButton(onClick = { repeatMenu = true }) { Text(repeat.label) }
                        DropdownMenu(expanded = repeatMenu, onDismissRequest = { repeatMenu = false }) {
                            ReminderRepeat.entries.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(option.label) },
                                    onClick = { repeat = option; repeatMenu = false },
                                )
                            }
                        }
                    }
                }
                Text("Saved on this phone. Android may deliver a little after the selected time.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            TextButton(onClick = ::save, enabled = title.isNotBlank() && dueAt > System.currentTimeMillis()) { Text("Set reminder") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun defaultReminderTime(): Long = Calendar.getInstance().apply {
    add(Calendar.HOUR_OF_DAY, 1)
    set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis
