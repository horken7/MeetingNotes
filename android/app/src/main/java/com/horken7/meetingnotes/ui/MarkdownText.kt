package com.horken7.meetingnotes.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.horken7.meetingnotes.core.Markdown

/** Renders the notes' Markdown: headings, lists, paragraphs and inline emphasis. */
@Composable
fun MarkdownText(markdown: String, modifier: Modifier = Modifier) {
    val blocks = remember(markdown) { Markdown.parse(markdown) }
    val type = MaterialTheme.typography
    SelectionContainer(modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            blocks.forEachIndexed { i, block ->
                when (block) {
                    is Markdown.Heading -> {
                        if (i > 0) Spacer(Modifier.height(10.dp))
                        val style = when (block.level) { 1 -> type.headlineSmall; 2 -> type.titleLarge; else -> type.titleMedium }
                        Text(annotated(block.text), style = style, fontWeight = FontWeight.SemiBold)
                    }
                    is Markdown.Item -> Row(Modifier.padding(start = (block.depth * 16).dp)) {
                        Text(block.marker, style = type.bodyLarge, modifier = Modifier.width(if (block.marker == "•") 16.dp else 24.dp))
                        Text(annotated(block.text), style = type.bodyLarge)
                    }
                    is Markdown.Paragraph -> Text(annotated(block.text), style = type.bodyLarge)
                    Markdown.Rule -> HorizontalDivider(Modifier.padding(vertical = 8.dp))
                }
            }
        }
    }
}

private fun annotated(spans: List<Markdown.Span>): AnnotatedString = buildAnnotatedString {
    for (s in spans) {
        withStyle(SpanStyle(
            fontWeight = if (s.bold) FontWeight.Bold else null,
            fontStyle = if (s.italic) FontStyle.Italic else null,
            fontFamily = if (s.code) FontFamily.Monospace else null,
        )) { append(s.text) }
    }
}
