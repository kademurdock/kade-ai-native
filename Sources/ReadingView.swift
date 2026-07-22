import SwiftUI
import UIKit

/// Session 25 (Kade: "Think we could do a reading view for native like we
/// do on web?"): the distraction-free full-screen reader, ported from the
/// web's `KadeReadingView.tsx` (July 16, accessibility research paper
/// Section C). One reply, plain text, big type, no chrome. The web version
/// renders deliberately-PLAIN text -- predictable for low-vision readers
/// and screen readers, styled markdown stays in chat -- and this port keeps
/// that choice: the text shown is `readableText`, the same
/// stripped-of-all-markup string the chat bubble reads.
///
/// Where the web hardcodes its type ramp (clamp 1.25-1.6rem, line-height
/// 1.7, 2.0 in loose mode), native gets all of that for FREE and better
/// from machinery that already exists here: `messageFont(relativeTo:
/// .title2)` = big type in the reader's CHOSEN family (Lexend/OpenDyslexic
/// honored, unlike the web reading view!), still Dynamic-Type-scaled; a
/// base 6pt of extra leading plays the role of the web's 1.7 line-height,
/// and the user's own line-spacing preference stacks on top exactly as it
/// does in chat. A 620pt reading measure mirrors the web's 46em cap.
///
/// VoiceOver: paragraphs are SEPARATE elements (one swipe per paragraph --
/// a long reply is resumable and skimmable, better than the web's single
/// text block), the close button is focused on open exactly as the web
/// focuses its close button, and dismissal is announced by the opener
/// putting focus back on the message row (see the fullScreenCover's
/// onDismiss in ConversationDetailView). Escape on a hardware keyboard
/// closes, matching the web's key handling.
struct ReadingView: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    @Environment(\.dismiss) private var dismiss

    let speaker: String
    let text: String

    @AccessibilityFocusState private var closeFocused: Bool

    private var paragraphs: [String] {
        let parts = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Visual header only -- the open announcement already says
                // whose reply this is, and a heading here would make
                // VoiceOver say it twice back to back.
                Text(speaker)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .padding(12)
                }
                .accessibilityLabel("Close reading view")
                .accessibilityHint("Returns to the conversation.")
                .accessibilityFocused($closeFocused)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(appearance.messageFont(relativeTo: .title2))
                            .lineSpacing(6 + appearance.lineSpacing.extraPoints)
                            .frame(maxWidth: 620, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 56)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear {
            closeFocused = true
            UIAccessibility.post(
                notification: .announcement,
                argument: "Reading view, full screen. \(speaker)'s reply. Swipe right to read paragraph by paragraph."
            )
        }
    }
}
