package com.froydinger.breeze.notifications

import java.time.LocalTime
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.time.temporal.ChronoUnit.HOURS

enum class ReminderRepeat(val label: String) {
    NONE("Doesn't repeat"), DAILY("Every day"), WEEKDAYS("Weekdays"), WEEKLY("Every week"), MONTHLY("Every month");
}

data class ParsedReminderRequest(val title: String, val dueAt: Long, val repeat: ReminderRepeat = ReminderRepeat.NONE)

/** A small, predictable local parser for explicit "remind me" requests. */
object ReminderRequestParser {
    private val prefix = Regex("^\\s*(?:please\\s+)?remind\\s+me(?:\\s+to)?\\s+", RegexOption.IGNORE_CASE)
    private val relative = Regex("\\bin\\s+(\\d{1,4})\\s*(minute|hour|day)s?\\b", RegexOption.IGNORE_CASE)
    private val clock12 = Regex("\\b(?:at\\s+)?(1[0-2]|0?[1-9])(?::([0-5]\\d))?\\s*(a\\.?m\\.?|p\\.?m\\.?)\\b", RegexOption.IGNORE_CASE)
    private val clock24 = Regex("\\bat\\s+([01]?\\d|2[0-3]):([0-5]\\d)\\b", RegexOption.IGNORE_CASE)
    private val dayWord = Regex("\\b(today|tomorrow|tonight)\\b", RegexOption.IGNORE_CASE)
    private val repeatWord = Regex("\\b(every\\s+day|daily|weekdays|every\\s+week|weekly|every\\s+month|monthly)\\b", RegexOption.IGNORE_CASE)

    fun isReminderRequest(text: String): Boolean = prefix.containsMatchIn(text)

    /** Preselects the named day when the user still needs to choose a time in the reminder sheet. */
    fun suggestedDueAt(text: String, now: ZonedDateTime = ZonedDateTime.now()): Long? {
        val day = when (dayWord.find(text)?.groupValues?.get(1)?.lowercase()) {
            "today", "tonight" -> now.toLocalDate()
            "tomorrow" -> now.toLocalDate().plusDays(1)
            else -> return null
        }
        val nextHour = now.plusHours(1).truncatedTo(HOURS).toLocalTime()
        var candidate = day.atTime(nextHour).atZone(now.zone)
        if (!candidate.isAfter(now)) candidate = candidate.plusDays(1)
        return candidate.toInstant().toEpochMilli()
    }

    fun parse(text: String, now: ZonedDateTime = ZonedDateTime.now()): ParsedReminderRequest? {
        if (!isReminderRequest(text)) return null
        val title = taskTitle(text)
        if (title.isBlank()) return null

        val relativeMatch = relative.find(text)
        val due = if (relativeMatch != null) {
            val amount = relativeMatch.groupValues[1].toLongOrNull()?.coerceIn(1, 365) ?: return null
            when (relativeMatch.groupValues[2].lowercase()) {
                "minute" -> now.plusMinutes(amount)
                "hour" -> now.plusHours(amount)
                else -> now.plusDays(amount)
            }
        } else {
            val dateMatch = dayWord.find(text)
            val date = when (dateMatch?.groupValues?.get(1)?.lowercase()) {
                "today", "tonight" -> now.toLocalDate()
                "tomorrow" -> now.toLocalDate().plusDays(1)
                else -> null
            }
            val time12 = clock12.find(text)
            val time24 = clock24.find(text)
            val time = when {
                time12 != null -> {
                    val hour = time12.groupValues[1].toInt()
                    val minute = time12.groupValues[2].ifBlank { "0" }.toInt()
                    val afternoon = time12.groupValues[3].startsWith("p", true)
                    LocalTime.of((hour % 12) + if (afternoon) 12 else 0, minute)
                }
                time24 != null -> LocalTime.of(time24.groupValues[1].toInt(), time24.groupValues[2].toInt())
                Regex("\\bnoon\\b", RegexOption.IGNORE_CASE).containsMatchIn(text) -> LocalTime.NOON
                Regex("\\btonight\\b", RegexOption.IGNORE_CASE).containsMatchIn(text) -> LocalTime.of(20, 0)
                else -> null
            } ?: return null
            var target = (date ?: now.toLocalDate()).atTime(time).atZone(now.zone)
            if (date == null && !target.isAfter(now)) target = target.plusDays(1)
            target
        }

        if (!due.isAfter(now)) return null
        val repeat = when (repeatWord.find(text)?.groupValues?.get(1)?.lowercase()?.replace(Regex("\\s+"), " ")) {
            "every day", "daily" -> ReminderRepeat.DAILY
            "weekdays" -> ReminderRepeat.WEEKDAYS
            "every week", "weekly" -> ReminderRepeat.WEEKLY
            "every month", "monthly" -> ReminderRepeat.MONTHLY
            else -> ReminderRepeat.NONE
        }
        val dueAt = if (relativeMatch != null) due.toInstant().toEpochMilli() else due.truncatedTo(ChronoUnit.MINUTES).toInstant().toEpochMilli()
        return ParsedReminderRequest(title, dueAt, repeat)
    }

    fun taskTitle(text: String): String {
        var title = prefix.replaceFirst(text, "")
        title = relative.replace(title, " ")
        title = clock12.replace(title, " ")
        title = clock24.replace(title, " ")
        title = dayWord.replace(title, " ")
        title = repeatWord.replace(title, " ")
        title = Regex("\\bnoon\\b", RegexOption.IGNORE_CASE).replace(title, " ")
        title = Regex("\\b(?:at|on)\\s*$", RegexOption.IGNORE_CASE).replace(title, " ")
        return title.replace(Regex("\\s+"), " ").trim(' ', ',', '.', ';', ':', '-')
    }
}
