import SwiftUI
import UIKit

/// CREATE A CHARACTER — the quiz, native (Aug 14 2026, build 202).
///
/// Her brief: "quiz options to help less creative people make an agent...
/// access for all, even those who don't know what ai is really." Eight
/// questions, every one answered by picking; typing is always optional. The
/// questions, the composed personality, the plain-language engine menu, and
/// the portrait painter all come from the SAME fork routes the web page at
/// /create-a-character uses — one brain, two surfaces, no drift.
///
/// House rules honored throughout: plain Buttons that own their own
/// accessibility (the Amber rule — nothing nested, no children:.ignore on
/// rows), one spoken announcement per state change, progress named out loud
/// ("Question 3 of 8"), and the one paid action (the portrait) says its price
/// on the button.
struct CharacterQuizView: View {
    let service: AgentBuilderService
    /// Called with the new agent's id after creation so the manager list
    /// refreshes without a manual pull.
    var onCreated: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case failed(String)
        case asking
        case composing
        case review
        case creating
        case done(String, String) // (name, agentId)
    }

    @State private var phase: Phase = .loading
    @State private var quiz: [AgentBuilderService.QuizQuestion] = []
    @State private var menu: [AgentBuilderService.ModelMenuEntry] = []
    @State private var step = 0
    @State private var singleAnswers: [String: String] = [:]
    @State private var multiAnswers: [String: [String]] = [:]
    @State private var typedName = ""
    @State private var draft: AgentBuilderService.QuizDraft?
    // Review-screen state
    @State private var pickedName = ""
    @State private var customName = ""
    @State private var editedDescription = ""
    @State private var editedInstructions = ""
    @State private var pickedModelKey = ""
    @State private var showTechnical = false
    @State private var portraitPng: Data?
    @State private var isPainting = false
    @State private var paintNote: String?
    @State private var errorNote: String?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Waking the quiz up…")
                        .accessibilityLabel("Waking the quiz up")
                case .failed(let why):
                    VStack(spacing: 12) {
                        Text(why).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                case .asking:
                    questionForm
                case .composing:
                    ProgressView("Building the character…")
                        .accessibilityLabel("Building the character")
                case .review:
                    reviewForm
                case .creating:
                    ProgressView("Bringing them to life…")
                        .accessibilityLabel("Bringing them to life")
                case .done(let name, _):
                    VStack(spacing: 16) {
                        Text("\(name) is alive.")
                            .font(.title2).fontWeight(.semibold)
                        Text("They're with your characters now. Anything about them can be fine-tuned in the regular builder any time.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Create a Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityHint("Leaves the quiz. Nothing is saved until the very last step.")
                }
            }
            .task { await load() }
        }
    }

    // MARK: - Loading

    private func load() async {
        phase = .loading
        async let q = service.loadQuiz()
        async let m = service.loadModelMenu()
        quiz = await q
        menu = await m
        if quiz.isEmpty {
            phase = .failed("The quiz couldn't load. Check the connection and try again.")
            return
        }
        phase = .asking
        announceStep()
    }

    private func announceStep() {
        guard step < quiz.count else { return }
        let q = quiz[step]
        UIAccessibility.post(
            notification: .screenChanged,
            argument: "Question \(step + 1) of \(quiz.count). \(q.ask)"
        )
    }

    // MARK: - Questions

    private var questionForm: some View {
        let q = quiz[step]
        return Form {
            Section {
                if let help = q.help, !help.isEmpty {
                    Text(help)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if q.freeText == true {
                    TextField("Their name (or leave blank for suggestions)", text: $typedName)
                        .accessibilityLabel("Their name")
                        .accessibilityHint("Optional. Leave it blank and five fitting names get offered instead.")
                } else if q.multi == true {
                    ForEach(q.options ?? [], id: \.v) { opt in
                        let on = (multiAnswers[q.id] ?? []).contains(opt.v)
                        Button {
                            toggleMulti(q: q, value: opt.v)
                        } label: {
                            HStack {
                                Text(opt.label).foregroundStyle(Color.primary)
                                Spacer()
                                if on { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(opt.label)
                        .accessibilityValue(on ? "Picked" : "Not picked")
                        .accessibilityHint("Double-tap to \(on ? "unpick" : "pick"). Up to \(q.max ?? 3).")
                    }
                } else {
                    ForEach(q.options ?? [], id: \.v) { opt in
                        let on = singleAnswers[q.id] == opt.v
                        Button {
                            singleAnswers[q.id] = opt.v
                            UIAccessibility.post(notification: .announcement, argument: "\(opt.label).")
                        } label: {
                            HStack {
                                Text(opt.label).foregroundStyle(Color.primary)
                                Spacer()
                                if on { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(opt.label)
                        .accessibilityValue(on ? "Picked" : "")
                    }
                }
            } header: {
                Text("Question \(step + 1) of \(quiz.count): \(q.ask)")
            } footer: {
                Text("No wrong answers anywhere in here.")
            }
            Section {
                if step > 0 {
                    Button("Back") {
                        step -= 1
                        announceStep()
                    }
                }
                Button(step == quiz.count - 1 ? "Build my character" : "Next") {
                    advance(from: q)
                }
                .fontWeight(.semibold)
                .disabled(q.freeText != true && q.multi != true && singleAnswers[q.id] == nil)
            }
        }
    }

    private func toggleMulti(q: AgentBuilderService.QuizQuestion, value: String) {
        var current = multiAnswers[q.id] ?? []
        if let idx = current.firstIndex(of: value) {
            current.remove(at: idx)
            UIAccessibility.post(notification: .announcement, argument: "Unpicked.")
        } else {
            if current.count >= (q.max ?? 3) {
                UIAccessibility.post(notification: .announcement, argument: "That's the limit of \(q.max ?? 3). Unpick one first.")
                return
            }
            current.append(value)
            UIAccessibility.post(notification: .announcement, argument: "Picked.")
        }
        multiAnswers[q.id] = current
    }

    private func advance(from q: AgentBuilderService.QuizQuestion) {
        if step < quiz.count - 1 {
            step += 1
            announceStep()
            return
        }
        Task { await composeDraft() }
    }

    private func composeDraft() async {
        phase = .composing
        var answers: [String: Any] = [:]
        for (k, v) in singleAnswers { answers[k] = v }
        for (k, v) in multiAnswers { answers[k] = v }
        answers["name"] = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let d = try await service.composeQuiz(answers: answers)
            draft = d
            pickedName = d.names.first ?? "Friend"
            editedDescription = d.description
            editedInstructions = d.instructions
            pickedModelKey = d.modelKey
            phase = .review
            UIAccessibility.post(
                notification: .screenChanged,
                argument: "The character is drafted. Review the name, the personality, the engine, and the picture, then bring them to life."
            )
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Review

    private var reviewForm: some View {
        Form {
            if let draft {
                Section {
                    ForEach(draft.names, id: \.self) { n in
                        Button {
                            pickedName = n
                            customName = ""
                            UIAccessibility.post(notification: .announcement, argument: "\(n) picked.")
                        } label: {
                            HStack {
                                Text(n).foregroundStyle(Color.primary)
                                Spacer()
                                if pickedName == n && customName.isEmpty {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(n)
                        .accessibilityValue(pickedName == n && customName.isEmpty ? "Picked" : "")
                    }
                    TextField("Or type another name", text: $customName)
                        .accessibilityLabel("Or type another name")
                } header: {
                    Text("Their name")
                }
                Section("One-line description") {
                    TextField("Description", text: $editedDescription, axis: .vertical)
                        .accessibilityLabel("Description")
                }
                Section {
                    TextField("Personality", text: $editedInstructions, axis: .vertical)
                        .lineLimit(6...30)
                        .accessibilityLabel("Personality")
                        .accessibilityHint("The full written personality. Edit anything, or leave it as drafted.")
                } header: {
                    Text("Their personality")
                } footer: {
                    Text("Written from your answers. Every word can be changed, now or later.")
                }
                Section {
                    ForEach(menu) { entry in
                        Button {
                            pickedModelKey = entry.key
                            UIAccessibility.post(notification: .announcement, argument: "\(entry.plainName) picked.")
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.plainName).fontWeight(.semibold)
                                        .foregroundStyle(Color.primary)
                                    Text(entry.blurb)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    if showTechnical {
                                        Text("\(entry.provider) / \(entry.model)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if pickedModelKey == entry.key {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.plainName). \(entry.blurb) Good for \(entry.goodFor).")
                        .accessibilityValue(pickedModelKey == entry.key ? "Picked" : "")
                    }
                    Button(showTechnical ? "Hide technical names" : "Show technical names") {
                        showTechnical.toggle()
                    }
                    .font(.footnote)
                } header: {
                    Text("Their engine")
                } footer: {
                    Text("The machinery that does their thinking, in plain words.")
                }
                Section {
                    if let png = portraitPng, let img = UIImage(data: png) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Their freshly painted portrait")
                    }
                    Button {
                        Task { await paint() }
                    } label: {
                        HStack {
                            Text(isPainting
                                ? "Painting…"
                                : (portraitPng == nil ? "Paint their portrait (3 cents)" : "Paint a different one (3 cents)"))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if isPainting { ProgressView().accessibilityHidden(true) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isPainting)
                    .accessibilityLabel(isPainting ? "Painting. About fifteen seconds." : "Paint their portrait. Costs three cents of picture credit.")
                    .accessibilityHint("Optional. Skipping it is fine — a picture can be added any time in the regular builder.")
                    if let paintNote {
                        Text(paintNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Their picture")
                }
                Section {
                    Button("Back to the questions") {
                        phase = .asking
                        step = quiz.count - 1
                        announceStep()
                    }
                    Button("Bring them to life") {
                        Task { await create() }
                    }
                    .fontWeight(.bold)
                    if let errorNote {
                        Text(errorNote).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func paint() async {
        guard let draft, !isPainting else { return }
        isPainting = true
        paintNote = nil
        UIAccessibility.post(notification: .announcement, argument: "Painting the portrait. About fifteen seconds.")
        defer { isPainting = false }
        do {
            let out = try await service.paintPortrait(prompt: "Character named \(finalName()). \(draft.avatarPrompt)")
            portraitPng = out.png
            if let left = out.remainingToday { paintNote = "\(left) repaints left today." }
            UIAccessibility.post(notification: .announcement, argument: "Portrait painted. There's a repaint button if you want a different one.")
        } catch {
            paintNote = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func finalName() -> String {
        let custom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? pickedName : custom
    }

    private func create() async {
        guard let draft else { return }
        phase = .creating
        errorNote = nil
        let entry = menu.first(where: { $0.key == pickedModelKey })
        let fields = AgentBuilderService.AgentFields(
            name: finalName(),
            description: editedDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: editedInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
            category: draft.category,
            provider: entry?.provider ?? draft.provider,
            model: entry?.model ?? draft.model,
            voice: "",
            starters: draft.conversation_starters,
            tools: nil
        )
        do {
            let agent = try await service.createAgent(fields)
            if let png = portraitPng, let img = UIImage(data: png),
               let jpeg = AgentEditorView.avatarJpeg(from: img) {
                // Fail-soft on purpose: the character exists either way, and
                // a portrait can be added in the editor any time.
                try? await service.uploadAvatar(id: agent.id, jpegData: jpeg)
            }
            onCreated?(agent.id)
            phase = .done(fields.name, agent.id)
            UIAccessibility.post(notification: .screenChanged, argument: "\(fields.name) is alive. They're with your characters now.")
        } catch {
            phase = .review
            errorNote = "That didn't take: \(error.localizedDescription) Nothing was lost — try again."
            UIAccessibility.post(notification: .announcement, argument: errorNote ?? "")
        }
    }
}
