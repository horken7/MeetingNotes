package com.horken7.meetingnotes

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.horken7.meetingnotes.core.Wav
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile

/**
 * Records the microphone to a 16 kHz mono WAV file on its own thread. The header is rewritten every few seconds,
 * so if the app is killed the file is still valid up to that point (and [Wav.repair] fixes the rest).
 */
class Recorder(
    context: Context,
    private val file: File,
    private val onUpdate: (elapsedMs: Long, level: Float, silenced: Boolean) -> Unit,
    /** Called on the recording thread when recording ends by itself; null error means it was stopped normally. */
    private val onEnd: (error: String?) -> Unit,
) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    @Volatile private var running = false
    @Volatile private var silenced = false
    private var thread: Thread? = null
    private var record: AudioRecord? = null
    private var rate = Wav.SAMPLE_RATE
    private var startedAt = 0L
    private var samplesWritten = 0L

    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
            val session = record?.audioSessionId ?: return
            // Another app (usually a phone call) took the microphone: Android feeds us silence until it's free.
            silenced = configs.firstOrNull { it.clientAudioSessionId == session }?.isClientSilenced ?: false
        }
    }

    val elapsedMs: Long get() = samplesWritten * 1000 / Wav.SAMPLE_RATE

    /** Starts recording; throws [UserFacingException] when the microphone can't be opened. */
    fun start() {
        record = open()
        file.parentFile?.mkdirs()
        FileOutputStream(file).use { it.write(Wav.header(0)) }
        running = true
        startedAt = SystemClock.elapsedRealtime()
        audioManager.registerAudioRecordingCallback(callback, Handler(Looper.getMainLooper()))
        thread = Thread({ loop() }, "Recorder").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    /** Stops and finishes the file. Blocks until the recording thread is done. */
    fun stop() {
        running = false
        thread?.join(5000)
    }

    @SuppressLint("MissingPermission")
    private fun open(): AudioRecord {
        for (r in intArrayOf(16_000, 48_000)) {
            val min = AudioRecord.getMinBufferSize(r, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val rec = AudioRecord(MediaRecorder.AudioSource.MIC, r, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(min * 4, r))
            if (rec.state == AudioRecord.STATE_INITIALIZED) {
                rate = r
                rec.startRecording()
                if (rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) return rec
            }
            rec.release()
        }
        throw UserFacingException("The microphone couldn't be opened. If another app is recording, stop it and try again.")
    }

    private fun loop() {
        var error: String? = null
        val chunk = rate / 10   // 100 ms
        val buf = ShortArray(chunk)
        var lastHeader = SystemClock.elapsedRealtime()
        var reopenAttempts = 0
        val out = BufferedOutputStream(FileOutputStream(file, true), 64 * 1024)
        try {
            while (running) {
                val rec = record ?: break
                val n = rec.read(buf, 0, buf.size)
                if (n < 0) {
                    // The audio server restarted or the mic went away: try to reopen it, keep what we have.
                    Log.w(TAG, "AudioRecord.read returned $n")
                    rec.release()
                    record = null
                    if (++reopenAttempts > 3) { error = "The microphone stopped working, so recording ended. The audio until then is kept."; break }
                    Thread.sleep(500)
                    record = runCatching { open() }.getOrNull()
                    continue
                }
                if (n == 0) continue
                val samples = if (rate == 48_000) Wav.downsample3(buf, n) else buf.copyOf(n)
                out.write(Wav.toBytes(samples))
                samplesWritten += samples.size
                onUpdate(elapsedMs, if (silenced) 0f else Wav.meterLevel(Wav.rms(samples)), silenced)

                val now = SystemClock.elapsedRealtime()
                if (now - lastHeader > 5000) {
                    out.flush()
                    writeHeader()
                    lastHeader = now
                    if ((file.parentFile?.usableSpace ?: Long.MAX_VALUE) < 50_000_000) {
                        error = "The phone is almost out of storage, so recording stopped. The audio until then is kept."
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "recording failed", e)
            error = "Recording stopped because of an error (${e.message}). The audio until then is kept."
        } finally {
            runCatching { out.flush(); out.close() }
            runCatching { record?.stop() }
            record?.release()
            record = null
            runCatching { audioManager.unregisterAudioRecordingCallback(callback) }
            writeHeader()
        }
        running = false
        onEnd(error)
    }

    private fun writeHeader() {
        runCatching {
            RandomAccessFile(file, "rw").use { raf ->
                raf.seek(0)
                raf.write(Wav.header(raf.length() - Wav.HEADER))
            }
        }
    }

    companion object { private const val TAG = "Recorder" }
}
