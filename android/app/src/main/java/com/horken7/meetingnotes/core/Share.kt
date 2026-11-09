package com.horken7.meetingnotes.core

/**
 * The text shared to another app (for example the Claude app, so the user's own AI assistant writes the notes):
 * a short request, then the transcript.
 */
object Share {
    const val PROMPT = "Write meeting notes for this transcript."

    /**
     * [transcriptMarkdown] is transcript.md as saved; its "# Title: transcript" heading is replaced by the title.
     * [customInstructions] are Settings > Notes instructions (blank means the default), the same the phone uses.
     */
    fun transcriptForNotes(title: String, transcriptMarkdown: String, customInstructions: String? = null): String =
        "$PROMPT\n\n${Prompts.instructions(customInstructions)}\n\nMeeting: $title\n\n${Transcript.stripHeading(transcriptMarkdown)}\n"

    /** The transcript alone, with no request for an AI: a "# Title: transcript" heading, then what was said. */
    fun transcript(title: String, transcriptMarkdown: String): String =
        "# $title: transcript\n\n${Transcript.stripHeading(transcriptMarkdown)}\n"
}
