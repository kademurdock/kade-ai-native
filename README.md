# kade-ai-native

Native SwiftUI iOS app for Kade-AI — the polished core (chat, voice, push) talking to the
existing LibreChat backend at kademurdock.com. The web app remains the full-featured workhorse;
this app links out for anything not built natively. Accessibility (VoiceOver) is priority #1.

- Bundle id: com.kademurdock.kadeai (same TestFlight app as the Capacitor shell; native builds
  are version 2.0, build 100+ so testers always see them as the newest build).
- Project is generated from `project.yml` by XcodeGen in CI — no .xcodeproj is committed.
- CI: `codemagic.yaml`, workflow `ios-native-testflight` → internal TestFlight (no Apple review).
- Endpoint documentation as confirmed: `docs/ENDPOINTS.md`.

The Capacitor app (kademurdock/kade-ai-app) stays intact as the fallback.
