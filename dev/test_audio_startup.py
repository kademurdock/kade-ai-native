"""Source contract checks; no iOS compilation, hardware or network is exercised."""
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE_REF = "9c8e2e82f382addd4631c2ab9fded8574ab9a053"
BASELINE = "--baseline" in sys.argv
if BASELINE:
    sys.argv.remove("--baseline")


def source(name, baseline=False):
    if baseline:
        return subprocess.check_output(["git", "show", f"{BASELINE_REF}:{name}"], cwd=ROOT, encoding="utf-8")
    return (ROOT / name).read_text(encoding="utf-8")


def method(text, name):
    found = re.search(r"\bfunc\s+" + re.escape(name) + r"\s*\(", text)
    assert found, f"Missing method: {name}"
    start = text.index("{", found.end())
    depth = 1
    for index in range(start + 1, len(text)):
        depth += (text[index] == "{") - (text[index] == "}")
        if depth == 0:
            body = text[start + 1:index]
            return re.sub(r"/\*[\s\S]*?\*/|//[^\n]*", "", body)
    raise AssertionError(f"Unclosed method: {name}")


FEEDBACK = source("Sources/KadeFeedback.swift", BASELINE)
EARCONS = FEEDBACK[FEEDBACK.index("final class Earcons {"):]
PREVIOUS = source("Sources/KadeFeedback.swift", True)
PREVIOUS_EARCONS = PREVIOUS[PREVIOUS.index("final class Earcons {"):]


class AudioStartupTests(unittest.TestCase):
    def test_launch_prewarm_only_caches_data(self):
        warm = method(EARCONS, "prewarm")
        self.assertIn("Self.renderWAV", warm)
        self.assertIn("Data(contentsOf: url)", warm)
        self.assertNotRegex(warm, r"AVAudioPlayer|AVAudioSession|prepareToPlay|setActive|setCategory|\.play\(")
        app = source("Sources/KadeAIApp.swift", BASELINE)
        self.assertIn("Earcons.shared.prewarm()", app)
        self.assertNotRegex(app, r"setActive\(|setCategory\(")

    def test_actual_feedback_only_selects_an_untouched_mixing_profile(self):
        setup = method(EARCONS, "prepareFeedbackSession")
        self.assertRegex(setup, r"guard session\.category == \.soloAmbient else\s*\{\s*return true\s*\}")
        self.assertIn("session.setCategory(.ambient, mode: .default)", setup)
        self.assertLess(setup.index("guard session.category"), setup.index("setCategory"))
        self.assertRegex(setup, r"catch\s*\{[\s\S]*return false")
        self.assertNotRegex(setup, r"setActive|duckOthers|interruptSpokenAudio|overrideOutputAudioPort|setPreferredInput|volume")

    def test_every_feedback_entry_checks_before_acquiring_audio_hardware(self):
        for name in ("fire", "startWaitingLoop", "playRoomChime"):
            body = method(EARCONS, name)
            self.assertLess(body.index("guard prepareFeedbackSession() else { return }"), body.index("AVAudioPlayer("), name)
            self.assertIn("player.prepareToPlay()", body)
            if name != "fire":
                self.assertLess(body.index("guard FeedbackPrefs.shared.soundEffects"), body.index("prepareFeedbackSession"), name)
        play = method(EARCONS, "play")
        self.assertLess(play.index("guard FeedbackPrefs.shared.soundEffects"), play.index("Task { @MainActor"))
        self.assertIn("self.fire(earcon)", play)

    def test_feedback_keeps_existing_sound_levels_and_does_not_deactivate_other_owners(self):
        for name in ("fire", "startWaitingLoop", "playRoomChime", "duckWaitingLoop"):
            current = method(EARCONS, name)
            previous = method(PREVIOUS_EARCONS, name)
            levels = r"\b(?:player|p)\.(?:volume\s*=\s*[^\n]+|setVolume\([^\n]+)"
            self.assertEqual(re.findall(levels, current), re.findall(levels, previous), name)
        self.assertNotRegex(EARCONS, r"setActive\(|MPVolumeView|outputVolume\s*=")
        for filename in ("Sources/VoiceService.swift", "Sources/StreamingClipPlayer.swift"):
            self.assertIn("session.setCategory(.playback, mode: .default, options: [.mixWithOthers])", source(filename))

    def test_existing_haptics_only_startup_and_ui_audit_gate_remain(self):
        haptics = FEEDBACK[FEEDBACK.index("final class KadeHapticEngine {"):FEEDBACK.index("final class Earcons {")]
        setup = method(haptics, "makeEngine")
        self.assertLess(setup.index("fresh.playsHapticsOnly = true"), setup.index("fresh.start()"))
        app = source("Sources/KadeAIApp.swift", BASELINE)
        self.assertRegex(app, r"if !KadeUITestMode\.skipsAudioWarmup\s*\{\s*Earcons\.shared\.prewarm\(\)\s*KadeHapticEngine\.shared\.prewarm\(\)")


if __name__ == "__main__":
    unittest.main()
