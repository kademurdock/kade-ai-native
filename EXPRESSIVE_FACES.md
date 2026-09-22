# Expressive faces — September 22, 2026

Adds eight additional facial expressions for each of Kiana, Della, Lilly and Harley. Original sheet indices and artwork remain unchanged. The four new `Character*Nuance` assets use the existing 1254px, 414px-cell, 420px-pitch layout. New expression raw values 9–16 select nuance panels 1–8.

Listening and thinking can use the curious and thoughtful faces when no emotional direction is active. Speaking continues to follow the existing delivery cues. Individual movement rhythms, periodic nods and subtle breathing replace the stage's large syllable zoom; the stage multiplier is 1.6 instead of 6 because the pose itself now supplies more motion. Quiet/serious emotions reduce the extra movement. Existing motion, visibility and scene controls remain in place.

Tests updated in `CharacterMotionTests/main.swift` for the new faces, real character motion bounds, and silence. Swift and Xcode are unavailable on this Windows host, so these native changes have not been compiled or device-tested. The equivalent web renderer and generated sheets have been inspected in a local browser. No paid Codemagic build or TestFlight release has been started.
