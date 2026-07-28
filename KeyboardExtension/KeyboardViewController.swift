import UIKit

/// KADE KEYS (July 28 2026) — phase 2: the real Prompt Library, offline.
///
/// v1 (build 167) existed to prove the second-target signing pipe and
/// shipped six canned phrases. Phase 2 wires the App Group
/// (group.com.kademurdock.kadeai): the main app's Prompt Library mirrors
/// its first prompts (title + live text) into the shared container
/// (KadeKeysSharedStore, written when the Prompts screen is opened), and
/// this keyboard reads them back and TYPES them — her actual saved
/// prompts, in Messages or anywhere else, no round-trip to the app.
///
/// Scope fences that still stand, and one that moved:
/// - NO microphone, still: iOS hard-blocks mic access inside keyboard
///   extensions at the OS level. Voice input stays Quick Dictate's job.
/// - NO network CALLS, still: this code never opens a connection. But the
///   OS gate for reading a shared container is the SAME switch as the
///   network gate — RequestsOpenAccess is now true, and the person must
///   flip "Allow Full Access" in Settings before the library shows up
///   (Apple's capability table; there is no container-only permission).
///   Without the switch — or before the library has ever been mirrored —
///   the six built-in phrases below are the graceful floor, so the
///   keyboard is never blank and never broken.
/// - Every control is a real UIButton with a spoken label — no custom
///   hit-testing, nothing clever. Saved prompts scroll in a plain
///   UIScrollView (VoiceOver handles those natively) with the utility
///   row pinned beneath, always reachable.
final class KeyboardViewController: UIInputViewController {
    /// The v1 phrases — now the FALLBACK when the shared library is
    /// unreadable (no full access, or never mirrored yet).
    private let fallbackPhrases: [String] = [
        "Love you!",
        "On my way.",
        "Call me when you can.",
        "Yes",
        "No",
        "Thank you so much.",
    ]

    /// Mirror of KadeKeysSharedStore.SharedPrompt — decoupled on purpose
    /// (the store type lives in the app target; the JSON is the contract).
    private struct SharedPrompt: Decodable {
        let title: String
        let text: String
    }

    private func loadSharedPrompts() -> [SharedPrompt] {
        guard hasFullAccess,
              let defaults = UserDefaults(suiteName: "group.com.kademurdock.kadeai"),
              let data = defaults.data(forKey: "kadeKeys.prompts.v1"),
              let prompts = try? JSONDecoder().decode([SharedPrompt].self, from: data),
              !prompts.isEmpty else {
            return []
        }
        return prompts
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        let prompts = loadSharedPrompts()
        if prompts.isEmpty {
            // Fallback floor: the six built-ins, two rows of three, exactly
            // as v1 shipped them.
            for rowPhrases in stride(from: 0, to: fallbackPhrases.count, by: 3)
                .map({ Array(fallbackPhrases[$0 ..< min($0 + 3, fallbackPhrases.count)]) }) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                row.distribution = .fillEqually
                for phrase in rowPhrases {
                    row.addArrangedSubview(phraseButton(title: phrase, inserts: phrase, hint: "Types this phrase."))
                }
                column.addArrangedSubview(row)
            }
        } else {
            // The real library: prompt titles two to a row (titles run
            // long), scrollable when the set outgrows the surface.
            let promptColumn = UIStackView()
            promptColumn.axis = .vertical
            promptColumn.spacing = 8
            promptColumn.translatesAutoresizingMaskIntoConstraints = false

            for rowPrompts in stride(from: 0, to: prompts.count, by: 2)
                .map({ Array(prompts[$0 ..< min($0 + 2, prompts.count)]) }) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                row.distribution = .fillEqually
                for prompt in rowPrompts {
                    row.addArrangedSubview(
                        phraseButton(title: prompt.title, inserts: prompt.text, hint: "Types this saved prompt.")
                    )
                }
                promptColumn.addArrangedSubview(row)
            }

            let scroll = UIScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(promptColumn)
            NSLayoutConstraint.activate([
                promptColumn.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                promptColumn.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                promptColumn.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                promptColumn.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                promptColumn.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 236),
                scroll.heightAnchor.constraint(equalTo: promptColumn.heightAnchor).withPriority(.defaultHigh),
            ])
            column.addArrangedSubview(scroll)
        }

        // Utility row: globe (required), space, backspace — pinned under
        // the phrases, never scrolled away.
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
            column.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    private func phraseButton(title: String, inserts text: String, hint: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.titleLineBreakMode = .byWordWrapping
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6)
        let button = UIButton(configuration: config)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.accessibilityLabel = title
        button.accessibilityHint = hint
        button.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(text)
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

private extension NSLayoutConstraint {
    /// Fluent priority helper — lets the "hug the content when it's
    /// short" height constraint yield to the 236pt cap when it isn't.
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
