package com.horken7.meetingnotes

import android.util.Log
import com.horken7.meetingnotes.core.AudioBlocks
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.LanguageVote
import com.horken7.meetingnotes.core.Meta
import com.horken7.meetingnotes.core.ModelFile
import com.horken7.meetingnotes.core.Segment
import com.horken7.meetingnotes.core.Summarizer
import com.horken7.meetingnotes.core.Transcript
import com.horken7.meetingnotes.core.Wav
import com.horken7.meetingnotes.llama.LlamaListener
import com.horken7.meetingnotes.llama.LlamaModel
import com.horken7.meetingnotes.whisper.WhisperModel
import java.io.File

class CancelledException : Exception("Stopped.")

/** Lets the user stop a long transcription or download; [onCancel] stops the native work right away. */
class CancelToken {
    @Volatile var cancelled = false
        private set
    @Volatile var onCancel: (() -> Unit)? = null

    fun cancel() { cancelled = true; onCancel?.invoke() }
    fun check() { if (cancelled) throw CancelledException() }
}

/** Transcribes a meeting with whisper.cpp and writes notes with llama.cpp, all on the phone. */
class Pipeline(
    private val settings: Settings,
    private val cancel: CancelToken,
    /** What's happening ("Transcribing"), and how far along, 0 to 1, when known. */
    private val report: (phase: String, fraction: Float?) -> Unit,
) {
    private val threads: Int = Runtime.getRuntime().availableProcessors().let { if (it >= 8) 4 else maxOf(2, it / 2) }

    fun run(folder: File, notesOnly: Boolean) {
        try {
            val transcriptFile = File(folder, "transcript.md")
            if (!notesOnly || !transcriptFile.exists()) transcribe(folder)
            // The transcript is saved, so the audio is no longer needed unless the user keeps it.
            if (!settings.keepAudio) Store.audioFiles(folder).forEach { it.delete() }
            writeNotes(folder)
            Store.update(folder) { it.copy(status = Meta.DONE, error = null) }
        } catch (e: CancelledException) {
            Store.update(folder) { it.copy(status = Meta.FAILED, error = "Stopped. Press Retry to continue.") }
        } catch (e: UserFacingException) {
            Store.update(folder) { it.copy(status = Meta.FAILED, error = e.message) }
        } catch (e: Throwable) {
            Log.e(TAG, "processing failed", e)
            Store.update(folder) { it.copy(status = Meta.FAILED, error = "Something went wrong: ${e.message ?: e.javaClass.simpleName}") }
        }
    }

    private fun transcribe(folder: File) {
        val audio = File(folder, Store.AUDIO)
        if (!audio.exists() || Wav.sampleCount(audio) == 0L) {
            throw UserFacingException("The audio for this meeting wasn't kept, so the transcript can't be redone.")
        }
        Store.update(folder) { it.copy(status = Meta.TRANSCRIBING, error = null) }
        if (!Models.cpuSupported) throw UserFacingException(Models.cpuMessage)
        Wav.repair(audio)

        for (m in Catalog.speechModels) ensure(m, "Downloading the speech model")   // only in builds without them
        val vad = Models.path(Catalog.vad)
        val total = Wav.sampleCount(audio)
        val rate = Wav.SAMPLE_RATE.toLong()
        val blocks = AudioBlocks.plan(total, target = 10 * 60 * rate, window = 15 * rate) { start, length ->
            Wav.rms(Wav.read(audio, start, length.toInt()))
        }

        // The built-in Whisper large-v3-turbo, or the optional models once downloaded: KB-Whisper for Swedish, and
        // Whisper small for other languages if the user chose speed.
        val fast = settings.fastSpeech && Models.isReady(Catalog.whisperFast)
        val swedish = Models.isReady(Catalog.whisperSwedish)
        var language = settings.language
        if (language == "auto") {
            report("Detecting the language", null)
            language = detectLanguage(audio, total, if (fast) Catalog.whisperFast else Catalog.whisperMultilingual) ?: "auto"
        }
        val speech = Catalog.speechModel(language, swedish, fast)
        Log.i(TAG, "transcribing in $language with ${speech.id}")
        report("Transcribing", 0f)
        val model = load(speech)
        val segments = ArrayList<Segment>()
        try {
            cancel.onCancel = { model.cancel() }
            blocks.forEachIndexed { i, block ->
                cancel.check()
                val samples = Wav.read(audio, block.first, (block.last - block.first + 1).toInt())
                val out = model.transcribe(samples, language, threads, vad) { pct ->
                    report("Transcribing", (i + pct / 100f) / blocks.size)
                } ?: run { cancel.check(); throw UserFacingException("Transcription failed. Press Retry to try again.") }
                // When detection was unsure, keep the language whisper heard first, so it doesn't switch midway.
                if (language == "auto") model.language?.let { language = it }
                val offset = block.first.toDouble() / rate
                out.forEach { segments.add(Segment(offset + it.startMs / 1000.0, it.text)) }
            }
        } finally {
            cancel.onCancel = null
            model.close()
        }

        val clean = Transcript.clean(segments)
        if (clean.isEmpty()) {
            throw UserFacingException("No speech was recognized. Check that the microphone isn't covered and the phone is near the people talking.")
        }
        val meta = Store.readMeta(folder) ?: Meta(title = folder.name)
        Store.writeAtomic(File(folder, "transcript.md"), Transcript.file(meta.title, clean))
        Store.update(folder) {
            it.copy(lang = language.takeIf { l -> l != "auto" }, duration = total.toDouble() / rate)
        }
    }

    private fun writeNotes(folder: File) {
        Store.update(folder) { it.copy(status = Meta.SUMMARIZING, error = null) }
        val transcript = Transcript.stripHeading(Store.readText(folder, "transcript.md") ?: "")
        val ram = settings.totalRamBytes
        val choice = settings.notesModel ?: throw UserFacingException(
            "This phone has ${Catalog.size(ram)} of memory, which isn't enough for the on-device notes model " +
                "(it needs about ${Catalog.size(Catalog.gemma1b.minRamBytes)}). The transcript is kept.")
        if (!Models.cpuSupported) throw UserFacingException(Models.cpuMessage)
        // The larger model once it's downloaded; until then (or offline) the built-in one.
        val use = if (Models.isReady(choice)) choice else Catalog.gemma1b
        ensure(use, "Downloading the notes model")
        report("Writing notes", null)

        val src = Models.source(use) ?: throw UserFacingException("The notes model is missing. Reinstall the app.")
        val model = LlamaModel.load(src.path, src.offset, CONTEXT, threads) ?: throw UserFacingException(
            "The notes model couldn't be loaded, probably because the phone ran out of memory. The transcript is kept: " +
                "close other apps and press Regenerate notes, or pick the smaller notes model in Settings.")
        val meta = Store.readMeta(folder) ?: Meta(title = folder.name)
        val notes = try {
            cancel.onCancel = { model.cancel() }
            var step = 0
            var steps = 1
            val summarizer = Summarizer(
                contextTokens = model.contextSize,
                generate = { system, user, max ->
                    cancel.check()
                    val listener = object : LlamaListener {
                        var chars = 0
                        override fun onPrompt(done: Int, total: Int) {
                            report("Writing notes", (step + 0.5f * done / total) / steps)
                        }
                        override fun onText(bytes: ByteArray) {
                            chars += bytes.size
                            // About 4 characters per token; the answer is rarely longer than the limit.
                            report("Writing notes", (step + 0.5f + 0.5f * minOf(1f, chars / (max * 4f))) / steps)
                        }
                    }
                    try {
                        model.generate(system, user, max, listener = listener)
                    } catch (e: IllegalArgumentException) {
                        throw UserFacingException("The transcript part was too long for the notes model. The transcript is kept.")
                    } ?: run { cancel.check(); throw UserFacingException("The notes model stopped unexpectedly. The transcript is kept; press Regenerate notes.") }
                },
                onStep = { done, total -> step = done; steps = total },
            )
            summarizer.summarize(meta.title, transcript, settings.customInstructions, meta.lang)
        } finally {
            cancel.onCancel = null
            model.close()
        }
        if (notes.isBlank()) throw UserFacingException("The notes model returned nothing. The transcript is kept; press Regenerate notes.")
        Store.writeAtomic(File(folder, "notes.md"), "# ${meta.title}\n\n$notes\n")
    }

    private fun load(m: ModelFile): WhisperModel {
        val src = Models.source(m) ?: throw UserFacingException("The speech model is missing. Reinstall the app.")
        return WhisperModel.load(src.path, src.offset, src.length)
            ?: throw UserFacingException("The speech model couldn't be loaded. Reinstall the app.")
    }

    /**
     * Guesses the language with a multilingual Whisper model on the three loudest 30-second stretches of the first
     * ten minutes, so a quiet start doesn't decide it. Null when it can't tell.
     */
    private fun detectLanguage(audio: File, total: Long, detector: ModelFile): String? {
        val window = 30L * Wav.SAMPLE_RATE
        if (total < Wav.SAMPLE_RATE) return null
        val searched = minOf(total, 10L * 60 * Wav.SAMPLE_RATE)
        val starts = (0 until maxOf(1, searched - window + 1) step window).toList()
            .sortedByDescending { Wav.rms(Wav.read(audio, it, minOf(window, total - it).toInt())) }
            .take(3)
        val model = load(detector)
        try {
            val guesses = starts.mapNotNull { start ->
                cancel.check()
                model.detectLanguage(Wav.read(audio, start, minOf(window, total - start).toInt()), threads)
            }
            Log.i(TAG, "language guesses: $guesses")
            return LanguageVote.pick(guesses)
        } finally {
            model.close()
        }
    }

    private fun ensure(m: ModelFile, phase: String) {
        if (Models.isReady(m)) return
        report(phase, 0f)
        Models.download(m, { cancel.cancelled }) { done, total -> report(phase, done.toFloat() / total) }
        cancel.check()
    }

    /** Downloads models ahead of the first meeting, from the setup card or Settings. */
    fun download(models: List<ModelFile>) {
        for (m in models) ensure(m, "Downloading ${m.label}")
    }

    companion object {
        private const val TAG = "Pipeline"
        /** Tokens of context for the notes model: enough for about 20 minutes of speech per part. */
        const val CONTEXT = 8192
    }
}
