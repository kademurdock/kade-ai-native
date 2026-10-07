import Foundation

var checks = 0
func check(_ passed: Bool, _ message: String) {
    checks += 1
    if !passed { fatalError(message) }
}

// The reported path: the final streamed clip is already playing at FINAL.
var streamed = ReplySpeechFocus()
streamed.playbackDidStart()
check(!streamed.completed(readAloudEnabled: true, hasAssistantReply: true), "autoplay completion keeps the user's cursor")
check(!streamed.awaitingFirstClip, "a clip before FINAL satisfies first-clip delivery")
check(!streamed.speechQueueDidFinish(), "draining the final streamed clip cannot reread the reply through VoiceOver")

// A gap between streamed sentences, including a gap at final completion.
var gap = ReplySpeechFocus()
gap.playbackDidStart()
check(!gap.speechQueueDidFinish(), "a sentence gap does not request a fallback")
check(!gap.completed(readAloudEnabled: true, hasAssistantReply: true), "FINAL in a sentence gap retains speech intent")
check(!gap.speechQueueDidFinish(), "a later tail failure does not reread an already spoken reply")

// The non-streamed handoff still delivers its first clip after FINAL.
var buffered = ReplySpeechFocus()
check(!buffered.completed(readAloudEnabled: true, hasAssistantReply: true), "buffered autoplay also preserves focus")
check(buffered.awaitingFirstClip, "buffered speech waits for its actual first clip")
buffered.playbackDidStart()
check(!buffered.awaitingFirstClip && !buffered.speechQueueDidFinish(), "a clip after FINAL also prevents duplicate VoiceOver")

// A real speech failure must retain the existing accessible delivery path.
var failed = ReplySpeechFocus()
check(!failed.completed(readAloudEnabled: true, hasAssistantReply: true), "speech failure first waits for voice delivery")
check(failed.speechQueueDidFinish(), "a queue that never played falls back to VoiceOver")
check(!failed.speechQueueDidFinish(), "speech failure fallback happens only once")

var silent = ReplySpeechFocus()
check(silent.completed(readAloudEnabled: false, hasAssistantReply: true), "Hear replies off reads the new reply through VoiceOver")
check(!silent.awaitingFirstClip && !silent.speechQueueDidFinish(), "a silent reply has no later voice fallback")
check(silent.completed(readAloudEnabled: true, hasAssistantReply: false), "no assistant reply never promises speech")

// A new send and a canceled wait must not inherit a previous turn's result.
streamed.reset()
check(!streamed.playbackStarted && !streamed.awaitingFirstClip, "new send clears prior playback history")
check(!streamed.completed(readAloudEnabled: true, hasAssistantReply: true) && streamed.speechQueueDidFinish(), "previous spoken turn cannot hide a new turn's speech failure")
var canceled = ReplySpeechFocus()
_ = canceled.completed(readAloudEnabled: true, hasAssistantReply: true)
canceled.clearWait()
check(!canceled.speechQueueDidFinish(), "canceling a wait cannot cause a late focus move")

print("Reply speech focus: \(checks) checks passed")
