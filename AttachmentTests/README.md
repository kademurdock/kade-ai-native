# Attachment regression tests

These four XCTest cases use synthetic bytes and injected uploads. They check
cancellation with a late completion, timeout recovery, explicit retry preserving
the original attachment/context, and empty/oversized/invalid-image validation.
They do not open Photos, request camera permission, upload files or invoke AI.

The `KadeAIAttachmentTests` target and scheme are registered in `project.yml` and
are separate from the release archive scheme. They have not been compiled or run
in this Windows workspace, where Swift and Xcode are unavailable.

On an authorized Mac with the existing project dependencies and XcodeGen:

```sh
xcodegen generate
xcodebuild test -scheme KadeAIAttachmentTests -configuration Debug \
  -destination 'platform=iOS Simulator,id=<available simulator UDID>' \
  CODE_SIGNING_ALLOWED=NO
```

Device acceptance still needs photo-picker cancellation, an iCloud photo that
loads slowly, a stalled upload, camera denial/unavailability/Retake/Use Photo,
attachment removal, and VoiceOver focus/Retry/Cancel. Use synthetic content and
an injected or mock backend; do not call paid model generation for these checks.
