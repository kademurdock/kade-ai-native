The keeper may save a card after a chat's three-second grace and FINAL event.
Native had already stopped reading that stream, so a real saved card could be
silent. The backend now retains the keeper's actual artifacts on the exact
saved assistant reply, without waiting longer for the reply.

Native uses the existing authenticated messages GET with both conversationId
and messageId. It reads for at most twelve attempts in a 48-second window,
stops on a rejected/malformed read or the first verified new card receipt,
and cancels on a new send, abort, or leaving the chat. It does not guess an
old reply id when a completed stream has already disappeared. No model,
audio generation, push notification, or persistent background polling is used.

Only new update/delete artifacts for that exact assistant reply can produce
the existing VoiceOver announcement and haptic. Live SSE receipts are seeded
into the deduplication set, so recovery does not replay a cue already heard.
Error artifacts, ordinary attachments, missing identities, other chats and
historical replies stay silent. The view additionally checks that its chat
is still on screen and matches the receipt's conversation.

Nineteen Foundation checks cover receipt identity, scope, live/recovery dedup,
error suppression, deletions, attempt/deadline limits, cancellation and leaving
before FINAL. The runner is in
both native build gates. Windows cannot execute Swift here; the authorized
Mac build must compile and run it. Physical iPhone/VoiceOver timing remains
unverified until the user tries the build.
