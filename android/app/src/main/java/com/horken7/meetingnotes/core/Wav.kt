package com.horken7.meetingnotes.core

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/** 16-bit PCM mono WAV files, written while recording and read back for whisper. */
object Wav {
    const val SAMPLE_RATE = 16_000
    const val HEADER = 44

    fun header(dataBytes: Long, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val data = dataBytes.coerceIn(0, 0xFFFF_FFFFL - 36).toInt()
        return ByteBuffer.allocate(HEADER).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + data); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1)
            putInt(sampleRate); putInt(sampleRate * 2); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(data)
        }.array()
    }

    /** Rewrites the sizes in the header from the file length, e.g. after the app was killed mid-recording. */
    fun repair(file: File, sampleRate: Int = SAMPLE_RATE) {
        if (!file.exists() || file.length() < HEADER) return
        RandomAccessFile(file, "rw").use { raf ->
            var data = raf.length() - HEADER
            if (data % 2 != 0L) { raf.setLength(raf.length() - 1); data-- }
            raf.seek(0)
            raf.write(header(data, sampleRate))
        }
    }

    /** Samples in the file, from its length (the header may be stale). */
    fun sampleCount(file: File): Long = maxOf(0, file.length() - HEADER) / 2

    fun durationSeconds(file: File): Double = sampleCount(file).toDouble() / SAMPLE_RATE

    /** Reads [count] samples from sample [start] as floats in [-1, 1]. */
    fun read(file: File, start: Long, count: Int): FloatArray {
        RandomAccessFile(file, "r").use { raf ->
            val available = ((raf.length() - HEADER) / 2 - start).coerceIn(0, count.toLong()).toInt()
            val bytes = ByteArray(available * 2)
            raf.seek(HEADER + start * 2)
            raf.readFully(bytes)
            return toFloats(bytes, available)
        }
    }

    fun toFloats(bytes: ByteArray, samples: Int = bytes.size / 2): FloatArray {
        val shorts = ByteBuffer.wrap(bytes, 0, samples * 2).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        return FloatArray(samples) { shorts.get(it) / 32768f }
    }

    /** Little-endian bytes of 16-bit samples. */
    fun toBytes(samples: ShortArray, count: Int = samples.size): ByteArray {
        val buf = ByteBuffer.allocate(count * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until count) buf.putShort(samples[i])
        return buf.array()
    }

    /** Root mean square of the samples, 0 to 1. */
    fun rms(samples: ShortArray, count: Int = samples.size): Double {
        if (count == 0) return 0.0
        var sum = 0.0
        for (i in 0 until count) { val v = samples[i] / 32768.0; sum += v * v }
        return sqrt(sum / count)
    }

    fun rms(samples: FloatArray): Double {
        if (samples.isEmpty()) return 0.0
        var sum = 0.0
        for (v in samples) sum += v * v
        return sqrt(sum / samples.size)
    }

    /** A meter level 0 to 1 from an RMS value: -60 dBFS and below is 0, 0 dBFS is 1. */
    fun meterLevel(rms: Double): Float {
        if (rms <= 0.0) return 0f
        val db = 20 * kotlin.math.log10(rms)
        return ((db + 60) / 60).toFloat().coerceIn(0f, 1f)
    }

    /** Averages each 3 samples into 1: 48 kHz to 16 kHz for microphones that won't record at 16 kHz. */
    fun downsample3(samples: ShortArray, count: Int): ShortArray {
        val out = ShortArray(count / 3)
        for (i in out.indices) out[i] = ((samples[3 * i] + samples[3 * i + 1] + samples[3 * i + 2]) / 3).toShort()
        return out
    }
}

/**
 * Plans where to cut a long recording into blocks for whisper: about every [target] samples, at the quietest
 * 100 ms within the last [window] samples before that point, so words are rarely cut in half.
 */
object AudioBlocks {
    fun plan(total: Long, target: Long, window: Long, step: Long = 1600, energy: (start: Long, length: Long) -> Double): List<LongRange> {
        require(target > window && window >= step)
        val blocks = ArrayList<LongRange>()
        var start = 0L
        while (total - start > target + window / 2) {
            val ideal = start + target
            var best = ideal
            var bestEnergy = Double.MAX_VALUE
            var at = ideal - window
            while (at + step <= ideal) {
                val e = energy(at, step)
                if (e < bestEnergy) { bestEnergy = e; best = at + step / 2 }
                at += step
            }
            blocks.add(start until best)
            start = best
        }
        if (total > start) blocks.add(start until total)
        return blocks
    }
}
