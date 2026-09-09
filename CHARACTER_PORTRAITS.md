# Voice-message portraits — session 168

Saved and arriving voice replies share a native SwiftUI portrait. Exact message author or the actual playing clip selects the authenticated roster entry. Missing authors/portraits use a monogram, never another character. Kiana facial patches require both her agent ID and the matching approved portrait filename. Other agents keep their own portrait with subtle movement; they do not borrow her mouth or eyes.

Settings > Feedback & Sounds > Animated voice portraits defaults on. Reduce Motion, Low Power Mode, backgrounding and offscreen disposal stop animation. This isolated decorative view can animate with VoiceOver enabled; it has no accessibility elements or per-frame transcript writes. The user's original transcript and play/pause controls stay authoritative.

Buffered replies read AVAudioPlayer meters; streaming replies summarize the actual scheduled PCM against the player source clock. Pausing freezes that clock; gaps/out-of-range samples close the mouth. No second player, microphone tap, TTS request, or change to synthesis/audio bytes. Mouth opening is amplitude-based, not phoneme lip sync.

Run bash run-character-tests.sh and bash run-speech-tests.sh. Character tests compile real Foundation code; bounds are additionally sampled across three identities. Full SwiftUI/AVFoundation compile needs Xcode. Device listening, Bluetooth, VoiceOver focus and battery acceptance remain separate from compile results. The approved original Kiana art, mouth atlas and closed-eye source come from the held LibreChat character work; no new paid generation.

This increment covers native voice messages. Native call metadata integration and individualized facial artwork for Della, Lilly and other characters remain future work. Do not promote private personal agent data into shared artwork or personas.
