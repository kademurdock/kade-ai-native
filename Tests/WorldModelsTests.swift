import Foundation

@main enum WorldModelsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let action = try decoder.decode(WorldAction.self, from: Data(#"{"label":"Look","cmd":"look"}"#.utf8))
        precondition(action.id == "look" && action.hint == nil && action.group == nil)
        let exit = try decoder.decode(WorldExit.self, from: Data(#"{"dir":"n","label":"north","to":"Lantern Row","locked":true}"#.utf8))
        precondition(exit.command == "go n" && exit.spokenLabel == "North to Lantern Row, locked")
        let hud = try decoder.decode(WorldHUD.self, from: Data(#"{"name":"Ruby Tester","coin":20,"clock":"Morning","mode":"create"}"#.utf8))
        precondition(hud.meters == nil && hud.coin == 20)
        let meter = try decoder.decode(WorldHUD.Meter.self, from: Data(#"{"key":"fed","value":42,"word":"peckish"}"#.utf8))
        precondition(meter.spokenValue == "42 out of 100, peckish")
        let stream = try decoder.decode(WorldStreamUpdate.self, from: Data(#"{"cursor":42,"events":[{"seq":42,"kind":"say","text":"Bea says hello","sound":null}]}"#.utf8))
        precondition(stream.cursor == 42 && stream.events?.first?.seq == 42)
        let end = try decoder.decode(WorldStreamUpdate.self, from: Data(#"{"end":"no character"}"#.utf8))
        precondition(end.events == nil && end.end == "no character")
        let a = URL(string: "https://example.invalid/reverie-sounds/door.m4a?X-Amz-Date=one&X-Amz-Signature=old&versionId=v1")!
        let b = URL(string: "https://example.invalid/reverie-sounds/door.m4a?versionId=v1&X-Amz-Date=two&X-Amz-Signature=new")!
        precondition(WorldSoundIdentity.cacheIdentity(a) == WorldSoundIdentity.cacheIdentity(b))
        let changed = URL(string: "https://example.invalid/reverie-sounds/door.m4a?versionId=v2")!
        precondition(WorldSoundIdentity.cacheIdentity(a) != WorldSoundIdentity.cacheIdentity(changed))
        let other = URL(string: "https://example.invalid/reverie-sounds/coin.m4a?versionId=v1")!
        precondition(WorldSoundIdentity.cacheIdentity(a) != WorldSoundIdentity.cacheIdentity(other))
        precondition(WorldSoundIdentity.cacheIdentity(a, revision: "installed-1") == WorldSoundIdentity.cacheIdentity(b, revision: "installed-1"))
        precondition(WorldSoundIdentity.cacheIdentity(a, revision: "installed-1") != WorldSoundIdentity.cacheIdentity(a, revision: "installed-2"))
        print("World models: 11 checks passed. This checks decoding and cache identity, not VoiceOver playback.")
    }
}
