package com.froydinger.breeze.data

import android.text.Html
import com.froydinger.breeze.SavedPage
import java.util.UUID

/** Parsers for the portable formats exported by common desktop and mobile browsers. */
object BrowserImport {
    fun bookmarksHtml(source: String): List<SavedPage> {
        val result = LinkedHashMap<String, SavedPage>()
        val anchors = Regex("(?is)<a\\b([^>]*)>(.*?)</a\\s*>")
        val href = Regex("(?is)\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        for (match in anchors.findAll(source)) {
            val attr = href.find(match.groupValues[1]) ?: continue
            val rawUrl = listOf(attr.groupValues[1], attr.groupValues[2], attr.groupValues[3]).first { it.isNotEmpty() }
            val url = decode(rawUrl).trim()
            if (!url.startsWith("http://", true) && !url.startsWith("https://", true)) continue
            val title = decode(match.groupValues[2].replace(Regex("(?is)<[^>]*>"), " ")).trim().ifBlank { url }
            result.putIfAbsent(url, SavedPage(UUID.randomUUID().toString(), title.take(2048), url.take(8192)))
        }
        return result.values.toList()
    }

    /** Parses RFC 4180 CSV including quoted commas, escaped quotes, and quoted newlines. */
    fun passwordsCsv(source: String): List<ImportedPassword> {
        val rows = parseCsv(source.removePrefix("\uFEFF"))
        if (rows.isEmpty()) return emptyList()
        val headers = rows.first().map { it.trim().lowercase().replace(Regex("[^a-z0-9]"), "") }
        fun column(vararg names: String) = names.firstNotNullOfOrNull { name -> headers.indexOf(name).takeIf { it >= 0 } }
        val urlColumn = column("url", "website", "origin", "hostname", "site") ?: return emptyList()
        val userColumn = column("username", "user", "loginusername") ?: return emptyList()
        val passColumn = column("password", "pass") ?: return emptyList()
        val output = LinkedHashMap<Pair<String, String>, ImportedPassword>()
        rows.drop(1).forEach { row ->
            val url = row.getOrNull(urlColumn)?.trim().orEmpty()
            val username = row.getOrNull(userColumn)?.trim().orEmpty()
            val password = row.getOrNull(passColumn).orEmpty()
            if ((url.startsWith("http://", true) || url.startsWith("https://", true)) && username.isNotBlank() && password.isNotEmpty()) {
                output[url to username] = ImportedPassword(url, username, password)
            }
        }
        return output.values.toList()
    }

    private fun decode(value: String): String = Html.fromHtml(value, Html.FROM_HTML_MODE_LEGACY).toString()

    private fun parseCsv(text: String): List<List<String>> {
        val rows = mutableListOf<List<String>>()
        var row = mutableListOf<String>()
        val field = StringBuilder()
        var quoted = false
        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                quoted && c == '"' && i + 1 < text.length && text[i + 1] == '"' -> { field.append('"'); i++ }
                c == '"' -> quoted = !quoted
                !quoted && c == ',' -> { row.add(field.toString()); field.setLength(0) }
                !quoted && (c == '\n' || c == '\r') -> {
                    row.add(field.toString()); field.setLength(0)
                    if (row.any { it.isNotEmpty() }) rows.add(row)
                    row = mutableListOf()
                    if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++
                }
                else -> field.append(c)
            }
            i++
        }
        if (field.isNotEmpty() || row.isNotEmpty()) { row.add(field.toString()); rows.add(row) }
        return rows
    }
}

data class ImportedPassword(val url: String, val username: String, val password: String)
