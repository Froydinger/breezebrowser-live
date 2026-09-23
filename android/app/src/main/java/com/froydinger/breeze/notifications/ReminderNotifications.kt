package com.froydinger.breeze.notifications

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.media.AudioAttributes
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import com.froydinger.breeze.BreezeApplication
import com.froydinger.breeze.LocalReminder
import com.froydinger.breeze.MainActivity
import com.froydinger.breeze.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.runtime.snapshotFlow
import java.time.Instant
import java.time.ZonedDateTime
import java.time.DayOfWeek

object ReminderScheduler {
    const val ACTION_FIRE = "com.froydinger.breeze.action.FIRE_REMINDER"
    const val ACTION_REFRESH = "com.froydinger.breeze.action.REFRESH_REMINDERS"
    private const val CHANNEL_ID = "breeze_reminders_v2"
    private const val EXTRA_REMINDER_ID = "reminder_id"

    fun schedule(context: Context, reminder: LocalReminder) {
        if (reminder.deliveredAt != null) {
            cancel(context, reminder.id)
            return
        }
        ensureChannel(context)
        val alarm = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = alarmIntent(context, reminder.id)
        // Local reminders use Android's inexact idle-friendly alarm path. It needs
        // no Firebase/VAPID or special exact-alarm access and may be delivered late.
        val now = System.currentTimeMillis()
        val triggerAt = reminder.dueAt.takeIf { it > now } ?: (now + 2_000L)
        alarm.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAt,
            pending,
        )
    }

    fun nextOccurrence(reminder: LocalReminder, now: ZonedDateTime = ZonedDateTime.now()): Long? {
        if (reminder.repeat == ReminderRepeat.NONE) return null
        val zone = now.zone
        val original = Instant.ofEpochMilli(reminder.dueAt).atZone(zone)
        val anchorDay = reminder.repeatDayOfMonth.takeIf { it in 1..31 } ?: original.dayOfMonth
        var next = when (reminder.repeat) {
            ReminderRepeat.NONE -> return null
            ReminderRepeat.DAILY -> original.plusDays(1)
            ReminderRepeat.WEEKDAYS -> nextWeekdayAfter(original)
            ReminderRepeat.WEEKLY -> original.plusWeeks(1)
            ReminderRepeat.MONTHLY -> monthWithAnchor(original, anchorDay)
        }
        while (!next.isAfter(now)) {
            next = when (reminder.repeat) {
                ReminderRepeat.NONE -> return null
                ReminderRepeat.DAILY -> next.plusDays(1)
                ReminderRepeat.WEEKDAYS -> nextWeekdayAfter(next)
                ReminderRepeat.WEEKLY -> next.plusWeeks(1)
                ReminderRepeat.MONTHLY -> monthWithAnchor(next, anchorDay)
            }
        }
        return next.toInstant().toEpochMilli()
    }

    private fun nextWeekdayAfter(value: ZonedDateTime): ZonedDateTime {
        var next = value.plusDays(1)
        while (next.dayOfWeek == DayOfWeek.SATURDAY || next.dayOfWeek == DayOfWeek.SUNDAY) next = next.plusDays(1)
        return next
    }

    private fun monthWithAnchor(value: ZonedDateTime, day: Int): ZonedDateTime {
        val month = value.plusMonths(1)
        return month.withDayOfMonth(day.coerceAtMost(month.toLocalDate().lengthOfMonth()))
    }

    fun cancel(context: Context, id: String) {
        val alarm = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = alarmIntent(context, id)
        alarm.cancel(pending)
        pending.cancel()
    }

    private fun alarmIntent(context: Context, id: String): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
            .setAction(ACTION_FIRE)
            .setData(Uri.parse("breeze://reminder/$id"))
            .putExtra(EXTRA_REMINDER_ID, id)
        return PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "On-device reminders you set in Breeze"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    setSound(
                        Uri.parse("android.resource://${context.packageName}/${R.raw.reminder_notification}"),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                },
            )
        }
    }

    fun notificationsAllowed(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
    }

    fun post(context: Context, reminder: LocalReminder) {
        if (!notificationsAllowed(context)) return
        ensureChannel(context)
        val openApp = PendingIntent.getActivity(
            context,
            reminder.id.hashCode(),
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.breeze_wave)
            .setContentTitle("Breeze reminder")
            .setContentText(reminder.title)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(
                Notification.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.breeze_wave)
                    .setContentTitle("Breeze reminder")
                    .setContentText("Open Breeze to view your reminder")
                    .build(),
            )
            .build()
        context.getSystemService(NotificationManager::class.java)?.notify(reminder.id, reminder.id.hashCode(), notification)
    }

    internal const val REMINDER_ID_EXTRA = EXTRA_REMINDER_ID
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        scope.launch {
            try {
                val app = context.applicationContext as? BreezeApplication ?: return@launch
                val state = app.browser
                withTimeoutOrNull(8_000L) { snapshotFlow { state.ready }.first { it } }
                if (!state.ready) return@launch
                if (intent.action == ReminderScheduler.ACTION_FIRE) {
                    val id = intent.getStringExtra(ReminderScheduler.REMINDER_ID_EXTRA) ?: return@launch
                    val reminder = state.reminders.firstOrNull { it.id == id } ?: return@launch
                    if (reminder.deliveredAt != null) {
                        ReminderScheduler.cancel(context, id)
                        return@launch
                    }
                    if (reminder.dueAt > System.currentTimeMillis()) {
                        ReminderScheduler.schedule(context, reminder)
                        return@launch
                    }
                    ReminderScheduler.post(context, reminder)
                    val next = ReminderScheduler.nextOccurrence(reminder)
                    if (next == null) state.completeReminder(id) else state.advanceReminderOccurrence(id, next)
                    if (next == null) state.persistImmediately()
                } else {
                    state.reminders.forEach { ReminderScheduler.schedule(context, it) }
                }
            } finally {
                pending.finish()
                scope.cancel()
            }
        }
    }
}
