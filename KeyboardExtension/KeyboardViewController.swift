import UIKit

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
/// The six quick phrases stay as compact secondary rows (her call: fine
/// "if they help the sighted or whatever"); the Prompt Library does NOT
/// ride the keyboard (her call, same breath).
final class KeyboardViewController: UIInputViewController {
    private let phrases: [String] = [
        "Love you!",
        "On my way.",
        "Call me when you can.",
        "Yes",
        "No",
        "Thank you so much.",
    ]

    private struct SharedDictation: Decodable {
        let text: String
        let at: Date
    }

    /// Fresh = written in the last 3 minutes. Older leftovers are stale
    /// (she wandered off mid-dance) and get cleared without typing.
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
        return dictation.text
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        // THE HERO: Dictate.
        var dictateConfig = UIButton.Configuration.filled()
        dictateConfig.title = "Dictate"
        dictateConfig.image = UIImage(systemName: "mic.fill")
        dictateConfig.imagePadding = 8
        dictateConfig.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 8, bottom: 14, trailing: 8)
        let dictate = UIButton(configuration: dictateConfig)
        dictate.accessibilityLabel = "Dictate"
        dictate.accessibilityHint = hasFullAccess
            ? "Opens Kade-AI to take your words. Swipe back here after and they type themselves."
            : "Opens Kade-AI to take your words. They'll land on your clipboard to paste here. Turn on Allow Full Access in Settings and they'll type themselves instead."
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
    /// makes. If it fails (a host app that blocks it), the hint text has
    /// already told her the manual road: open Kade-AI, use Quick Dictate.
    private func openDictation() {
        guard let url = URL(string: "kadeai://kadekeys-dictate") else { return }
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), !(current is KeyboardViewController) {
                _ = current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: "Couldn't open Kade-AI from here. Open the app and use Quick Dictate."
        )
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
