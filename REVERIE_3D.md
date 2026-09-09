# Reverie miniature world

HELD at Kade's request on September 9, 2026: wait on the iPhone build. Run 6aa10c0d11228e03785d722a was canceled during machine preparation, before source checkout or compilation. No new IPA or TestFlight upload was produced. Do not start another build or merge this branch into main without a new instruction. The existing iPhone build 280 remains the released baseline.

The World screen renders its current room and people using an offline, bundled Three.js 0.186.0 scene. The scene never receives credentials, requests game state, plays sound, or sends commands. The same renderer source ships in LibreChat/client/public/assets/reverie. Sources/Reverie/ReverieStage.html is a minified IIFE bundle; mural.webp is original GPT-generated wall art. MIT dependency attribution is bundled beside it.

World settings contains Room picture, World motion, and Describe the picture. Graphics are accessibility-hidden and cannot intercept gestures. Existing SwiftUI controls, text, audio and the single announcement path remain authoritative. Reduce Motion, Low Power Mode, leaving the screen and backgrounding stop animation. Turning pictures off removes the WebKit view. A WebKit or WebGL failure leaves the world controls working. The description explicitly identifies the layout as illustrative and figures as stand-ins, not the final character-customization system.

Room decoding adds optional furniture, home and sensory fields; older payloads still decode. The renderer gets current room occupants and HUD weather/darkness. Resident Reply choices honor the compose flag and preserve existing command drafts.

Validation: WorldModelsTests compiles and executes on Linux; the speech regression is unchanged. A local browser checks the bundled renderer independently from the web module. Full iOS compilation and resource packaging remain unverified while the build is held. VoiceOver, actual phone frame rate, thermal/battery behavior and listening remain device acceptance work.
