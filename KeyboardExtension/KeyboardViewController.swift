import UIKit

/// Aug 5 2026: a button whose VoiceOver activation is EXPLICIT. VO's
/// double-tap calls accessibilityActivate() first; returning true consumes
/// the activation, so the action never depends on synthesized-touch
/// delivery into a keyboard extension (the Transcribe dead-key report).
/// Real finger taps never enter this path — touchUpInside stays wired.
final class KadeActivatableButton: UIButton {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }
}

/// KADE KEYS (July 31 2026) — phase 2, HER PIVOT, verbatim: "I just want a
/// deepgram dictate for the most part... I want the keyboard to be just
/// like the [transcribe] part of my app." So: DICTATE IS THE HERO KEY.
///
/// The dance (the same one Wispr Flow pays for, because iOS hard-blocks
/// microphones inside every keyboard extension, no exceptions):
///   1. Dictate key → opens the Kade-AI app at kadeai://kadekeys-dictate
///      (responder-chain openURL — the household trick every shipping
///      dictation keyboard uses; extensionContext.open is a no-op in
///      keyboards).
///   2. The app lands on the Quick-Dictate lane in keyboard mode: already
///      listening, Deepgram cleans it up, the finished text goes into the
///      App Group container AND the clipboard.
///   3. She swipes back (iOS 26.4 killed automatic hop-back — the one
///      manual step, announced by the app so it's never a mystery).
///   4. This keyboard, on becoming active again, finds the fresh
///      dictation and TYPES it right where the cursor is, then clears it.
///
/// Access truths: reading the App Group needs "Allow Full Access" (OS law
/// — same switch as network, though this code never opens a connection).
/// Without it, the dictation still lands on the CLIPBOARD and the keyboard
/// says so — one long-press paste instead of auto-typing. Never blank,
/// never broken.
///
/// Quick phrases (Aug 4 2026, her redesign): PERSONAL now — each account
/// keeps its own list ("things they say all the time instead of canned
/// crap"), managed in the app (Settings > Kade Keys), mirrored into the
/// App Group, read here offline. The six built-ins survive only as the
/// empty-state fallback so the keyboard is never blank. The hero key says
/// TRANSCRIBE (was "Dictate" — collided with the iPhone's own Dictate
/// button, her report). The Prompt Library still does NOT ride the
/// keyboard (her call, reaffirmed: "I don't really care about prompts").
final class KeyboardViewController: UIInputViewController {
    /// Round 4: one pending visibility-check at a time — tap spam queues one
    /// instruction, not a chorus.
    private var instructionCheckScheduled = false

    private let builtinPhrases: [String] = [
        "Love you!",
        "On my way.",
        "Call me when you can.",
        "Yes",
        "No",
        "Thank you so much.",
    ]

    /// Her own phrases, mirrored from the account by the main app
    /// (kadeKeys.customPhrases.v1). Reading the container needs Full
    /// Access (same OS gate as the dictation handoff); without it, or
    /// before she's added any, the built-ins above keep the keyboard
    /// useful.
    private var phrases: [String] {
        guard hasFullAccess,
              let defaults = UserDefaults(suiteName: "group.com.kademurdock.kadeai"),
              let data = defaults.data(forKey: "kadeKeys.customPhrases.v1"),
              let custom = try? JSONDecoder().decode([String].self, from: data),
              !custom.isEmpty else {
            return builtinPhrases
        }
        return Array(custom.prefix(12))
    }

    private struct SharedDictation: Decodable {
        let text: String
        let at: Date
        let id: String?
    }

    /// Fresh = written in the last 3 minutes. Older leftovers are stale
    /// (she wandered off mid-dance) and get cleared without typing.
    /// Aug 4 2026: also refuses to type the same dictation SESSION twice
    /// (`id` + the lastTyped marker) — the app writes the raw transcript
    /// immediately and may overwrite it with the auto-cleaned version a
    /// few seconds later; if she swiped back fast and this keyboard
    /// already typed the raw take, the cleaned overwrite must not get
    /// typed AGAIN into some later field.
    private func takePendingDictation() -> String? {
        guard hasFullAccess,
              let defaults = UserDefaults(suiteName: "group.com.kademurdock.kadeai"),
              let data = defaults.data(forKey: "kadeKeys.dictation.v1") else {
            return nil
        }
        defaults.removeObject(forKey: "kadeKeys.dictation.v1")
        guard let dictation = try? JSONDecoder().decode(SharedDictation.self, from: data),
              Date().timeIntervalSince(dictation.at) < 180,
              !dictation.text.isEmpty else {
            return nil
        }
        if let id = dictation.id {
            let lastTypedKey = "kadeKeys.lastTypedTake.v1"
            guard defaults.string(forKey: lastTypedKey) != id else { return nil }
            defaults.set(id, forKey: lastTypedKey)
        }
        return dictation.text
    }

    /// Aug 6 2026: her "delete keys and stuff" ask. Deletes trailing
    /// whitespace plus one whole word, mirroring the system's option-delete.
    /// Empty context falls back to a single character delete so the key is
    /// never a dead press.
    private func deleteLastWord() {
        let proxy = textDocumentProxy
        guard let before = proxy.documentContextBeforeInput, !before.isEmpty else {
            proxy.deleteBackward()
            return
        }
        var count = 0
        var sawWord = false
        for ch in before.reversed() {
            if ch.isWhitespace {
                if sawWord { break }
                count += 1
            } else {
                sawWord = true
                count += 1
            }
        }
        for _ in 0 ..< max(count, 1) { proxy.deleteBackward() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        // THE HERO: Transcribe (renamed from "Dictate" Aug 4 2026 — her
        // report: "I can't tell the diff between that and my actual
        // dictate button via system." One name for one feature: this key
        // opens the app's own Transcribe tool.)
        var dictateConfig = UIButton.Configuration.filled()
        dictateConfig.title = "Transcribe"
        dictateConfig.image = UIImage(systemName: "waveform")
        dictateConfig.imagePadding = 8
        dictateConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 8, bottom: 14, trailing: 8)
        // Aug 5 2026 — HER REPORT: "the kade keys transcribe button is not
        // activatable by voiceover." A VO double-tap runs the action through
        // an accessibility-activation context, and the responder-chain
        // openURL: hop (below) can die silently there — a responder answers
        // the selector, quietly refuses, and the old code treated "someone
        // answered" as success, so VO users got a dead key with no sound.
        // Rounds 2-3 (Aug 5, her live reports): explicit
        // accessibilityActivate() stays (VO's canonical hook), and the key
        // now ARMS an App-Group transcribe request + speaks the switch
        // instruction when programmatic opening fails — the full story
        // lives on openDictation below.
        let dictate = KadeActivatableButton(configuration: dictateConfig)
        dictate.accessibilityLabel = "Transcribe"
        dictate.accessibilityHint = hasFullAccess
            ? "Double-tap, then switch to Kade-AI — it'll already be listening. Swipe back here after and your words type themselves."
            : "Double-tap, then open Kade-AI and use Transcribe. Your words land on the clipboard to paste here. Turn on Allow Full Access in Settings and they'll type themselves instead."
        dictate.onActivate = { [weak self] in
            self?.openDictation()
        }
        dictate.addAction(UIAction { [weak self] _ in
            self?.openDictation()
        }, for: .touchUpInside)
        column.addArrangedSubview(dictate)

        // Aug 6 2026 (her build-184 feedback: "the keyboard should have
        // delete keys and stuff... it's just not super intuitive"): the
        // utility row grew a RETURN key and a DELETE-WORD key, and it now
        // sits directly under the hero key VISUALLY AND in VoiceOver order —
        // she never found the old bottom row, so discoverability was the
        // real gap. Phrases follow after.
        let utility = UIStackView()
        utility.axis = .horizontal
        utility.spacing = 8
        utility.distribution = .fillEqually

        let globe = utilityButton(symbol: "globe", label: "Next keyboard")
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        utility.addArrangedSubview(globe)

        let space = utilityButton(symbol: "space", label: "Space")
        space.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(" ")
        }, for: .touchUpInside)
        utility.addArrangedSubview(space)

        let returnKey = utilityButton(symbol: "return", label: "Return")
        returnKey.accessibilityHint = "Types a new line."
        returnKey.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText("\n")
        }, for: .touchUpInside)
        utility.addArrangedSubview(returnKey)

        let backspace = utilityButton(symbol: "delete.left", label: "Delete")
        backspace.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }, for: .touchUpInside)
        utility.addArrangedSubview(backspace)

        let deleteWord = utilityButton(symbol: "delete.left.fill", label: "Delete word")
        deleteWord.accessibilityHint = "Deletes the whole last word."
        deleteWord.addAction(UIAction { [weak self] _ in
            self?.deleteLastWord()
        }, for: .touchUpInside)
        utility.addArrangedSubview(deleteWord)

        column.addArrangedSubview(utility)

        // The phrases, rows of three, AFTER the controls.
        var phraseRows: [UIStackView] = []
        for rowPhrases in stride(from: 0, to: phrases.count, by: 3)
            .map({ Array(phrases[$0 ..< min($0 + 3, phrases.count)]) }) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for phrase in rowPhrases {
                row.addArrangedSubview(phraseButton(phrase))
            }
            column.addArrangedSubview(row)
            phraseRows.append(row)
        }

        // VoiceOver walks: Transcribe first, the control row second, phrases
        // last — controls are one swipe from the hero key now.
        view.accessibilityElements = [dictate, utility] + phraseRows

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            column.heightAnchor.constraint(greaterThanOrEqualToConstant: 216),
        ])
    }

    /// Step 4 of the dance: back from the app, type what she said.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let dictation = takePendingDictation() {
            textDocumentProxy.insertText(dictation)
            UIAccessibility.post(notification: .announcement, argument: "Typed your dictation.")
        }
    }

    /// Step 1: open the app. Keyboards get no UIApplication and no working
    /// extensionContext.open, so this walks the responder chain for the
    /// host's openURL: — the same move every shipping dictation keyboard
    /// makes.
    ///
    /// Aug 5 2026 (the VoiceOver dead-key fix, her report): three changes.
    /// (1) Announce immediately — the key firing is never silent again.
    /// (2) The walk runs on the NEXT run-loop tick: performing openURL:
    ///     synchronously inside a VO accessibility-activation callback is
    ///     the classic silent-rejection spot; deferring one tick puts the
    ///     call back in an ordinary event context.
    /// (3) Honesty about failure: the old code stopped at the FIRST
    ///     responder that merely answered the selector and assumed success.
    ///     Now every responder that answers gets tried, the perform's
    ///     result is checked (openURL: returns a BOOL), and only a truthy
    ///     return counts — anything less falls through to the spoken
    ///     manual-road fallback instead of a dead key.
    private func openDictation() {
        // Aug 5 2026, ROUND 3 — her report on round 2: "I tap transcribe
        // once and it doesn't do anything, and when tapped again it says it
        // couldn't open the kade-ai app." Tap-1 silence convicted round 2's
        // extensionContext.open attempt: in keyboards it's the documented
        // no-op (this file's own June comment said so), and a no-op whose
        // completion never fires means no fallback, no speech, dead air.
        // Tap-2's announcement proved the responder walk honestly fails on
        // this iOS too. So round 3 stops betting on URL magic and builds
        // the flow she herself described from Wispr ("prompts you to swipe
        // and dictate"): the key ARMS a transcribe request in the App Group,
        // still tries the walk (free if some iOS lets it through — the app
        // then opens instantly), and otherwise SPEAKS the switch
        // instruction. The app consumes the armed request the moment it
        // foregrounds (within 3 minutes) and starts listening right away —
        // so "switch to Kade-AI" is the whole manual step, exactly the
        // Wispr dance. Every tap now either opens the app or speaks;
        // silence is impossible by construction.
        // ROUND 5 (Aug 5 evening, her report ON build 183: VO gets out "r—"
        // and dies mid-syllable, and switching to the app finds nothing
        // armed): the "r—" proves round 3 ran and the ARMED sentence began —
        // then the responder walk's side effect SUSPENDED this keyboard
        // (iOS starts a transition it later denies), which (a) killed the
        // speech mid-syllable and (b) most likely killed the UserDefaults
        // flush before it reached disk — extensions flush lazily, so the
        // armed flag EVAPORATED with the suspension. Three consequences
        // built in here:
        //   1. The flag is now ALSO an atomic FILE in the App Group
        //      container (synchronous write, suspension-proof), and
        //      defaults.synchronize() forces the plist flush too.
        //   2. The spoken instruction is scheduled BEFORE the walk runs —
        //      a pending timer survives suspension and fires on resume, so
        //      even a suspended keyboard finishes its sentence when iOS
        //      hands the screen back.
        //   3. The walk goes LAST, as a pure free-win attempt.
        var armed = false
        if hasFullAccess {
            let stamp = Date().timeIntervalSince1970
            if let defaults = UserDefaults(suiteName: "group.com.kademurdock.kadeai") {
                defaults.set(stamp, forKey: "kadeKeys.transcribeRequest.v1")
                defaults.synchronize()
                armed = true
            }
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.kademurdock.kadeai"
            ) {
                let marker = container.appendingPathComponent("kadeKeysTranscribeRequest.txt")
                try? String(stamp).write(to: marker, atomically: true, encoding: .utf8)
                armed = true
            }
        }
        guard let url = URL(string: "kadeai://kadekeys-dictate") else { return }
        let armedNow = armed
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.instructionCheckScheduled {
                self.instructionCheckScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.instructionCheckScheduled = false
                    guard self.view.window != nil else { return } // keyboard gone = app really opened
                    let instruction = armedNow
                        ? "Ready to transcribe. Switch to Kade-AI — it starts listening the moment it opens. Then swipe back here and your words type themselves."
                        : "Open the Kade-AI app and use Transcribe there. Your words will land on the clipboard to paste here."
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: NSAttributedString(
                            string: instruction,
                            attributes: [.accessibilitySpeechQueueAnnouncement: true]
                        )
                    )
                }
            }
            _ = self.performOpenURLWalk(url)
        }
    }

    /// Walks the responder chain trying openURL: on every responder that
    /// answers it. Returns false when the URL provably went through (a
    /// truthy perform result), true when the caller should speak the
    /// fallback. (Inverted so the guard above reads naturally.)
    private func performOpenURLWalk(_ url: URL) -> Bool {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), !(current is KeyboardViewController) {
                let result = current.perform(selector, with: url)
                if result != nil {
                    return false
                }
            }
            responder = current.next
        }
        return true
    }

    private func phraseButton(_ phrase: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = phrase
        config.titleLineBreakMode = .byWordWrapping
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6)
        let button = UIButton(configuration: config)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.accessibilityLabel = phrase
        button.accessibilityHint = "Types this phrase."
        button.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(phrase)
        }, for: .touchUpInside)
        return button
    }

    private func utilityButton(symbol: String, label: String) -> UIButton {
        var config = UIButton.Configuration.tinted()
        if symbol == "space" {
            config.title = "Space"
        } else {
            config.image = UIImage(systemName: symbol)
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        return button
    }
}
