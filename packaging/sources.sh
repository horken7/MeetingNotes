# The Swift sources of the Mac app, for `source`-ing in the build scripts (with ROOT set to the repository):
# src/*.swift, plus the notes logic shared with the iPhone app (prompts, grounding rules, splitting long
# meetings into parts, tidying), which the built-in notes model uses.
SHARED_DIR="$ROOT/ios/MeetingCore/Sources/MeetingCore"
SHARED_SOURCES=("$SHARED_DIR/Transcript.swift" "$SHARED_DIR/Notes.swift" "$SHARED_DIR/Grounding.swift")
APP_SOURCES=("$ROOT"/src/*.swift "${SHARED_SOURCES[@]}")
