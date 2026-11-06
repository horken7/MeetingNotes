package com.horken7.meetingnotes.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.horken7.meetingnotes.MeetingService
import com.horken7.meetingnotes.Models
import com.horken7.meetingnotes.Settings
import com.horken7.meetingnotes.Store
import com.horken7.meetingnotes.Work
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.ModelFile
import com.horken7.meetingnotes.core.Prompts

private val languages = listOf(
    "auto" to "Automatic", "sv" to "Swedish", "da" to "Danish", "en" to "English", "no" to "Norwegian",
    "fi" to "Finnish", "de" to "German", "fr" to "French", "es" to "Spanish", "nl" to "Dutch",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(settings: Settings, onBack: () -> Unit) {
    val context = LocalContext.current
    val processing by Work.processing.collectAsState()
    val version by Store.version.collectAsState()
    var refresh by remember { mutableIntStateOf(0) }
    // Re-read files and settings when downloads finish or something is deleted.
    val tick = Triple(version, processing?.phase, refresh)

    Scaffold(topBar = {
        TopAppBar(title = { Text("Settings") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {

            Section("Language spoken in meetings")
            var language by remember { mutableStateOf(settings.language) }
            languages.forEach { (code, name) ->
                Choice(name, null, language == code) { language = code; settings.language = code }
            }

            HorizontalDivider()
            Section("Speech recognition")
            var whisper by remember { mutableStateOf(settings.whisperChoice) }
            Catalog.whisperModels.forEach { m ->
                ModelChoice(m, whisper == m.id, tick, onSelect = { whisper = m.id; settings.whisperChoice = m.id },
                    onDelete = { Models.delete(m); refresh++ })
            }

            HorizontalDivider()
            Section("Notes model")
            val ram = settings.totalRamBytes
            val auto = Catalog.defaultNotesModel(ram)
            Text("This phone has ${Catalog.size(ram)} of memory." +
                (auto?.let { " Automatic uses ${it.label}." } ?: " That's not enough for a notes model; you'll get transcripts only."),
                style = MaterialTheme.typography.bodySmall)
            var notesChoice by remember { mutableStateOf(settings.notesChoice) }
            Choice("Automatic", "Picks the best model this phone can run.", notesChoice == "auto") { notesChoice = "auto"; settings.notesChoice = "auto" }
            Catalog.notesModels.forEach { m ->
                val tooBig = ram < m.minRamBytes
                ModelChoice(m, notesChoice == m.id, tick, warning = if (tooBig) "Probably too large for this phone." else null,
                    onSelect = { notesChoice = m.id; settings.notesChoice = m.id }, onDelete = { Models.delete(m); refresh++ })
            }
            Text("Gemma 3 is made by Google and used under the Gemma Terms of Use (ai.google.dev/gemma/terms). " +
                "Speech recognition is OpenAI's Whisper (MIT licence) running in whisper.cpp.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            HorizontalDivider()
            Section("Notes instructions")
            Text("How the notes are written. The default asks for a summary, decisions, action items, open questions and key points, in the meeting's language.",
                style = MaterialTheme.typography.bodySmall)
            var instructions by remember { mutableStateOf(Prompts.instructions(settings.customInstructions)) }
            OutlinedTextField(instructions, { instructions = it; settings.customInstructions = it },
                Modifier.fillMaxWidth().heightIn(min = 160.dp))
            TextButton(onClick = { instructions = Prompts.defaultInstructions; settings.customInstructions = "" }) { Text("Reset to default") }

            HorizontalDivider()
            var keep by remember { mutableStateOf(settings.keepAudio) }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Keep audio recordings", style = MaterialTheme.typography.bodyLarge)
                    Text("Needed to redo a transcript. About 115 MB per hour.", style = MaterialTheme.typography.bodySmall)
                }
                Switch(keep, { keep = it; settings.keepAudio = it })
            }

            HorizontalDivider()
            Text("Everything happens on this phone: recordings, transcripts and notes never leave it unless you share them. " +
                "The internet is only used once, to download the models.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            processing?.takeIf { it.meetingId == null }?.let { p ->
                Text(p.phase, style = MaterialTheme.typography.bodySmall)
                p.fraction?.let { LinearProgressIndicator(progress = { it }, Modifier.fillMaxWidth()) }
                TextButton(onClick = { MeetingService.cancel(context) }) { Text("Stop download") }
            }
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
}

@Composable
private fun Choice(label: String, detail: String?, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onClick)
        Column {
            Text(label, style = MaterialTheme.typography.bodyLarge)
            detail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun ModelChoice(m: ModelFile, selected: Boolean, tick: Any, warning: String? = null, onSelect: () -> Unit, onDelete: () -> Unit) {
    val context = LocalContext.current
    val ready = remember(tick) { Models.isReady(m) }
    Row(Modifier.fillMaxWidth().clickable(onClick = onSelect), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onSelect)
        Column(Modifier.weight(1f)) {
            Text("${m.label} · ${Catalog.size(m.bytes)}", style = MaterialTheme.typography.bodyLarge)
            Text(m.description, style = MaterialTheme.typography.bodySmall)
            warning?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        }
        if (ready) TextButton(onClick = onDelete) { Text("Delete") }
        else OutlinedButton(onClick = { MeetingService.download(context, listOf(m.id)) }) { Text("Download") }
    }
}
