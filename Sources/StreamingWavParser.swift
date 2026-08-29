import Foundation

/* Part 98 (Aug 29 2026) — THE STREAMING PLAYER'S PURE HALF.
 *
 * The streamed voice lane (proxy commit b6494b6) sends a WAV whose declared
 * sizes are the streaming sentinel 0xFFFFFFFF, followed by PCM that arrives
 * in whatever chunks the network felt like. Everything in this file is the
 * logic that must be RIGHT about those bytes and needs no audio hardware to
 * prove it: header parsing that never trusts a declared length, and the
 * byte→sample conversion with a carry for the sample a chunk boundary tears
 * in half. Pure Foundation on purpose — run-speech-tests.sh compiles this
 * file on Linux, so the whole class of "off-by-one in the header math"
 * bug is catchable in a sandbox before a build is ever cut. The half that
 * needs a device (AVAudioEngine scheduling, session routing, pause/stop
 * discipline) lives in StreamingClipPlayer.swift and is named there as
 * not-covered, same honesty as the pump's own test file.
 */

struct StreamingWavFormat: Equatable {
    let numChannels: Int
    let sampleRate: Double
    let bitsPerSample: Int
}

enum StreamingWavParser {
    /// Parse the header of a (possibly streaming) WAV and find where PCM
    /// starts. Returns nil while the buffer is still too short to hold the
    /// whole header — the caller accumulates and retries — and throws
    /// nothing: a malformed stream shows up as nil forever, which the
    /// fetch-level failure handling already covers with its timeout.
    ///
    /// The declared RIFF and data sizes are deliberately IGNORED: on the
    /// streamed lane both are 0xFFFFFFFF because the proxy cannot know the
    /// total while Inworld is still speaking. Trusting a declared length was
    /// never an option here.
    static func parseHeader(_ data: Data) -> (format: StreamingWavFormat, pcmStart: Int)? {
        guard data.count >= 12 else { return nil }
        guard data[data.startIndex] == 0x52, data[data.startIndex + 1] == 0x49,
              data[data.startIndex + 2] == 0x46, data[data.startIndex + 3] == 0x46, // "RIFF"
              data[data.startIndex + 8] == 0x57, data[data.startIndex + 9] == 0x41,
              data[data.startIndex + 10] == 0x56, data[data.startIndex + 11] == 0x45 // "WAVE"
        else { return nil }

        var offset = 12
        var fmt: StreamingWavFormat?
        while offset + 8 <= data.count {
            let idStart = data.startIndex + offset
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            let chunkStart = offset + 8
            let a = data[idStart], b = data[idStart + 1], c = data[idStart + 2], d = data[idStart + 3]
            if a == 0x66, b == 0x6d, c == 0x74, d == 0x20 { // "fmt "
                guard chunkStart + 16 <= data.count else { return nil }
                let channels = Int(readUInt16LE(data, at: chunkStart + 2))
                let rate = Double(readUInt32LE(data, at: chunkStart + 4))
                let bits = Int(readUInt16LE(data, at: chunkStart + 14))
                guard channels > 0, rate > 0, bits > 0 else { return nil }
                fmt = StreamingWavFormat(numChannels: channels, sampleRate: rate, bitsPerSample: bits)
                offset = chunkStart + chunkSize + (chunkSize % 2)
            } else if a == 0x64, b == 0x61, c == 0x74, d == 0x61 { // "data"
                guard let fmt else { return nil }
                return (fmt, chunkStart)
            } else {
                offset = chunkStart + chunkSize + (chunkSize % 2)
            }
        }
        return nil
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }
}

/// Turns arriving PCM byte chunks into Float samples (-1...1), carrying the
/// lone byte of a 16-bit sample a chunk boundary tears in half. One instance
/// per clip; feed every chunk through in arrival order.
struct PcmSampleAccumulator {
    private var carry: UInt8?

    mutating func append(_ bytes: Data) -> [Float] {
        guard !bytes.isEmpty else { return [] }
        var work: Data
        if let c = carry {
            work = Data([c])
            work.append(bytes)
            carry = nil
        } else {
            work = bytes
        }
        if work.count % 2 == 1 {
            carry = work[work.startIndex + work.count - 1]
            work = work.subdata(in: work.startIndex ..< work.startIndex + work.count - 1)
        }
        let sampleCount = work.count / 2
        guard sampleCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: sampleCount)
        work.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0 ..< sampleCount {
                let lo = UInt16(base[i * 2])
                let hi = UInt16(base[i * 2 + 1])
                let bits = lo | (hi << 8)
                let sample = Int16(bitPattern: bits)
                out[i] = Float(sample) / 32768.0
            }
        }
        return out
    }
}
