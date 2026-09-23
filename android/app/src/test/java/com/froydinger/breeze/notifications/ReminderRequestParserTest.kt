package com.froydinger.breeze.notifications

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class ReminderRequestParserTest {
    private val zone = ZoneId.of("America/Chicago")
    private val now = ZonedDateTime.of(2026, 9, 23, 14, 10, 0, 0, zone)

    @Test
    fun tomorrowAtThreePmUsesTheFollowingLocalDate() {
        val reminder = ReminderRequestParser.parse("Remind me to buy eggs tomorrow at 3pm", now)
        assertNotNull(reminder)
        val due = ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(reminder!!.dueAt), zone)
        assertEquals(LocalDate.of(2026, 9, 24), due.toLocalDate())
        assertEquals(LocalTime.of(15, 0), due.toLocalTime())
        assertEquals("buy eggs", reminder.title)
    }

    @Test
    fun tomorrowWithoutTimeKeepsTomorrowInTheReminderComposer() {
        val dueAt = ReminderRequestParser.suggestedDueAt("Remind me to buy eggs tomorrow", now)
        assertNotNull(dueAt)
        val due = ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(dueAt!!), zone)
        assertEquals(LocalDate.of(2026, 9, 24), due.toLocalDate())
        assertEquals(LocalTime.of(15, 0), due.toLocalTime())
    }

    @Test
    fun oneMinuteReminderIsExactlyOneMinuteAway() {
        val reminder = ReminderRequestParser.parse("Remind me to buy eggs in 1 minute", now)
        assertNotNull(reminder)
        assertEquals(now.plusMinutes(1).toInstant().toEpochMilli(), reminder!!.dueAt)
    }
}
