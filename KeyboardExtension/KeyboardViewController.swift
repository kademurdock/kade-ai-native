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
        // Fix, round 2 (Aug 5 later — her report on round 1: the spoken
        // breadcrumb got cut off and the app still didn't open): explicit
        // accessibilityActivate() path on the key (KadeActivatableButton —
        // VO's canonical activation hook, no synthesized-touch dependence),
        // NO speech on the happy path (the app opening IS the feedback,
        // Wispr-style), extensionContext.open attempted first with its
        // completion as truth, responder-chain walk as fallback, and one
        // QUEUED teaching announcement only on real failure — see
        // openDictation below.
        let dictate = KadeActivatableButton(configuration: dictateConfig)
        dictate.accessibilityLabel = "Transcribe"
        dictate.accessibilityHint = hasFullAccess
            ? "Opens Kade-AI to take your words. Swipe back here after and they type themselves."
            : "Opens Kade-AI to take your words. They'll land on your clipboard to paste here. Turn on Allow Full Access in Settings and they'll type themselves instead."
        dictate.onActivate = { [weak self] in
            self?.openDictation()
        }
        dictate.addAction(UIAction { [weak self] _ in
            self?.openDictation()
        }, for: .touchUpInside)
        column.addArrangedSubview(dictate)

        // The six phrases, two compact rows of three.
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
        }

        // Utility row: globe (required), space, backspace.
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

        let backspace = utilityButton(symbol: "delete.left", label: "Delete")
        backspace.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }, for: .touchUpInside)
        utility.addArrangedSubview(backspace)

        column.addArrangedSubview(utility)

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
        // Aug 5 2026, round 2 (her report: "voiceover wants to tell me
        // something, but it gets interrupted, transcribe ends up not
        // working"). Round 1's pre-announcement collided with the failure
        // announcement and the app-open transition — so NO speech on the
        // happy path at all now (the app opening and landing on Transcribe
        // IS the feedback, Wispr-style). Attempt order: extensionContext
        // .open first (some hosts allow it for the containing app's own
        // scheme; its completion is authoritative), then the responder-chain
        // walk, and only on REAL failure one queued announcement that
        // teaches the manual road — queued, so VoiceOver finishes its
        // current utterance instead of being cut off mid-word.
        guard let url = URL(string: "kadeai://kadekeys-dictate") else { return }
        if let context = extensionContext {
            context.open(url) { [weak self] success in
                if success { return }
                DispatchQueue.main.async { self?.fallBackToResponderWalk(url) }
            }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.fallBackToResponderWalk(url) }
    }

    private func fallBackToResponderWalk(_ url: URL) {
        if !performOpenURLWalk(url) { return }
        let instruction = NSAttributedString(
            string: "Transcribe couldn't open Kade-AI by itself. Open the Kade-AI app, use Transcribe there, then swipe back here — your words will type themselves.",
            attributes: [.accessibilitySpeechQueueAnnouncement: true]
        )
        UIAccessibility.post(notification: .announcement, argument: instruction)
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
