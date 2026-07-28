import UIKit

/// KADE KEYS v1 (July 28 2026, un-parked by Kade: "Attempt it, separate
/// build") — a deliberately SMALL custom keyboard whose whole job tonight
/// is to prove the pipeline: second target, second bundle id, second
/// provisioning profile, one build, TestFlight. The useful payload comes
/// after the pipe is proven.
///
/// Scope fences, all three deliberate:
/// - NO microphone. iOS hard-blocks mic access inside keyboard extensions
///   at the OS level (the session-16 research note; Wispr Flow's keyboard
///   has to bounce out to its app for exactly this reason). Voice input
///   stays Quick Dictate's job in the main app.
/// - NO network. That would need RequestsOpenAccess=true and the scary
///   "Allow Full Access" prompt; v1 stays fully offline so the privacy
///   story is one sentence: this keyboard sends nothing anywhere.
/// - NO App Group yet. Syncing the Prompt Library in here needs a shared
///   container entitlement on BOTH bundle ids — that's phase 2, only
///   worth wiring once tonight proves signing works at all.
///
/// What it DOES do: one row of big, VoiceOver-labeled quick phrases that
/// type themselves into whatever app is open, a backspace, a space, and
/// the system-required next-keyboard globe. Every control is a real
/// UIButton with a spoken label — no custom hit-testing, nothing clever.
final class KeyboardViewController: UIInputViewController {
    private let phrases: [String] = [
        "Love you!",
        "On my way.",
        "Call me when you can.",
        "Yes",
        "No",
        "Thank you so much.",
    ]

    override func viewDidLoad() {
        super.viewDidLoad()

        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 8
        column.distribution = .fillEqually
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        // Two rows of three phrases.
        for rowPhrases in stride(from: 0, to: phrases.count, by: 3).map({ Array(phrases[$0 ..< min($0 + 3, phrases.count)]) }) {
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
            column.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
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
