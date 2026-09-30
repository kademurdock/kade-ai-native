import SwiftUI
import UIKit

// MARK: - Family history: How are you related? (Sep 29 2026)
//
// DESIGN 1.12, one GET /play: five rounds of mixed kinds, every word the
// server's ("Who is she to you?", "Mom's side or Dad's side?", "Who was
// born first?", "Guess this picture's decade", "Where was she born?"). The
// server leaves out anyone on a research path or in a sensitive finding,
// because a quiz states its answer as fact.
// - No timers. The question is a heading; the choices are buttons.
// - After a choice: right plays the success haptic, the action earcon and a
//   short confetti burst (never when motion is reduced); wrong plays the
//   error earcon. Either way the server's words say why ("Not quite. She's
//   your 2nd great-grandmother: your mom's mom's mom.") as text, and
//   VoiceOver moves to them (not to Next).
// - The score reads "3 of 5"; the best score is kept for each account.
// - A guest meets the server's reason ("For family members in the tree").
// Faces and the round's picture are for sight: they never give the answer
// away (first names only, and the server takes the year out of a picture's
// words), and VoiceOver hears the question's own sentence instead.

struct FamilyPlayScreen: View {
    let apiClient: KadeAPIClient

    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var game: FHPlay?
    @State private var failure: String?
    /// The server said no (a guest): its words, and no Try again.
    @State private var closed: String?
    @State private var round = 0
    @State private var picked: Int?
    @State private var right = 0
    @State private var finished = false
    @State private var confetti = 0
    @State private var best: FamilyPlayScore?
    @AccessibilityFocusState private var focus: FamilyPlayFocus?

    private var rounds: [FHRound] { (game?.rounds ?? []).filter { $0.playable } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FamilyHeading(text: "How are you related?", level: .h1, focusOnArrival: true)
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("How are you related?")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
    }

    @ViewBuilder
    private var content: some View {
        if let closed {
            Text(closed)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if game != nil {
            if rounds.isEmpty {
                Text("There are no questions to ask yet. The game needs more of the tree.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if finished {
                endCard
            } else if rounds.indices.contains(round) {
                roundView(rounds[round])
            }
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    // MARK: One round

    private func roundView(_ current: FHRound) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Question \(round + 1) of \(rounds.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            question(current)
            FamilyPlayPictures(round: current)
            choices(current)
            if let picked {
                resultCard(current, picked: picked)
            }
        }
    }

    private func question(_ current: FHRound) -> some View {
        Text(current.prompt ?? "")
            .font(.title2.bold())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(FamilyAccessRules.nonEmpty(current.spoken) ?? current.prompt ?? "")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
            .accessibilityFocused($focus, equals: .question(round))
    }

    private func choices(_ current: FHRound) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(current.choices.enumerated()), id: \.offset) { pair in
                FamilyPlayChoice(choice: pair.element,
                                 state: choiceState(pair.offset, current),
                                 answered: picked != nil) {
                    choose(pair.offset, in: current)
                }
            }
        }
    }

    private func choiceState(_ index: Int, _ current: FHRound) -> FamilyChoiceState {
        guard let picked else { return .open }
        if index == current.answer { return .right }
        if index == picked { return .wrongPick }
        return .other
    }

    private func resultCard(_ current: FHRound, picked: Int) -> some View {
        let correct: Bool = picked == current.answer
        let last: Bool = round + 1 >= rounds.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(current.result(correct: correct))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($focus, equals: .result(round))
            Text("Score: " + FamilyPlayScore(right: right, total: rounds.count).words)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                next()
            } label: {
                Text(last ? "See your score" : "Next question")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .familyCard()
        .overlay {
            if correct && motionAllowed {
                FamilyConfetti(trigger: confetti)
            }
        }
    }

    // MARK: The end

    private var endCard: some View {
        let score = FamilyPlayScore(right: right, total: rounds.count)
        return VStack(alignment: .leading, spacing: 12) {
            Text("You got " + score.words + ".")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h2)
                .accessibilityFocused($focus, equals: .end)
            if let best {
                Text("Your best: " + best.words)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await load(force: true) }
            } label: {
                Text("Play again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Five new questions.")
        }
        .familyCard()
    }

    // MARK: Playing

    private func choose(_ index: Int, in current: FHRound) {
        guard picked == nil else { return }
        picked = index
        let correct: Bool = index == current.answer
        if correct {
            right += 1
            KadeHaptics.success()
            Earcons.shared.play(.actionDone)
            confetti += 1
        } else {
            KadeHaptics.warning()
            Earcons.shared.play(.error)
        }
        let target: FamilyPlayFocus = .result(round)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            focus = target
        }
    }

    private func next() {
        if round + 1 >= rounds.count {
            finish()
            return
        }
        round += 1
        picked = nil
        let target: FamilyPlayFocus = .question(round)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            focus = target
        }
    }

    private func finish() {
        finished = true
        let score = FamilyPlayScore(right: right, total: rounds.count)
        let kept: FamilyPlayScore? = FamilyPlayScore(stored: FamilyMemory.string(FamilyMemory.playBest))
        if score.beats(kept) {
            FamilyMemory.set(score.stored, FamilyMemory.playBest)
            best = score
        } else {
            best = kept
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            focus = .end
        }
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool) async {
        if !force, game != nil || closed != nil { return }
        do {
            let fresh = try await FamilyHistoryService.shared.play(count: 5)
            game = fresh
            failure = nil
            round = 0
            picked = nil
            right = 0
            finished = false
            if force {
                let target: FamilyPlayFocus = .question(0)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    focus = target
                }
            }
        } catch {
            if LibraryLoad.cancelled(error) { return }
            if case .locked(let locked)? = error as? FamilyFailure {
                closed = FamilyAccessRules.nonEmpty(locked.error) ?? FamilyAccessRules.nonEmpty(locked.detail)
                    ?? "The game is for family members in the tree."
                return
            }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if game == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }
}

/// Where VoiceOver is sent in the game.
enum FamilyPlayFocus: Hashable {
    case question(Int)
    case result(Int)
    case end
}

enum FamilyChoiceState {
    case open, right, wrongPick, other
}

// MARK: - A choice

/// One answer button. After a choice the right answer shows a tick and the
/// wrong pick a cross (and says so), never colour alone.
struct FamilyPlayChoice: View {
    let choice: FHChoice
    let state: FamilyChoiceState
    let answered: Bool
    let action: () -> Void

    private var spoken: String {
        let words: String = FamilyAccessRules.nonEmpty(choice.spoken) ?? choice.text
        switch state {
        case .right: return words + ", the right answer"
        case .wrongPick: return words + ", your answer"
        case .open, .other: return words
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(choice.text)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                mark
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(answered)
        .accessibilityLabel(spoken)
        .accessibilityInputLabels([choice.text])
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .right:
            Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
        case .wrongPick:
            Image(systemName: "xmark.circle.fill").accessibilityHidden(true)
        case .open, .other:
            EmptyView()
        }
    }

    private var tint: Color {
        switch state {
        case .right: return .green
        case .wrongPick: return .red
        case .open, .other: return .accentColor
        }
    }
}

// MARK: - The round's faces and picture

/// The people asked about (faces or initials, first names only) and the
/// round's picture, for sight. Hidden from VoiceOver: the question's own
/// sentence says what they show.
struct FamilyPlayPictures: View {
    let round: FHRound

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = round.image {
                FamilyWidePhoto(image: image, size: .s, height: 220, longSide: 680)
            }
            if !round.people.isEmpty && round.image == nil {
                HStack(spacing: 18) {
                    ForEach(round.people) { person in
                        VStack(spacing: 4) {
                            FamilyPhoto(image: person.face, size: .f, drawn: 72,
                                        initials: person.initials ?? "", side: .unknown, circle: true)
                            Text(FamilyAccessRules.nonEmpty(person.first) ?? person.shownName)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Confetti

/// A short burst of paper for a right answer: a drawing, hidden from
/// VoiceOver, never shown when motion is reduced (the caller checks).
struct FamilyConfetti: View {
    let trigger: Int

    @State private var falling = false
    @State private var visible = false

    private static let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if visible {
                    ForEach(0..<24, id: \.self) { i in
                        piece(i, size: geo.size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: trigger) { await burst() }
    }

    private func piece(_ i: Int, size: CGSize) -> some View {
        let x: CGFloat = size.width * CGFloat((i * 37) % 100) / 100
        let drift: CGFloat = CGFloat(((i * 53) % 41) - 20)
        let turn: Double = Double((i * 71) % 360)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Self.colors[i % Self.colors.count])
            .frame(width: 7, height: 11)
            .rotationEffect(.degrees(falling ? turn + 240 : turn))
            .position(x: x + (falling ? drift : 0), y: falling ? size.height + 20 : -10)
            .opacity(falling ? 0 : 1)
    }

    @MainActor
    private func burst() async {
        guard trigger > 0 else { return }
        falling = false
        visible = true
        try? await Task.sleep(nanoseconds: 30_000_000)
        withAnimation(.easeIn(duration: 1.1)) {
            falling = true
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        visible = false
    }
}
