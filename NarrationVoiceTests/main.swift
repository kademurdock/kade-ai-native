import Foundation

let choices = ["Clear warm voice · cedarbrook", "Bright voice · silversky"]
precondition(NarrationVoiceChoice.retaining("Voice 1", fallback: choices[0], choices: choices) == "Voice 1")
precondition(NarrationVoiceChoice.retaining("Old Fish voice", fallback: choices[0], choices: []) == "Old Fish voice")
precondition(NarrationVoiceChoice.retaining(nil, fallback: "Voice 1", choices: choices) == "Voice 1")
precondition(NarrationVoiceChoice.retaining(nil, fallback: nil, choices: choices) == choices[0])
precondition(NarrationVoiceChoice.isKnown("Voice 1", choices: choices, retained: ["Voice 1"]))
precondition(!NarrationVoiceChoice.isKnown("Unknown", choices: choices, retained: ["Voice 1"]))
precondition(choices == ["Clear warm voice · cedarbrook", "Bright voice · silversky"])
print("Narration voice retention: 7 checks passed")
