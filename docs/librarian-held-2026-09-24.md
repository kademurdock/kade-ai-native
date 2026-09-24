# Librarian entry points — prepared, not built

User direction: ship the website; do not spend any Mac build minutes or start a native build. These source changes are held on `codex/librarian-ready-20260924`, based on `d7e8e72`.

The Library shelf opens Mrs. Witherspoon through the existing `ConversationDetailView`. The item player prepares a question containing the catalog ID. Both use the authenticated `/api/kade/reading-room/guide` endpoint, pause library playback, preserve the usual character voice settings, and report failures without switching characters.

Her registered expression and mouth sheets are bundled for the native portrait stage and character rows. This character uses nine core facial poses; extra native expression names reuse their closest core pose. The other companions keep their existing nuance sheets. Her avatar filename must still match the registered artwork before the moving portrait appears.

Before a future authorized release, merge this branch into the current native source, compile in Xcode, and check VoiceOver, back navigation, the prepared draft, character voice selection and microphone/call behavior on a device. No Xcode, simulator, Codemagic or TestFlight build was run for this change.
