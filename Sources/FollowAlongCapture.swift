import AVFoundation

// MARK: - Tellavision "Follow along": the microphone's sound, to 8 kHz mono
//
// Nov 14 2026. Its own file, AVFoundation only (no UIKit), so the tests run
// it on the build Mac: buffers in, 8 kHz mono out, through the change of
// format that earbuds going in or out can bring.
//
// Privacy: the sound only passes through here on its way to the loop's
// 16-second memory. Nothing is written, sent or logged (FollowAlongTests
// checks the source).

/// The phone's audio clock in seconds (the same clock as the microphone's
/// timestamps), for "now" everywhere in Follow along.
enum FollowClock {
    static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
}

/// Lives on the microphone tap's own thread (the tap hands it one buffer at
/// a time). One bulk copy per piece of sound, then on to the loop.
///
/// The converter is made from each buffer's own format, and made again when
/// that format changes (Nov 14 review): earbuds going in or out can change
/// the microphone's rate, and a converter made for the old rate turns the new
/// sound into nothing. StreamingCallService's MicConverterBox learned this on
/// a live call.
final class FollowAlongCapture {
    private let target: AVAudioFormat
    private let sink: FollowSoundSink
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    /// nil when this phone cannot turn `format` (the microphone's, as the
    /// engine reports it) into 8 kHz mono at all.
    init?(from format: AVAudioFormat, sink: FollowSoundSink) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true) else {
            return nil
        }
        self.target = target
        self.sink = sink
        guard converting(format) != nil else { return nil }
    }

    /// The converter for sound in `format`: kept while the format stays the
    /// same, made again when it changes.
    private func converting(_ format: AVAudioFormat) -> AVAudioConverter? {
        if let converter, let source, source == format { return converter }
        source = format
        let made = AVAudioConverter(from: format, to: target)
        made?.downmix = true
        converter = made
        return made
    }

    func take(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        let frames = Double(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0, let converter = converting(buffer.format) else { return }
        let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : FollowClock.now() - frames / rate
        let end = start + frames / rate
        let capacity = AVAudioFrameCount(frames * target.sampleRate / rate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var problem: NSError?
        let status = converter.convert(to: out, error: &problem) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, problem == nil, out.frameLength > 0, let channels = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(out.frameLength)))
        sink.receive(samples, endingAt: end)
    }
}
