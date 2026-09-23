package com.froydinger.breeze.core

import java.time.Instant
import java.util.UUID

/** Stable, dependency-free domain records shared by Android UI and persistence adapters. */
object Ids {
    fun newId(): String = UUID.randomUUID().toString()
}

enum class TabKind { WEB, HOME, CHAT, PRIVATE }
enum class ThemeMode { SYSTEM, LIGHT, DARK }
enum class HomeInputMode { ASK, SEARCH }
enum class SearchEngine(val id: String, val displayName: String) {
    SPECTRA("spectra", "Spectra"), GOOGLE("google", "Google"),
    DUCKDUCKGO("duckduckgo", "DuckDuckGo"), BING("bing", "Bing"), BRAVE("brave", "Brave");

    companion object {
        fun fromId(id: String?): SearchEngine = entries.firstOrNull { it.id == id?.lowercase() } ?: SPECTRA
    }
}

data class BrowserTab(
    val id: String = Ids.newId(),
    val url: String? = null,
    val title: String = "New tab",
    val kind: TabKind = TabKind.HOME,
    val isPinned: Boolean = false,
    val groupId: String? = null,
    val createdAt: Instant = Instant.now(),
    val lastActiveAt: Instant = createdAt,
)

data class Bookmark(
    val id: String = Ids.newId(),
    val url: String,
    val title: String,
    val folderId: String? = null,
    val createdAt: Instant = Instant.now(),
    val updatedAt: Instant = createdAt,
)

data class HistoryEntry(
    val id: String = Ids.newId(),
    val url: String,
    val title: String,
    val visitedAt: Instant = Instant.now(),
    val isPrivate: Boolean = false,
)

data class Chat(
    val id: String = Ids.newId(),
    val title: String = "New chat",
    val createdAt: Instant = Instant.now(),
    val updatedAt: Instant = createdAt,
    val parentChatId: String? = null,
)

enum class MessageRole { USER, ASSISTANT, TOOL }

data class ChatMessage(
    val id: String = Ids.newId(),
    val chatId: String,
    val role: MessageRole,
    val text: String,
    val createdAt: Instant = Instant.now(),
    val parentMessageId: String? = null,
    val citations: List<Citation> = emptyList(),
)

data class Citation(val title: String, val url: String, val snippet: String? = null)

data class BrowserSettings(
    val theme: ThemeMode = ThemeMode.SYSTEM,
    val homeInputMode: HomeInputMode = HomeInputMode.ASK,
    val searchEngine: SearchEngine = SearchEngine.SPECTRA,
    val showShortcuts: Boolean = true,
    val trackingProtectionEnabled: Boolean = true,
)
