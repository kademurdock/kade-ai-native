import Foundation

var checks = 0
func check(_ passed: Bool, _ message: String) {
    checks += 1
    if !passed { fatalError(message) }
}

// FINAL observes delivery state but never instructs an automatic focus move.
var streamed = ReplySpeechFocus()
streamed.playbackDidStart()
streamed.completed(readAloudEnabled: true, hasAssistantReply: true)
check(!streamed.awaitingFirstClip, "a clip before FINAL satisfies delivery")
check(!streamed.queueDidDrain(hasPendingSpeech: false), "draining spoken audio does not create another delivery")
var gap = ReplySpeechFocus()
gap.playbackDidStart()
check(!gap.queueDidDrain(hasPendingSpeech: true), "a sentence gap with pending speech does not finish waiting")
gap.completed(readAloudEnabled: true, hasAssistantReply: true)
check(!gap.awaitingFirstClip && !gap.queueDidDrain(hasPendingSpeech: false), "FINAL between sentences does not rearm first-clip waiting")

var buffered = ReplySpeechFocus()
buffered.completed(readAloudEnabled: true, hasAssistantReply: true)
check(buffered.awaitingFirstClip, "buffered speech still waits for its real first clip")
check(!buffered.queueDidDrain(hasPendingSpeech: true) && buffered.awaitingFirstClip,
      "an older pump's false edge cannot end a newly scheduled or queued reply")
buffered.playbackDidStart()
check(!buffered.awaitingFirstClip && !buffered.queueDidDrain(hasPendingSpeech: false), "a clip after FINAL also prevents duplicate delivery")

var failed = ReplySpeechFocus()
failed.completed(readAloudEnabled: true, hasAssistantReply: true)
check(failed.awaitingFirstClip, "zero-audio FINAL first waits for actual queued playback")
check(failed.queueDidDrain(hasPendingSpeech: false), "an actually idle queue ends waiting without a focus instruction")
check(!failed.queueDidDrain(hasPendingSpeech: false), "an idle drain cannot repeat the completed wait")

var silent = ReplySpeechFocus()
silent.completed(readAloudEnabled: false, hasAssistantReply: true)
check(!silent.awaitingFirstClip, "Hear replies off stays quiet and never waits for autoplay")
check(!silent.queueDidDrain(hasPendingSpeech: false), "Hear replies off has no automatic fallback delivery")
silent.completed(readAloudEnabled: true, hasAssistantReply: false)
check(!silent.awaitingFirstClip, "a FINAL without a current assistant reply never promises speech")

streamed.reset()
check(!streamed.playbackStarted && !streamed.awaitingFirstClip, "a new Send clears previous playback history")
streamed.completed(readAloudEnabled: true, hasAssistantReply: true)
check(!streamed.queueDidDrain(hasPendingSpeech: true) && streamed.awaitingFirstClip, "an old drain cannot finish a new pending Send")
var canceled = ReplySpeechFocus()
canceled.completed(readAloudEnabled: true, hasAssistantReply: true)
canceled.clearWait()
check(!canceled.queueDidDrain(hasPendingSpeech: false), "canceling the wait leaves no late fallback action")

let old = ReplySpeechIdentity(messageId: "old-reply", conversationId: "current-chat", isCreatedByUser: false)
let current = ReplySpeechIdentity(messageId: "current-reply", conversationId: "current-chat", isCreatedByUser: false)
check(!ReplySpeechFocus.acceptsReply(finalReplyId: nil, conversationId: "current-chat", message: old), "missing FINAL identity cannot replay history")
check(!ReplySpeechFocus.acceptsReply(finalReplyId: "", conversationId: "current-chat", message: old), "empty FINAL identity cannot replay history")
check(!ReplySpeechFocus.acceptsReply(finalReplyId: "current-reply", conversationId: "current-chat", message: old), "an old assistant row cannot stand in for the current reply")
check(ReplySpeechFocus.acceptsReply(finalReplyId: "current-reply", conversationId: "current-chat", message: current), "the exact current FINAL reply is eligible for autoplay")
check(!ReplySpeechFocus.acceptsReply(finalReplyId: "current-reply", conversationId: "other-chat", message: current), "same reply ID in another chat is rejected")
let human = ReplySpeechIdentity(messageId: "current-reply", conversationId: "current-chat", isCreatedByUser: true)
check(!ReplySpeechFocus.acceptsReply(finalReplyId: "current-reply", conversationId: "current-chat", message: human), "a human message is never an assistant autoplay reply")
let receiptData = Data(#"{"taskId":"current-request","conversationId":"current-chat","status":"completed","responseMessageId":"current-reply","canOpenConversation":true}"#.utf8)
let receipt = try JSONDecoder().decode(ReplyTaskReceipt.self, from: receiptData)
check(receipt.completedReplyId(requestId: "current-request", conversationId: "current-chat") == "current-reply", "an already-ended stream recovers the exact completed request's reply")
check(receipt.completedReplyId(requestId: "other-request", conversationId: "current-chat") == nil, "a different request cannot supply the reply")
check(receipt.completedReplyId(requestId: "current-request", conversationId: "other-chat") == nil, "a different chat cannot supply the reply")
for status in ["starting", "running", "failed", "stopped", "interrupted"] {
    let incomplete = ReplyTaskReceipt(taskId: "current-request", conversationId: "current-chat", status: status,
                                      responseMessageId: "current-reply", canOpenConversation: true)
    check(incomplete.completedReplyId(requestId: "current-request", conversationId: "current-chat") == nil,
          "a \(status) request cannot claim a completed reply")
}
let deleted = ReplyTaskReceipt(taskId: "current-request", conversationId: "current-chat", status: "completed",
                               responseMessageId: "current-reply", canOpenConversation: false)
check(deleted.completedReplyId(requestId: "current-request", conversationId: "current-chat") == nil, "a deleted or inaccessible chat cannot be recovered")
let missing = ReplyTaskReceipt(taskId: "current-request", conversationId: "current-chat", status: "completed",
                               responseMessageId: nil, canOpenConversation: true)
check(missing.completedReplyId(requestId: "current-request", conversationId: "current-chat") == nil, "a receipt without a reply ID never guesses history")
print("Reply speech focus: \(checks) checks passed")
