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
        /// Part 113: the front door. Describe them in your own words, or take
        /// the eight questions. The describe door is new and is the one she
        /// asked for; the quiz is exactly where it was.
        case door
        case describing
        case writing
        case persona
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
    // Part 113 — the description box
    @State private var describeText = ""
    @State private var describeName = ""
    @State private var personaQuestions: [String] = []
    @State private var personaAnswers: [String] = ["", "", ""]
    @State private var personaNotes: String?
    @State private var personaRound = 0
    @State private var personaCost: Double?
    @State private var personaNote: String?

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
                case .door:
                    doorForm
                case .describing:
                    describeForm
                case .writing:
                    ProgressView("Writing their personality…")
                        .accessibilityLabel("Writing their personality. This takes up to a minute.")
                case .persona:
                    personaForm
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
        phase = .door
        UIAccessibility.post(
            notification: .screenChanged,
            argument: "How would you like to start? Describe them in your own words, or answer eight quick questions."
        )
    }

    private func announceStep() {
        guard step < quiz.count else { return }
        let q = quiz[step]
        UIAccessibility.post(
            notification: .screenChanged,
            argument: "Question \(step + 1) of \(quiz.count). \(q.ask)"
        )
    }

    // MARK: - The front door and the description box (Part 113)

    private var doorForm: some View {
        Form {
            Section {
                Button {
                    phase = .describing
                    UIAccessibility.post(
                        notification: .screenChanged,
                        argument: "Describe the character or agent you want. A sentence is enough to start."
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Describe them in your own words").fontWeight(.semibold)
                            .foregroundStyle(Color.primary)
                        Text("Say who they are however it comes out, and a full, detailed personality gets written for you — then it asks you a couple of questions to make it deeper. About a penny.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Describe them in your own words")
                .accessibilityHint("Writes a full detailed personality from a description. Costs about one cent of credit.")

                Button {
                    step = 0
                    phase = .asking
                    announceStep()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Answer eight quick questions").fontWeight(.semibold)
                            .foregroundStyle(Color.primary)
                        Text("Every one answered by picking. Free, and it builds a shorter starter personality you can grow later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Answer eight quick questions")
                .accessibilityHint("Free. Nothing here needs you to know anything about A I.")
            } header: {
                Text("How would you like to start?")
            } footer: {
                Text("Either way you can edit every word before anybody comes to life.")
            }
        }
    }

    private var describeForm: some View {
        Form {
            Section {
                TextField(
                    "An acceptance-and-commitment therapist who also borrows from other approaches when it fits.",
                    text: $describeText,
                    axis: .vertical
                )
                .lineLimit(5...20)
                .accessibilityLabel("Your description")
                .accessibilityHint("Say who they are, what they're for, and how they should feel to talk to. There is no wrong way to write this.")
                TextField("Their name, if you have one", text: $describeName)
                    .accessibilityLabel("Their name")
                    .accessibilityHint("Optional. Leave it blank and names get suggested later.")
            } header: {
                Text("Describe the character or agent you want")
            } footer: {
                Text("A sentence is enough to start with — you get follow-up questions afterwards, and the answers make it deeper each time.")
            }
            Section {
                Button("Back") { phase = .door }
                Button("Write their personality (about 1 cent)") {
                    Task { await writePersona(round: 1, existing: "", answers: []) }
                }
                .fontWeight(.semibold)
                .disabled(describeText.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
                if let personaNote {
                    Text(personaNote).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private var personaForm: some View {
        Form {
            Section {
                TextField("Personality", text: $editedInstructions, axis: .vertical)
                    .lineLimit(8...40)
                    .accessibilityLabel("Their personality")
                    .accessibilityHint("The full written personality. Edit any word of it — it's yours.")
            } header: {
                Text("Their personality")
            } footer: {
                Text("\(editedInstructions.count) characters, written from your description. Edit anything.")
            }
            if let personaNotes, !personaNotes.isEmpty {
                Section("What the writer says") {
                    Text(personaNotes).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !personaQuestions.isEmpty {
                Section {
                    ForEach(Array(personaQuestions.enumerated()), id: \.offset) { idx, q in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(q).font(.subheadline)
                            TextField("Your answer", text: Binding(
                                get: { idx < personaAnswers.count ? personaAnswers[idx] : "" },
                                set: { v in
                                    while personaAnswers.count <= idx { personaAnswers.append("") }
                                    personaAnswers[idx] = v
                                }
                            ), axis: .vertical)
                            .lineLimit(1...6)
                            .accessibilityLabel("Answer to: \(q)")
                        }
                    }
                    Button("Deepen it with my answers (about 1 cent)") {
                        let pairs = zip(personaQuestions, personaAnswers)
                            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                            .map { AgentBuilderService.PersonaAnswer(q: $0.0, a: $0.1) }
                        Task { await writePersona(round: personaRound + 1, existing: editedInstructions, answers: pairs) }
                    }
                    .fontWeight(.semibold)
                    .disabled(personaAnswers.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                } header: {
                    Text("Answer any of these and it gets deeper")
                } footer: {
                    Text("These are the questions the writer says would most improve the next draft. Answer one, two, all three, or none — skipping is fine.")
                }
            }
            Section {
                Button("Start the description over") { phase = .describing }
                Button("Use this personality") {
                    Task { await useWrittenPersona() }
                }
                .fontWeight(.bold)
                if let personaNote {
                    Text(personaNote).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    /// One call, both doors — round 1 from a description, later rounds from
    /// the draft plus her answers. Fail-soft: a failure leaves whatever draft
    /// was already on screen exactly where it was, because losing a persona
    /// somebody just paid for and read is the worst failure this screen has.
    private func writePersona(round: Int, existing: String, answers: [AgentBuilderService.PersonaAnswer]) async {
        /* `Phase` carries associated values and is deliberately not Equatable,
         * so remember where to fall BACK to as a plain flag rather than
         * comparing cases. */
        let cameFromPersona = personaRound > 0
        personaNote = nil
        phase = .writing
        UIAccessibility.post(notification: .announcement, argument: "Writing their personality. This takes up to a minute.")
        do {
            let out = try await service.writePersona(
                description: describeText.trimmingCharacters(in: .whitespacesAndNewlines),
                name: describeName.trimmingCharacters(in: .whitespacesAndNewlines),
                existing: existing,
                answers: answers,
                round: round
            )
            editedInstructions = out.instructions
            personaQuestions = out.questions
            personaAnswers = ["", "", ""]
            personaNotes = out.notes
            personaRound = out.round
            personaCost = out.costUSD
            phase = .persona
            let qLine = out.questions.isEmpty
                ? "You can edit it, or use it as it stands."
                : "There are \(out.questions.count) follow-up questions that would make it deeper, and a button to use it as it stands."
            UIAccessibility.post(
                notification: .screenChanged,
                argument: "Their personality is written, \(out.instructions.count) characters. \(qLine)"
            )
        } catch {
            phase = cameFromPersona ? .persona : .describing
            personaNote = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    /// The written persona hands off to the SAME review screen the quiz uses —
    /// name, engine, portrait, create. The quiz brain supplies the defaults
    /// for the parts a description doesn't cover, so there is exactly one
    /// review screen and one create path.
    private func useWrittenPersona() async {
        let written = editedInstructions
        if draft == nil {
            phase = .composing
            do {
                var answers: [String: Any] = [:]
                let typed = describeName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty { answers["name"] = typed }
                let d = try await service.composeQuiz(answers: answers)
                draft = d
                pickedName = d.names.first ?? "Friend"
                pickedModelKey = d.modelKey
                let firstSentence = describeText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { ".!?".contains($0) })
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let line = (firstSentence?.isEmpty == false ? firstSentence! : d.description)
                editedDescription = String(line.prefix(140))
            } catch {
                phase = .persona
                personaNote = error.localizedDescription
                return
            }
        }
        editedInstructions = written
        phase = .review
        UIAccessibility.post(
            notification: .screenChanged,
            argument: "The character is drafted. Review the name, the description, the engine, and the picture, then bring them to life."
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
                    /* Part 113 — the second door, reachable from the quiz's own
                     * review: take the short template draft and have it written
                     * out properly. This is the door Amber A actually needs —
                     * she knows what she wants, she needs help expressing it. */
                    Button("Have it written out properly (about 1 cent)") {
                        if describeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            describeText = editedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        describeName = finalName()
                        Task { await writePersona(round: 1, existing: editedInstructions, answers: []) }
                    }
                    .font(.footnote)
                } header: {
                    Text("Their personality")
                } footer: {
                    Text("Written from your answers. Every word can be changed, now or later. Having it written out properly turns this into a full, detailed personality and asks you a couple of questions to deepen it — nothing changes until you look at it.")
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
                    Button(describeText.isEmpty ? "Back to the questions" : "Back to the description") {
                        if describeText.isEmpty {
                            phase = .asking
                            step = quiz.count - 1
                            announceStep()
                        } else {
                            phase = .persona
                        }
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
