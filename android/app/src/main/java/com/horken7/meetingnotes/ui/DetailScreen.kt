package com.horken7.meetingnotes.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.PrimaryTabRow
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.horken7.meetingnotes.Meeting
import com.horken7.meetingnotes.MeetingService
import com.horken7.meetingnotes.Store
import com.horken7.meetingnotes.Work
import com.horken7.meetingnotes.core.Meta
import com.horken7.meetingnotes.core.Share
import com.horken7.meetingnotes.core.Transcript
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(id: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val version by Store.version.collectAsState()
    val processing by Work.processing.collectAsState()
    val recording by Work.recording.collectAsState()
    val queued by Work.queued.collectAsState()
    val meeting = remember(version, id) { Store.load(Store.folder(id)) }
    if (meeting == null) { onBack(); return }
    val notes = remember(version, id) { Store.readText(meeting.folder, "notes.md")?.let(Transcript::stripHeading) }
    val transcript = remember(version, id) { Store.readText(meeting.folder, "transcript.md")?.let(Transcript::stripHeading) }
    var tab by rememberSaveable { mutableStateOf(0) }
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var choosingShare by remember { mutableStateOf(false) }
    val isRecording = recording?.meetingId == id
    val busy = isRecording || id in queued
    val progress = processing?.takeIf { it.meetingId == id }

    var pendingSave by remember { mutableStateOf<String?>(null) }
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/markdown")) { uri: Uri? ->
        val text = pendingSave
        if (uri != null && text != null) {
            runCatching { context.contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) } }
                .onFailure { Work.message.value = "Couldn't save the file: ${it.message}" }
        }
        pendingSave = null
    }
    fun save(name: String, file: String) {
        val text = Store.readText(meeting.folder, file) ?: return
        pendingSave = text
        saver.launch("${meeting.title} - $name.md")
    }
    fun shareForNotes() {
        val text = Store.readText(meeting.folder, "transcript.md") ?: return
        shareText(context, "${meeting.title}: transcript", Share.transcriptForNotes(meeting.title, text))
    }
    fun shareNotes() = shareText(context, meeting.title, Store.readText(meeting.folder, "notes.md") ?: "")
    // Share…: the transcript with a request to write notes, so the user can pick the Claude app (or any other) and
    // have their own assistant write the notes; with notes already written, they choose which to share.
    fun share() = if (notes != null) choosingShare = true else shareForNotes()

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(meeting.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
            actions = {
                if (transcript != null) IconButton(onClick = { share() }) {
                    Icon(Icons.Default.Share, contentDescription = "Share")
                }
                IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, contentDescription = "More") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    val close = { menu = false }
                    MenuItem("Rename", close = close) { renaming = true }
                    MenuItem("Regenerate notes", !busy && transcript != null, close) { MeetingService.process(context, id, notesOnly = true) }
                    MenuItem("Redo transcript and notes", !busy && meeting.hasAudio, close) { MeetingService.process(context, id, notesOnly = false) }
                    HorizontalDivider()
                    MenuItem("Share…", transcript != null, close) { share() }
                    MenuItem("Share files (notes, transcript, audio)", !isRecording, close) { shareFiles(context, meeting) }
                    MenuItem("Save notes to Files or Drive", notes != null, close) { save("notes", "notes.md") }
                    MenuItem("Save transcript to Files or Drive", transcript != null, close) { save("transcript", "transcript.md") }
                    HorizontalDivider()
                    MenuItem("Delete", !busy, close) { deleting = true }
                }
            },
        )
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            when {
                isRecording -> InfoCard("Recording. Notes are written after you press Stop.")
                busy -> Card(Modifier.fillMaxWidth().padding(16.dp, 8.dp)) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(progress?.phase ?: "Waiting for another meeting to finish", style = MaterialTheme.typography.titleSmall)
                        progress?.fraction?.let { LinearProgressIndicator(progress = { it }, Modifier.fillMaxWidth()) }
                            ?: LinearProgressIndicator(Modifier.fillMaxWidth())
                        Text("This runs on the phone and can take a while for long meetings. You can lock the screen.",
                            style = MaterialTheme.typography.bodySmall)
                        if (progress != null) TextButton(onClick = { MeetingService.cancel(context) }) { Text("Stop") }
                    }
                }
                meeting.status == Meta.FAILED -> Card(Modifier.fillMaxWidth().padding(16.dp, 8.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                    Column(Modifier.padding(16.dp)) {
                        Text(meeting.meta.error ?: "This meeting wasn't finished.", color = MaterialTheme.colorScheme.onErrorContainer)
                        Row(Modifier.align(Alignment.End)) {
                            if (meeting.hasAudio) TextButton(onClick = { MeetingService.process(context, id, notesOnly = false) }) {
                                Text(if (transcript == null) "Retry" else "Redo transcript")
                            }
                            if (transcript != null) TextButton(onClick = { MeetingService.process(context, id, notesOnly = true) }) { Text("Retry notes") }
                        }
                    }
                }
            }
            PrimaryTabRow(selectedTabIndex = tab) {
                Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("Notes") })
                Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("Transcript") })
            }
            Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).navigationBarsPadding()) {
                if (tab == 0) {
                    if (notes != null) MarkdownText(notes)
                    else Placeholder(if (busy) "The notes appear here when they're ready." else "No notes yet.")
                } else {
                    if (transcript != null) SelectionContainer { Text(transcript, style = MaterialTheme.typography.bodyLarge) }
                    else Placeholder(if (busy) "The transcript appears here when it's ready." else "No transcript.")
                }
            }
        }
    }

    if (renaming) {
        var title by remember { mutableStateOf(meeting.title) }
        AlertDialog(
            onDismissRequest = { renaming = false },
            title = { Text("Rename meeting") },
            text = { OutlinedTextField(title, { title = it }, singleLine = true) },
            confirmButton = {
                TextButton(onClick = {
                    val t = title.trim()
                    if (t.isNotEmpty()) rename(meeting, t)
                    renaming = false
                }) { Text("Rename") }
            },
            dismissButton = { TextButton(onClick = { renaming = false }) { Text("Cancel") } },
        )
    }
    if (choosingShare) {
        AlertDialog(
            onDismissRequest = { choosingShare = false },
            title = { Text("Share") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    ShareChoice("Transcript, for an AI app to write notes",
                        "Starts with a request to write a summary, decisions and action items. Pick the Claude app, " +
                            "or another assistant, to use your own subscription.") { choosingShare = false; shareForNotes() }
                    ShareChoice("Notes", "The notes written on this phone.") { choosingShare = false; shareNotes() }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { choosingShare = false }) { Text("Cancel") } },
        )
    }
    if (deleting) {
        ConfirmDelete(meeting.title, onConfirm = { deleting = false; Store.delete(meeting.folder); onBack() }, onDismiss = { deleting = false })
    }

}

@Composable
private fun MenuItem(label: String, enabled: Boolean = true, close: () -> Unit, action: () -> Unit) {
    DropdownMenuItem(text = { Text(label) }, enabled = enabled, onClick = { close(); action() })
}

@Composable
private fun ShareChoice(title: String, detail: String, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall)
        Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun InfoCard(text: String) {
    Card(Modifier.fillMaxWidth().padding(16.dp, 8.dp)) { Text(text, Modifier.padding(16.dp)) }
}

@Composable
private fun Placeholder(text: String) {
    Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Renames like the Mac app: the title in meta.json and the files' headings; the folder keeps its name. */
private fun rename(m: Meeting, title: String) {
    Store.update(m.folder) { it.copy(title = title) }
    for ((file, heading) in listOf("notes.md" to "# $title", "transcript.md" to "# $title: transcript")) {
        val text = Store.readText(m.folder, file) ?: continue
        if (text.startsWith("# ")) Store.writeAtomic(File(m.folder, file), heading + "\n" + text.substringAfter('\n', ""))
    }
    Store.changed()
}

private fun shareText(context: Context, subject: String, text: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain")
        .putExtra(Intent.EXTRA_SUBJECT, subject).putExtra(Intent.EXTRA_TEXT, text)
    context.startActivity(Intent.createChooser(send, null))
}

private fun shareFiles(context: Context, m: Meeting) {
    val files = listOf("notes.md", "transcript.md", Store.AUDIO).map { File(m.folder, it) }.filter { it.exists() }
    if (files.isEmpty()) return
    val uris = ArrayList(files.map { FileProvider.getUriForFile(context, "${context.packageName}.files", it) })
    val send = Intent(Intent.ACTION_SEND_MULTIPLE).setType("*/*")
        .putExtra(Intent.EXTRA_SUBJECT, m.title)
        .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, null))
}
