package com.froydinger.breeze.core

import java.net.URLEncoder

enum class InputSurface { HOME, WEBPAGE }

sealed interface InputRoute {
    data class OpenUrl(val url: String) : InputRoute
    data class Search(val query: String, val engine: SearchEngine, val url: String) : InputRoute
    data class StartChat(val prompt: String, val fresh: Boolean = true) : InputRoute
    data class RunTask(val task: NavTask, val prompt: String) : InputRoute
}

enum class NavTask(val slug: String, val needsPrompt: Boolean) {
    RESEARCH("research", true), SUMMARIZE("summarize", false),
    FACTCHECK("factcheck", true), YOUTUBE("youtube", false);

    companion object {
        /** Desktop-compatible exact slug first, then a unique abbreviated prefix. */
        fun match(token: String): NavTask? {
            val normalized = token.trim().lowercase()
            if (normalized.isEmpty()) return null
            return entries.firstOrNull { it.slug == normalized }
                ?: entries.filter { it.slug.startsWith(normalized) }.singleOrNull()
        }
    }
}

/**
 * Deterministic routing contract for home Ask/Search and webpage address input.
 * Ordinary text always stays in Nav. Web searches require a search mode, the
 * explicit search control, or an explicit search phrase. URLs are the only
 * unprompted input that opens a page.
 */
object InputRouter {
    /**
     * @param surface HOME follows [homeMode]; WEBPAGE uses explicit search gestures only.
     * @param explicitSearch Search-button/engine modifier. If set, non-URL text is searched.
     */
    fun route(
        rawInput: String,
        surface: InputSurface,
        homeMode: HomeInputMode = HomeInputMode.ASK,
        searchEngine: SearchEngine = SearchEngine.SPECTRA,
        explicitSearch: Boolean = false,
    ): InputRoute? {
        val input = rawInput.trim()
        if (input.isEmpty()) return null

        parseTask(input)?.let { return it }

        if (looksLikeUrl(input)) return InputRoute.OpenUrl(normalizeUrl(input))

        openSearchResultsQuery(input)?.let { return search(it, SearchEngine.SPECTRA) }

        val modified = explicitSearchModifier(input)
        val genericQuery = explicitGenericSearchQuery(input)
        val query = modified?.second ?: genericQuery ?: input
        val engine = modified?.first ?: searchEngine

        if (explicitSearch || modified != null || genericQuery != null ||
            (surface == InputSurface.HOME && homeMode == HomeInputMode.SEARCH)
        ) {
            return search(query, engine)
        }

        if (surface == InputSurface.HOME) return InputRoute.StartChat(input)

        // Address-bar text is still an Ask action unless the user explicitly
        // switches to Search or uses a search modifier/button.
        return InputRoute.StartChat(input)
    }

    fun looksLikeUrl(rawInput: String): Boolean {
        val input = rawInput.trim()
        if (input.contains("://")) {
            val scheme = input.substringBefore("://").lowercase()
            if (scheme != "http" && scheme != "https") return false
            return runCatching {
                val uri = java.net.URI(input)
                !uri.host.isNullOrBlank()
            }.getOrDefault(false)
        }
        // Avoid treating arbitrary colon/dot punctuation as a URL. Validate a
        // conventional DNS name (including localhost) with an optional port/path.
        if (input.any(Char::isWhitespace)) return false
        return runCatching {
            val uri = java.net.URI("https://$input")
            val host = uri.host ?: return false
            val labels = host.trimEnd('.').split('.')
            val validHost = host.equals("localhost", ignoreCase = true) ||
                host.matches(Regex("\\d{1,3}(?:\\.\\d{1,3}){3}")) ||
                (labels.size >= 2 && labels.all { it.isNotEmpty() && it.length <= 63 } &&
                    (labels.last().length >= 2 || labels.last().startsWith("xn--", ignoreCase = true)))
            validHost && (uri.port == -1 || uri.port in 1..65535)
        }.getOrDefault(false)
    }

    fun searchUrl(query: String, engine: SearchEngine): String {
        val encoded = URLEncoder.encode(query, "UTF-8").replace("+", "%20")
        val base = when (engine) {
            SearchEngine.SPECTRA -> "https://spectrasearch.online/search?q="
            SearchEngine.GOOGLE -> "https://www.google.com/search?q="
            SearchEngine.DUCKDUCKGO -> "https://duckduckgo.com/?q="
            SearchEngine.BING -> "https://www.bing.com/search?q="
            SearchEngine.BRAVE -> "https://search.brave.com/search?q="
        }
        return base + encoded
    }

    private fun search(query: String, engine: SearchEngine) =
        InputRoute.Search(query, engine, searchUrl(query, engine))

    private fun normalizeUrl(input: String): String =
        if (input.contains("://")) input else "https://$input"

    private fun explicitSearchModifier(input: String): Pair<SearchEngine, String>? {
        val lower = input.lowercase()
        val modifiers = listOf(
            "search with duckduckgo " to SearchEngine.DUCKDUCKGO,
            "search with google " to SearchEngine.GOOGLE,
            "search with bing " to SearchEngine.BING,
            "search with brave " to SearchEngine.BRAVE,
            "search with spectra " to SearchEngine.SPECTRA,
        )
        val match = modifiers.firstOrNull { lower.startsWith(it.first) } ?: return null
        val remainder = input.drop(match.first.length).trim()
        return if (remainder.isEmpty()) null else match.second to remainder
    }

    private fun explicitGenericSearchQuery(input: String): String? {
        val prefixes = listOf("search ", "look up ")
        val prefix = prefixes.firstOrNull { input.startsWith(it, ignoreCase = true) } ?: return null
        return input.drop(prefix.length).trim().takeIf(String::isNotEmpty)
    }

    private fun openSearchResultsQuery(input: String): String? {
        val prefix = "open search results for "
        return if (input.startsWith(prefix, ignoreCase = true)) input.drop(prefix.length).trim().takeIf(String::isNotEmpty) else null
    }

    private fun parseTask(input: String): InputRoute.RunTask? {
        if (!input.startsWith('/')) return null
        val body = input.drop(1)
        val split = body.split(Regex("\\s+"), limit = 2)
        val task = NavTask.match(split.firstOrNull().orEmpty()) ?: return null
        return InputRoute.RunTask(task, split.getOrNull(1)?.trim().orEmpty())
    }
}
