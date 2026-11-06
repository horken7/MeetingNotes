package com.horken7.meetingnotes.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * A meeting's `meta.json`, with the same keys as the Mac app's `Meta` so folders can be copied between them.
 * Properties are in alphabetical order, so the file comes out with sorted keys like the Mac writes it.
 */
@Serializable
data class Meta(
    val app: String? = null,
    /** When the audio files were deleted, ISO 8601. */
    val audioArchived: String? = null,
    /** ISO 8601 in UTC without fractions ("2026-11-06T09:30:00Z"), which Swift's `.iso8601` strategy reads. */
    val created: String? = null,
    /** Seconds of audio. */
    val duration: Double? = null,
    val error: String? = null,
    /** Whisper language code, e.g. "sv". */
    val lang: String? = null,
    val offsets: Map<String, Double>? = null,
    /** recording, transcribing, summarizing, done or failed. */
    val status: String? = null,
    val title: String,
) {
    val createdInstant: Instant? get() = created?.let { runCatching { Instant.parse(it) }.getOrNull() }

    companion object {
        const val RECORDING = "recording"
        const val TRANSCRIBING = "transcribing"
        const val SUMMARIZING = "summarizing"
        const val DONE = "done"
        const val FAILED = "failed"

        @OptIn(ExperimentalSerializationApi::class)
        private val json = Json {
            prettyPrint = true
            prettyPrintIndent = "  "
            explicitNulls = false
            ignoreUnknownKeys = true
            encodeDefaults = false
        }

        fun parse(text: String): Meta? = runCatching { json.decodeFromString(serializer(), text) }.getOrNull()

        fun timestamp(instant: Instant): String = instant.truncatedTo(ChronoUnit.SECONDS).toString()
    }

    fun encode(): String = json.encodeToString(serializer(), this) + "\n"

    val isBusy: Boolean get() = status in setOf(RECORDING, TRANSCRIBING, SUMMARIZING)
}
