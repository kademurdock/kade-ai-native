import AVFoundation
import LiveKit

/// Play the decoded music channels before WebRTC's mono voice mixer.
/// Used only with headphones; microphone/voice playback remain with LiveKit.
final class ClubhouseMusicRenderer: NSObject, AudioRenderer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Kade.Clubhouse.music")
    private let lock = NSLock()
    private var active = true
    private var bufferedSeconds = 0.0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var volume: Float
    private var reported = false
    private let onPlayback: @Sendable (Bool) -> Void

    init(volume: Double, onPlayback: @escaping @Sendable (Bool) -> Void) {
        self.volume = Float(volume)
        self.onPlayback = onPlayback
        super.init()
    }

    func setVolume(_ value: Double) {
        queue.async { [self] in
            volume = Float(value)
            player?.volume = volume
        }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let seconds = Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock()
        guard active, bufferedSeconds + seconds <= 0.5 else { lock.unlock(); return }
        bufferedSeconds += seconds
        lock.unlock()

        // SDK-owned buffers may be reused after this callback. Copy now, before
        // handing work to our queue, and bound pending audio to half a second.
        guard let copy = AVAudioPCMBuffer(pcmFormat: pcmBuffer.format,
                                         frameCapacity: pcmBuffer.frameLength) else {
            release(seconds)
            return
        }
        copy.frameLength = pcmBuffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { release(seconds); return }
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData,
                  target[index].mDataByteSize >= source[index].mDataByteSize else {
                release(seconds)
                return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        queue.async { [self] in play(copy, seconds: seconds) }
    }

    private func release(_ seconds: Double) {
        lock.lock()
        bufferedSeconds = max(0, bufferedSeconds - seconds)
        lock.unlock()
    }

    private func play(_ input: AVAudioPCMBuffer, seconds: Double) {
        lock.lock()
        let shouldPlay = active
        lock.unlock()
        guard shouldPlay else { release(seconds); return }
        guard input.format.channelCount == 2 else { fail(); release(seconds); return }
        do {
            if engine == nil || inputFormat != input.format {
                player?.stop()
                engine?.stop()
                let next = AVAudioEngine()
                let node = AVAudioPlayerNode()
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: input.format.sampleRate,
                                                 channels: 2, interleaved: false),
                      next.outputNode.outputFormat(forBus: 0).channelCount >= 2,
                      let convert = AVAudioConverter(from: input.format, to: format) else {
                    fail(); release(seconds); return
                }
                next.attach(node)
                next.connect(node, to: next.mainMixerNode, format: format)
                node.volume = volume
                try next.start()
                node.play()
                engine = next
                player = node
                converter = convert
                inputFormat = input.format
            }
            guard let converter, let player,
                  let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                                frameCapacity: input.frameLength) else {
                fail(); release(seconds); return
            }
            try converter.convert(to: output, from: input)
            player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.release(seconds)
            }
            if !reported { reported = true; onPlayback(true) }
        } catch {
            fail()
            release(seconds)
        }
    }

    private func fail() {
        lock.lock()
        active = false
        lock.unlock()
        player?.stop()
        engine?.stop()
        onPlayback(false)
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
        queue.sync {
            player?.stop()
            engine?.stop()
            player = nil
            engine = nil
            converter = nil
        }
    }
}
