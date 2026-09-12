import SwiftUI
import AVFoundation

@MainActor final class Probe: ObservableObject {
    var player: AVAudioPlayer?
    func start() async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var result: [String: Any] = [:]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let audio = try AVAudioPlayer(contentsOf: Bundle.main.url(forResource: "tone", withExtension: "wav")!)
            player = audio; audio.isMeteringEnabled = true
            let started = audio.play()
            try await Task.sleep(nanoseconds: 400_000_000)
            audio.updateMeters()
            result = ["passed": started && audio.currentTime > 0.1 && audio.averagePower(forChannel: 0) > -60,
                "currentTime": audio.currentTime, "power": audio.averagePower(forChannel: 0)]
            audio.stop()
        } catch { result = ["passed": false, "error": error.localizedDescription] }
        try? JSONSerialization.data(withJSONObject: result).write(to: folder.appendingPathComponent("audio-probe.json"))
    }
}
@main struct AudioProbe: App {
    @StateObject var probe = Probe()
    var body: some Scene { WindowGroup { Text("Offline audio setup probe").task { await probe.start() } } }
}
