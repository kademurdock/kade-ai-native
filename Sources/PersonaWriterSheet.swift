import SwiftUI
import UIKit

/// THE DESCRIPTION BOX, from inside the ordinary agent editor (Part 113,
/// Sep 1 2026).
///
/// Her brief, verbatim: *"I would kind of like a box maybe where you describe
/// what you want in an agent or character, and the ai generates a robust
/// system prompt like Kiana's. So people who can't find the words can get
/// them eventually."*
///
/// ⭐ "EVENTUALLY" IS THE REQUIREMENT, NOT A HEDGE, and it is why this screen
/// is a loop instead of a button. The person who needs this most cannot
/// describe what they want on the first try — that is precisely why they need
/// it. So the desk drafts, hands back the two or three questions whose answers
/// would most improve the next draft, and deepens on each pass. A one-shot
/// generator would serve the articulate person who needed the least help.
///
/// This sheet is the SECOND door — improve the prompt I already have — which
/// is the one Amber A actually needs: she knows what acceptance and commitment
/// therapy is, she needs help expressing it, not inventing it. The first door
/// (write me one from nothing) lives in CharacterQuizView.
///
/// Nothing here writes to the agent. It hands the finished text back to the
/// editor, where the person still has to look at it and tap Save.
struct PersonaWriterSheet: View {
    let service: AgentBuilderService
    let characterName: String
    let existing: String
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var brief = ""
    @State private var draft = ""
    @State private var questions: [String] = []
    @State private var answers: [String] = ["", "", ""]
    @State private var notes: String?
    @State private var round = 0
    @State private var busy = false
    @State private var errorNote: String?

    private var trimmedBrief: String { brief.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if round == 0 {
                    briefSection
                } else {
                    draftSection
                    if !questions.isEmpty { questionsSection }
                    useSection
                }
                if busy {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().accessibilityHidden(true)
                            Text("Writing… this takes up to a minute.")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Writing their personality. This takes up to a minute.")
                    }
                }
                if let errorNote {
                    Section { Text(errorNote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Help me write this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityHint("Closes this without changing the personality.")
                }
            }
            .onAppear {
                UIAccessibility.post(
                    notification: .screenChanged,
                    argument: existing.isEmpty
                        ? "Describe the character you want. A sentence is enough to start."
                        : "Say what you want this character to be. The personality already in the editor gets improved rather than replaced from scratch."
                )
            }
        }
    }

    private var briefSection: some View {
        Section {
            TextField(
                "An acceptance-and-commitment therapist who also borrows from other approaches when it fits.",
                text: $brief,
                axis: .vertical
            )
            .lineLimit(4...16)
            .accessibilityLabel("What you want this character to be")
            .accessibilityHint("Say it however it comes out. There is no wrong way to write this.")
            Button(existing.isEmpty ? "Write their personality (about 1 cent)" : "Improve what's there (about 1 cent)") {
                Task { await write(nextRound: 1, answered: []) }
            }
            .fontWeight(.semibold)
            .disabled(busy || (trimmedBrief.count < 8 && existing.isEmpty))
        } header: {
            Text(existing.isEmpty ? "Describe the character you want" : "What should this character be?")
        } footer: {
            Text(existing.isEmpty
                 ? "A sentence is enough to start with — you get follow-up questions afterwards, and the answers make it deeper each time."
                 : "The personality already in the editor gets deepened, not thrown away. Say what's missing, or what it should really be, and everything specific it already has is kept.")
        }
    }

    private var draftSection: some View {
        Section {
            TextField("Personality", text: $draft, axis: .vertical)
                .lineLimit(8...40)
                .accessibilityLabel("The written personality")
                .accessibilityHint("Edit any word of it. Nothing is saved to the character until you use it and then tap Save in the editor.")
        } header: {
            Text("The written personality")
        } footer: {
            Text("\(draft.count) characters\(notes.map { ". \($0)" } ?? "")")
        }
    }

    private var questionsSection: some View {
        Section {
            ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q).font(.subheadline)
                    TextField("Your answer", text: Binding(
                        get: { idx < answers.count ? answers[idx] : "" },
                        set: { v in
                            while answers.count <= idx { answers.append("") }
                            answers[idx] = v
                        }
                    ), axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityLabel("Answer to: \(q)")
                }
            }
            Button("Deepen it with my answers (about 1 cent)") {
                let pairs = zip(questions, answers)
                    .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { AgentBuilderService.PersonaAnswer(q: $0.0, a: $0.1) }
                Task { await write(nextRound: round + 1, answered: pairs) }
            }
            .fontWeight(.semibold)
            .disabled(busy || answers.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } header: {
            Text("Answer any of these and it gets deeper")
        } footer: {
            Text("These are the questions the writer says would most improve the next draft. Answer one, two, all three, or none — skipping is fine, and you can always edit by hand.")
        }
    }

    private var useSection: some View {
        Section {
            Button("Use this personality") {
                onUse(draft)
                dismiss()
            }
            .fontWeight(.bold)
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityHint("Puts this text into the personality box in the editor. It still has to be saved there.")
            Button("Start over") {
                round = 0
                questions = []
                answers = ["", "", ""]
                notes = nil
                errorNote = nil
            }
        }
    }

    /// Fail-soft on purpose: a failed round leaves the draft that is already on
    /// screen exactly where it is. Losing a persona somebody just paid for and
    /// read is the worst failure this screen has.
    private func write(nextRound: Int, answered: [AgentBuilderService.PersonaAnswer]) async {
        guard !busy else { return }
        busy = true
        errorNote = nil
        UIAccessibility.post(notification: .announcement, argument: "Writing their personality. This takes up to a minute.")
        defer { busy = false }
        do {
            let out = try await service.writePersona(
                description: trimmedBrief.isEmpty ? "Improve and deepen this character's existing personality." : trimmedBrief,
                name: characterName.trimmingCharacters(in: .whitespacesAndNewlines),
                existing: round == 0 ? existing : draft,
                answers: answered,
                round: nextRound
            )
            draft = out.instructions
            questions = out.questions
            answers = ["", "", ""]
            notes = out.notes
            round = out.round
            let qLine = out.questions.isEmpty
                ? "You can edit it, or use it as it stands."
                : "There are \(out.questions.count) follow-up questions that would make it deeper, and a button to use it as it stands."
            UIAccessibility.post(
                notification: .screenChanged,
                argument: "Their personality is written, \(out.instructions.count) characters. \(qLine)"
            )
        } catch {
            errorNote = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }
}
