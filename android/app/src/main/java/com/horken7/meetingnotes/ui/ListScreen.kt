package com.horken7.meetingnotes.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.horken7.meetingnotes.Meeting
import com.horken7.meetingnotes.MeetingService
import com.horken7.meetingnotes.Models
import com.horken7.meetingnotes.Settings
import com.horken7.meetingnotes.Store
import com.horken7.meetingnotes.Work
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.Meta
import com.horken7.meetingnotes.core.TextSearch
import com.horken7.meetingnotes.core.formatDuration
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

val Red = Color(0xFFE5484D)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListScreen(settings: Settings, onOpen: (String) -> Unit, onSettings: () -> Unit, onRecord: () -> Unit) {
    val version by Store.version.collectAsState()
    val processing by Work.processing.collectAsState()
    val recording by Work.recording.collectAsState()
    val message by Work.message.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    val meetings = remember(version) { Store.loadAll() }
    val searchText = remember(version) { HashMap<String, String>() }
    val shown = if (query.isBlank()) meetings else meetings.filter { m ->
        val text = searchText.getOrPut(m.id) {
            listOfNotNull(m.title, Store.readText(m.folder, "notes.md"), Store.readText(m.folder, "transcript.md")).joinToString("\n")
        }
        TextSearch.matches(query, text)
    }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Meetings") }, actions = {
                IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, contentDescription = "Settings") }
            })
        },
        bottomBar = { RecordPanel(recording, onRecord) },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            message?.let { Banner(it, onDismiss = { Work.message.value = null }) }
            SetupCard(settings, processing, version)
            if (meetings.isNotEmpty()) {
                OutlinedTextField(
                    value = query, onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    placeholder = { Text("Search titles, notes and transcripts") },
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                    trailingIcon = {
                        if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Clear, contentDescription = "Clear search") }
                    },
                    singleLine = true,
                )
            }
            if (meetings.isEmpty()) {
                Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                    Text("Put the phone on the table and press Start recording when the meeting begins.\n\n" +
                        "Everything stays on this phone: the transcript and the notes are made here, without internet.",
                        style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(shown, key = { it.id }) { m ->
                        MeetingRow(m, processing?.takeIf { it.meetingId == m.id }?.fraction, recording?.meetingId == m.id) { onOpen(m.id) }
                        HorizontalDivider()
                    }
                    if (shown.isEmpty()) item {
                        Text("No meetings match \"$query\".", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
private fun MeetingRow(m: Meeting, fraction: Float?, isRecording: Boolean, onClick: () -> Unit) {
    val date = remember(m.created) {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .format(m.created.atZone(ZoneId.systemDefault()))
    }
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(m.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Row(verticalAlignment = Alignment.CenterVertically) {
            val duration = m.meta.duration?.let { " · ${formatDuration(it)}" } ?: ""
            Text("$date$duration", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            StatusLabel(if (isRecording) Meta.RECORDING else m.status, fraction)
        }
    }
}

@Composable
fun StatusLabel(status: String, fraction: Float?) {
    val pct = fraction?.let { " ${(it * 100).toInt()}%" } ?: ""
    val (text, color) = when (status) {
        Meta.RECORDING -> "Recording" to Red
        Meta.TRANSCRIBING -> "Transcribing$pct" to MaterialTheme.colorScheme.primary
        Meta.SUMMARIZING -> "Writing notes$pct" to MaterialTheme.colorScheme.primary
        Meta.FAILED -> "Needs attention" to MaterialTheme.colorScheme.error
        else -> return
    }
    Text(text, style = MaterialTheme.typography.labelMedium, color = color)
}

@Composable
fun Banner(text: String, onDismiss: () -> Unit) {
    Card(Modifier.fillMaxWidth().padding(16.dp, 8.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
        Column(Modifier.padding(16.dp)) {
            Text(text, color = MaterialTheme.colorScheme.onErrorContainer)
            TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) { Text("OK") }
        }
    }
}

/**
 * Shown while a model the next meeting needs isn't on the phone: the larger notes model the user picked, or every
 * model in a build made without them built in.
 */
@Composable
private fun SetupCard(settings: Settings, processing: com.horken7.meetingnotes.ProcessingState?, version: Int) {
    val context = LocalContext.current
    val needed = remember(version, processing) {
        (Catalog.speechModels + listOfNotNull(settings.notesModel)).filterNot { Models.isReady(it) }
    }
    if (needed.isEmpty()) return
    val downloading = processing != null && processing.meetingId == null
    Card(Modifier.fillMaxWidth().padding(16.dp, 8.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val total = needed.sumOf { it.bytes }
            Text(if (needed.size == 1) needed[0].label else "Speech and notes models", style = MaterialTheme.typography.titleMedium)
            Text("Download once (${Catalog.size(total)}), Wi-Fi is best. Until then the built-in models are used. " +
                "Nothing about your meetings leaves the phone.",
                style = MaterialTheme.typography.bodyMedium)
            if (settings.notesModel == null) {
                Text("This phone doesn't have enough memory for the notes model, so you'll get transcripts without notes.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
            }
            if (downloading) {
                Text(processing!!.phase, style = MaterialTheme.typography.bodySmall)
                processing.fraction?.let { LinearProgressIndicator(progress = { it }, Modifier.fillMaxWidth()) }
                    ?: LinearProgressIndicator(Modifier.fillMaxWidth())
                TextButton(onClick = { MeetingService.cancel(context) }) { Text("Stop download") }
            } else {
                Button(onClick = { MeetingService.download(context, needed.map { it.id }) }) { Text("Download (${Catalog.size(total)})") }
            }
        }
    }
}

@Composable
private fun RecordPanel(recording: com.horken7.meetingnotes.RecordingState?, onRecord: () -> Unit) {
    val context = LocalContext.current
    Surface(tonalElevation = 3.dp) {
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (recording != null) {
                Text(formatDuration(recording.elapsedMs / 1000.0), fontSize = 40.sp, fontWeight = FontWeight.Light)
                val level by animateFloatAsState(recording.level, label = "level")
                LinearProgressIndicator(progress = { level }, Modifier.fillMaxWidth(0.7f).height(6.dp).clip(RoundedCornerShape(3.dp)),
                    color = if (level > 0.9f) Red else MaterialTheme.colorScheme.primary)
                if (recording.silenced) {
                    Text("Paused: another app, such as a phone call, is using the microphone. Recording continues when it's free.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
                BigButton("Stop recording", square = true) { MeetingService.stop(context) }
                Text("Keeps recording with the screen off.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                BigButton("Start recording", square = false, onClick = onRecord)
            }
        }
    }
}

@Composable
private fun BigButton(label: String, square: Boolean, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clip(RoundedCornerShape(16.dp)).clickable(onClick = onClick).padding(8.dp)
            .semantics { contentDescription = label }) {
        Box(Modifier.size(76.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
            Box(Modifier.size(if (square) 30.dp else 56.dp).clip(if (square) RoundedCornerShape(6.dp) else CircleShape).background(Red))
        }
        Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 6.dp))
    }
}
