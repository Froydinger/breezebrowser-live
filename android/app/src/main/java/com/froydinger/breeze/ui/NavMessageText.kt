package com.froydinger.breeze.ui

import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.LinkInteractionListener
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.froydinger.breeze.BrowserState

/** Small, local Markdown renderer for assistant replies. It does not fetch or interpret HTML. */
@Composable
fun NavMessageText(markdown: String, state: BrowserState, modifier: Modifier = Modifier, numberedCards: Boolean = false) {
    val linkColor = if (MaterialTheme.colorScheme.background.red < .3f) Color(0xFF63D4DA) else Color(0xFF087C89)
    val codeBackground = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .55f)
    val blocks = remember(markdown) { parseMarkdownBlocks(markdown) }

    SelectionContainer(modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            blocks.forEach { block ->
                when (block) {
                    is MarkdownBlock.Paragraph -> Text(
                        text = inlineMarkdown(block.text, state, linkColor, codeBackground),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    is MarkdownBlock.Heading -> Text(
                        text = inlineMarkdown(block.text, state, linkColor, codeBackground),
                        style = when (block.level) {
                            1, 2 -> MaterialTheme.typography.titleLarge
                            3 -> MaterialTheme.typography.titleMedium
                            else -> MaterialTheme.typography.titleSmall
                        },
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    is MarkdownBlock.ListItems -> Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        block.items.forEachIndexed { index, item ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                                if (numberedCards) Box(Modifier.size(30.dp).background(MaterialTheme.colorScheme.surfaceVariant, CircleShape).border(.6.dp, MaterialTheme.colorScheme.outline, CircleShape),contentAlignment=Alignment.Center) { Text("${index+1}",style=MaterialTheme.typography.bodyLarge) }
                                else Text(item.marker, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Spacer(Modifier.width(9.dp))
                                Text(
                                    text = inlineMarkdown(item.text, state, linkColor, codeBackground),
                                    modifier = Modifier.weight(1f),
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private sealed interface MarkdownBlock {
    data class Paragraph(val text: String) : MarkdownBlock
    data class Heading(val level: Int, val text: String) : MarkdownBlock
    data class ListItems(val items: List<MarkdownListItem>) : MarkdownBlock
}

private data class MarkdownListItem(val marker: String, val text: String)

private fun parseMarkdownBlocks(source: String): List<MarkdownBlock> {
    val lines = source.replace("\r\n", "\n").replace('\r', '\n').lines()
    val result = mutableListOf<MarkdownBlock>()
    val paragraph = mutableListOf<String>()
    val list = mutableListOf<MarkdownListItem>()

    fun flushParagraph() {
        if (paragraph.isNotEmpty()) {
            result += MarkdownBlock.Paragraph(paragraph.joinToString(" ").trim())
            paragraph.clear()
        }
    }
    fun flushList() {
        if (list.isNotEmpty()) {
            result += MarkdownBlock.ListItems(list.toList())
            list.clear()
        }
    }

    for (line in lines) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) {
            flushParagraph()
            flushList()
            continue
        }

        val heading = Regex("^(#{1,6})\\s+(.+)$").matchEntire(trimmed)
        if (heading != null) {
            flushParagraph(); flushList()
            result += MarkdownBlock.Heading(heading.groupValues[1].length.coerceAtMost(4), heading.groupValues[2].trim())
            continue
        }

        val bullet = Regex("^([-*+])\\s+(.+)$").matchEntire(trimmed)
        val numbered = Regex("^(\\d{1,3})[.)]\\s+(.+)$").matchEntire(trimmed)
        when {
            bullet != null -> {
                flushParagraph()
                list += MarkdownListItem("•", bullet.groupValues[2])
            }
            numbered != null -> {
                flushParagraph()
                list += MarkdownListItem("${numbered.groupValues[1]}.", numbered.groupValues[2])
            }
            else -> {
                flushList()
                paragraph += trimmed
            }
        }
    }
    flushParagraph(); flushList()
    return result
}

private val markdownToken = Regex("\\[([^\\]]+)]\\(([^)\\s]+)\\)|\\*\\*([^*]+)\\*\\*|__([^_]+)__|`([^`]+)`")

private fun inlineMarkdown(source: String, state: BrowserState, linkColor: Color, codeBackground: Color): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    markdownToken.findAll(source).forEach { match ->
        append(source.substring(cursor, match.range.first))
        val label = match.groups[1]?.value
        val rawUrl = match.groups[2]?.value
        when {
            label != null && rawUrl != null -> {
                if (isSafeWebUrl(rawUrl)) {
                    val link = LinkAnnotation.Clickable(
                        tag = rawUrl,
                        styles = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)),
                        linkInteractionListener = LinkInteractionListener { annotation ->
                            val target = (annotation as? LinkAnnotation.Clickable)?.tag
                            if (target != null && isSafeWebUrl(target)) state.openSourceFromChat(target)
                        },
                    )
                    withLink(link) { append(label) }
                } else {
                    append(match.value)
                }
            }
            match.groups[3] != null || match.groups[4] != null -> {
                val bold = match.groups[3]?.value ?: match.groups[4]?.value.orEmpty()
                pushStyle(SpanStyle(fontWeight = FontWeight.SemiBold))
                append(bold)
                pop()
            }
            match.groups[5] != null -> {
                pushStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBackground))
                append(match.groups[5]?.value.orEmpty())
                pop()
            }
        }
        cursor = match.range.last + 1
    }
    append(source.substring(cursor))
}

private fun isSafeWebUrl(value: String): Boolean {
    val uri = runCatching { java.net.URI(value) }.getOrNull() ?: return false
    val scheme = uri.scheme?.lowercase() ?: return false
    return scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null
}
