# Character presentation, 2.2.8 candidate

The call screen now scrolls captions, camera and secondary actions above a fixed
Mute/Hang Up footer. Those two controls stack at accessibility text sizes and
keep a minimum 44-point target. The character portrait uses the actual call
window width. The chat portrait shrinks to 104 points for accessibility text
and 84 while typing or in a compact vertical size class. The app still declares
portrait orientation; no new rotation support is claimed.

An optional Describe character button in chat and call opens the reviewed
current-portrait description. It uses the same exact agent/avatar filename
registration as the picker. The requested name and text are captured together;
an agent or avatar change dismisses the alert. Call handoff hides the original
character's appearance action and updates the navigation title to the Spotter.
Artwork, figure registration, expression motion, audio and speech are unchanged.

Local Windows checks: Swift tree-sitter syntax parsing of all eight affected
Swift files, Python script compilation, five existing audio-startup source
checks, two signed-receipt tests, the59-picture art-word gate, YAML/workflow
invariants, seven generated workflow scripts and character-runner Bash syntax,
and git whitespace checks passed. These are not Swift compilation or device
acceptance. One hundred new Foundation layout checks join run-character-tests.sh.

The exact-source ios-character-polish-release workflow is bounded to25 minutes.
It runs the existing Foundation gates, the existing offline playback/portrait
simulator audit, and two screenshots of the actual CallView with invented
captions (light/default text and dark/largest accessibility text). Its DEBUG
fixture returns before starting a call; it does not sign in, open a microphone
or make a provider request. The screenshots require visual review. The same
run produces one signed archive and upload-recovery receipt. Automatic tester
distribution and notification are off; the App Store tour is absent. Physical
VoiceOver focus, controls, audio and actual phone-size appearance remain device
checks. No new figure artwork is registered by this candidate.
