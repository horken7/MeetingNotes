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
import androidx.compose.material3.AlertDialog
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
            Text("Built in: ${Catalog.whisperSwedish.label} for Swedish, and ${Catalog.whisperMultilingual.label} " +
                "for Danish, English and other languages. With Automatic, the language is detected first.",
                style = MaterialTheme.typography.bodyMedium)
            Text("Other languages than Swedish", style = MaterialTheme.typography.bodyLarge)
            var fast by remember { mutableStateOf(settings.fastSpeech) }
            Choice("Accurate (built in)", "Whisper large-v3-turbo. Takes about as long as the meeting on a recent phone.", !fast) {
                fast = false; settings.fastSpeech = false
            }
            val small = Catalog.whisperFast
            ModelChoice(small, fast, tick,
                onSelect = {
                    fast = true; settings.fastSpeech = true
                    if (!Models.isReady(small)) MeetingService.download(context, listOf(small.id))
                },
                onDelete = { Models.delete(small); fast = false; settings.fastSpeech = false; refresh++ })

            HorizontalDivider()
            Section("Notes model")
            val ram = settings.totalRamBytes
            Text("This phone has ${Catalog.size(ram)} of memory." +
                (if (ram < Catalog.gemma1b.minRamBytes) " That's probably not enough for a notes model; you may get transcripts only." else ""),
                style = MaterialTheme.typography.bodySmall)
            var notesChoice by remember { mutableStateOf(if (settings.notesChoice == Catalog.gemma4b.id) Catalog.gemma4b.id else "auto") }
            Choice(Catalog.gemma1b.label, Catalog.gemma1b.description, notesChoice == "auto") {
                notesChoice = "auto"; settings.notesChoice = "auto"
            }
            val big = Catalog.gemma4b
            ModelChoice(big, notesChoice == big.id, tick,
                warning = if (ram < big.minRamBytes) "Probably too large for this phone." else null,
                onSelect = {
                    notesChoice = big.id; settings.notesChoice = big.id
                    if (!Models.isReady(big)) MeetingService.download(context, listOf(big.id))
                },
                onDelete = { Models.delete(big); notesChoice = "auto"; settings.notesChoice = "auto"; refresh++ })
            Text("Until ${big.label.substringBefore(" (")} is downloaded, notes are written with the built-in model.",
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
                    Text("When off, the audio is deleted as soon as the transcript is ready. Keep it to redo a transcript (about 115 MB per hour).", style = MaterialTheme.typography.bodySmall)
                }
                Switch(keep, { keep = it; settings.keepAudio = it })
            }

            HorizontalDivider()
            Text("Everything happens on this phone: recordings, transcripts and notes never leave it unless you share them. " +
                "The models are built into the app; the internet is only used if you download one of the optional models.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            processing?.takeIf { it.meetingId == null }?.let { p ->
                Text(p.phase, style = MaterialTheme.typography.bodySmall)
                p.fraction?.let { LinearProgressIndicator(progress = { it }, Modifier.fillMaxWidth()) }
                TextButton(onClick = { MeetingService.cancel(context) }) { Text("Stop download") }
            }

            HorizontalDivider()
            Section("Licences")
            Text("Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms. " +
                "By using the app you agree not to use Gemma for the restricted uses in Section 3.2 of those terms " +
                "(the Gemma Prohibited Use Policy) or against the law.",
                style = MaterialTheme.typography.bodySmall)
            var legal by remember { mutableStateOf<Pair<String, String>?>(null) }
            Row {
                TextButton(onClick = { legal = "Gemma Terms of Use" to "legal/gemma-terms-of-use.txt" }) { Text("Gemma Terms of Use") }
                TextButton(onClick = { legal = "Gemma Prohibited Use Policy" to "legal/gemma-prohibited-use-policy.txt" }) { Text("Prohibited uses") }
            }
            Text("KB-Whisper: National Library of Sweden (KBLab), Apache License 2.0. Whisper: OpenAI, MIT License. " +
                "Silero VAD: MIT License. whisper.cpp and llama.cpp: The ggml authors, MIT License.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            legal?.let { (title, asset) ->
                val text = remember(asset) { context.assets.open(asset).bufferedReader().use { it.readText() } }
                AlertDialog(
                    onDismissRequest = { legal = null },
                    title = { Text(title) },
                    text = { Text(text, Modifier.verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall) },
                    confirmButton = { TextButton(onClick = { legal = null }) { Text("Close") } },
                )
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
