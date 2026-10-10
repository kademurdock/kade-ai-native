import Foundation

func runCharacterDellaHostLayoutChecks(_ check: (Bool, String) -> Void) {
    let layout = CharacterDellaHostLayout.self
    func square(_ side: Double) -> CharacterDellaHostStage {
        CharacterDellaHostStage(side: side, portraitHeight: side, articulated: false)
    }
    func chat(side: Double = 208, height: Double = 932, keyboard: Bool = false,
              editing: Bool = false, compact: Bool = false, accessibility: Bool = false,
              competing: Bool = false, eligible: Bool = true) -> CharacterDellaHostStage {
        layout.chat(preferredSide: side, availableHeight: height, keyboard: keyboard,
            editing: editing, compactHeight: compact, accessibilityText: accessibility,
            competingControls: competing, candidateEligible: eligible)
    }
    func call(side: Double = 160, height: Double = 800, camera: Bool = false,
              accessibility: Bool = false, eligible: Bool = true) -> CharacterDellaHostStage {
        layout.call(preferredSide: side, availableHeight: height, camera: camera,
            accessibilityText: accessibility, candidateEligible: eligible)
    }

    // Unapproved art, a different speaker, or a missing resource must retain
    // the caller's exact established square frame even in constrained modes.
    for side in [84.0, 104, 132, 160, 176, 208] {
        check(chat(side: side, keyboard: true, editing: true, compact: true,
            accessibility: true, competing: true, eligible: false) == square(side),
            "An ineligible chat candidate preserves its existing square preference")
        check(call(side: side, camera: true, accessibility: true, eligible: false) == square(side),
            "An ineligible call candidate preserves its existing square preference")
    }

    check(chat(keyboard: true) == square(84), "The keyboard retains compact transcript room")
    check(chat(editing: true) == square(84), "Composer focus shrinks before the keyboard notification")
    check(chat(compact: true) == square(84), "A compact-height chat cannot reserve a tall puppet")
    check(chat(keyboard: true, accessibility: true, competing: true) == square(84),
        "Keyboard space takes priority over the larger compact accessibility frame")
    check(chat(accessibility: true) == square(104), "Accessibility text leaves room for growing controls")
    check(chat(competing: true) == square(104), "Attachments, errors and invitation controls retain transcript room")

    check(chat(height: 859.999) == square(208), "Tall chat stays disabled just below its available-height boundary")
    check(chat(height: 860).articulated, "A roomy chat opts in at the exact available-height boundary")
    check(chat(side: 159.999) == square(159.999), "Tall framing cannot shrink Della below the readable face width")
    let minimumChat = chat(side: 160, height: 860)
    check(minimumChat.articulated && minimumChat.side == 160
        && abs(minimumChat.portraitHeight - 239.6135265700483) < 0.000001,
        "The minimum tall chat preserves face width and the approved 414-by-620 viewport")
    let largeChat = chat(height: 860)
    check(largeChat.side == 208 && abs(largeChat.frameHeight - 351.4975845410628) < 0.000001,
        "The host reserves all of the 208-point tall portrait and its single 40-point chrome")

    check(call(height: 739.999) == square(160), "A shorter call retains its approved square framing")
    check(call(height: 740).articulated, "Tall voice-only calling starts at the exact window-height boundary")
    check(call(side: 132, height: 932) == square(132), "The existing compact-call preference remains square")
    check(call(camera: true) == square(104), "Camera preview space takes priority over the decorative body")
    check(call(accessibility: true) == square(104), "Large call controls keep their compact character frame")
    check(call(side: 208, height: 932) == chat(height: 932),
        "Call and chat reserve the same approved body geometry for the same eligible width")
    check(square(208).frameHeight == 248, "Square fallbacks retain the established stage chrome exactly once")

    for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
        check(chat(side: invalid) == square(104) && call(side: invalid) == square(104),
            "Invalid preferred widths resolve to a finite compact square")
        check(chat(height: invalid) == square(208) && call(height: invalid) == square(160),
            "Unknown or invalid host height never enables tall art or changes a valid preferred square")
    }
    let overflowing = call(side: Double.greatestFiniteMagnitude, height: 932)
    check(!overflowing.articulated && overflowing.portraitHeight.isFinite && overflowing.frameHeight.isFinite,
        "An overflowing tall aspect calculation falls back to a finite square")
}
