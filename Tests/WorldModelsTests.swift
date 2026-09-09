import Foundation

@main enum WorldModelsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let action = try decoder.decode(WorldAction.self, from: Data(#"{"label":"Look","cmd":"look"}"#.utf8))
        precondition(action.id == "look" && action.hint == nil && action.group == nil)
        let person = try decoder.decode(WorldPerson.self, from: Data(#"{"id":"p","name":"Mira","kind":"player","appearance":{"build":"solid","hair":"locs","style":"denim"}}"#.utf8))
        precondition(person.appearance?.hair == "locs")
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
        let reply = try decoder.decode(WorldAction.self, from: Data(#"{"label":"Reply to Pat","cmd":"reply ","compose":true}"#.utf8))
        precondition(reply.compose == true)
        let picture = try decoder.decode(WorldPictureRoom.self, from: Data(#"{"roomId":"reedbank_creek","name":"Reedbank Creek","desc":"Water over stones","outdoor":true,"sensory":{"nature":true,"water":"river"},"peopleDetail":[{"id":"npc:test","name":"Pat","kind":"citizen"}]}"#.utf8))
        precondition(picture.sensory?.water == "river" && picture.furniture == nil)
        let snapshot = WorldPictureSnapshot(room: picture, hud: hud)
        let encoded = try JSONEncoder().encode(snapshot)
        let roundtrip = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition((roundtrip["room"] as? [String: Any])?["roomId"] as? String == "reedbank_creek")
        let oldRoom = try decoder.decode(WorldPictureRoom.self, from: Data(#"{"name":"Room","desc":"Old room"}"#.utf8))
        precondition(oldRoom.sensory == nil && oldRoom.home == nil && oldRoom.peopleDetail == nil)
        let night = try decoder.decode(WorldHUD.self, from: Data(#"{"name":"Alex","dark":true,"weather":"snow"}"#.utf8))
        precondition(night.dark == true && night.weather == "snow")
        print("World models: 16 checks passed. This checks decoding and cache identity, not VoiceOver playback or WebKit rendering.")
    }
}
