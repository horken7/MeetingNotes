package com.horken7.meetingnotes

import android.app.ActivityManager
import android.content.Context
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.Folders
import com.horken7.meetingnotes.core.Meta
import com.horken7.meetingnotes.core.ModelFile
import com.horken7.meetingnotes.core.Prompts
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

/** A meeting folder and its meta.json. */
data class Meeting(val folder: File, val meta: Meta, val created: Instant, val hasAudio: Boolean) {
    val id: String get() = folder.name
    val title: String get() = meta.title
    val status: String get() = meta.status ?: if (File(folder, "notes.md").exists()) Meta.DONE else Meta.FAILED
    val isBusy: Boolean get() = status in setOf(Meta.RECORDING, Meta.TRANSCRIBING, Meta.SUMMARIZING)
}

/** The meetings on disk: one folder per meeting in the app's private storage, laid out like the Mac app's. */
object Store {
    const val AUDIO = "audio.wav"

    lateinit var root: File
        private set

    /** Bumped on every change, so screens reload. */
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version

    fun init(context: Context) {
        root = File(context.filesDir, "Meetings").apply { mkdirs() }
    }

    fun changed() { _version.value++ }

    fun folder(id: String): File = File(root, id)

    fun readMeta(folder: File): Meta? =
        File(folder, "meta.json").takeIf { it.exists() }?.let { runCatching { Meta.parse(it.readText()) }.getOrNull() }

    fun writeMeta(folder: File, meta: Meta) {
        writeAtomic(File(folder, "meta.json"), meta.encode())
    }

    @Synchronized
    fun update(folder: File, change: (Meta) -> Meta) {
        val current = readMeta(folder) ?: Meta(title = folder.name)
        writeMeta(folder, change(current))
        changed()
    }

    fun writeAtomic(file: File, text: String) {
        val tmp = File(file.parentFile, ".${file.name}.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) { file.writeText(text); tmp.delete() }
    }

    fun loadAll(): List<Meeting> =
        (root.listFiles() ?: emptyArray()).filter { it.isDirectory }.mapNotNull { load(it) }.sortedByDescending { it.created }

    fun load(folder: File): Meeting? {
        val meta = readMeta(folder) ?: return null
        val created = meta.createdInstant ?: Instant.ofEpochMilli(folder.lastModified())
        return Meeting(folder, meta, created, audioFiles(folder).isNotEmpty())
    }

    fun audioFiles(folder: File): List<File> =
        (folder.listFiles() ?: emptyArray()).filter { it.extension.lowercase() in setOf("wav", "caf", "m4a") }

    fun newMeeting(title: String, now: Instant = Instant.now()): File {
        val base = Folders.name(title, LocalDateTime.ofInstant(now, ZoneId.systemDefault()))
        val dir = File(root, Folders.unique(base) { File(root, it).exists() })
        dir.mkdirs()
        writeMeta(dir, Meta(title = title, created = Meta.timestamp(now), status = Meta.RECORDING))
        changed()
        return dir
    }

    fun readText(folder: File, name: String): String? = File(folder, name).takeIf { it.exists() }?.readText()

    fun delete(folder: File) {
        folder.deleteRecursively()
        changed()
    }
}

/** Settings, kept in SharedPreferences. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val totalRam: Long = (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
        .let { am -> ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }.totalMem }

    /** "auto" or a whisper language code. */
    var language: String
        get() = prefs.getString("language", "auto") ?: "auto"
        set(v) = prefs.edit().putString("language", v).apply()

    var whisperChoice: String
        get() = prefs.getString("whisperModel", Catalog.whisperSmall.id) ?: Catalog.whisperSmall.id
        set(v) = prefs.edit().putString("whisperModel", v).apply()

    /** "auto" picks by the phone's memory. */
    var notesChoice: String
        get() = prefs.getString("notesModel", "auto") ?: "auto"
        set(v) = prefs.edit().putString("notesModel", v).apply()

    /** Blank means the default instructions. */
    var customInstructions: String
        get() = prefs.getString("notesInstructions", "") ?: ""
        set(v) = prefs.edit().putString("notesInstructions", if (v.trim() == Prompts.defaultInstructions) "" else v).apply()

    var keepAudio: Boolean
        get() = prefs.getBoolean("keepAudio", false)
        set(v) = prefs.edit().putBoolean("keepAudio", v).apply()

    val totalRamBytes: Long get() = totalRam

    val whisperModel: ModelFile get() = Catalog.whisperModel(whisperChoice)
    val notesModel: ModelFile? get() = Catalog.notesModel(notesChoice, totalRam)
}
