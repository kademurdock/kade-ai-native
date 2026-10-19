import Foundation
import CryptoKit
import Compression

// MARK: - ADD A GAME (Oct 19 2026), the pure half
//
// Kade, Oct 19 2026: people may add their own game files to the Arcade, for
// their own use. A file added from Files stays on this iPhone and is never
// uploaded; only its No-Intro sha1 goes to her server, to ask whether an
// accessibility pack (the voices, the sound map, the RAM map, but no game)
// is made for it. A pack follows its game's shelf: a family game's pack is
// family-only, and anyone else plays the original game with the reason read.
//
// Everything here is plain Foundation, CryptoKit and Compression, so
// run-arcade-tests.sh compiles it with swiftc and no simulator:
//   - the v1 systems (license-clean cores only) and how a file is recognised
//   - the No-Intro identity: sha1 and crc32 of the ROM as No-Intro hashes it
//     (NES without its iNES header, N64 in big-endian .z64 order), plus the
//     raw file's own sha1 as the import's local id
//   - a minimal zip reader: stored and raw DEFLATE entries, exactly one game
//     inside, 128 MB at most, no ZIP64, no passwords
//   - the import store, Application Support/Arcade/imports/<local id>/,
//     excluded from backup
//   - GET /api/kade/arcade/match, read leniently, and each import's status
//   - where an added game's page and ROM live under kadearcade://

// MARK: - Systems

/// The systems an added game may be, with the EmulatorJS core each one uses.
enum ArcadeSystem: String, Codable, CaseIterable, Equatable {
    case nes, gb, gbc, gba, n64

    /// What VoiceOver says.
    var name: String {
        switch self {
        case .nes: return "NES"
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .gba: return "Game Boy Advance"
        case .n64: return "N64"
        }
    }

    /// The EmulatorJS core (all of them fine for an app that charges).
    var core: String {
        switch self {
        case .nes: return "fceumm"
        case .gb, .gbc: return "gambatte"
        case .gba: return "mgba"
        case .n64: return "mupen64plus_next"
        }
    }

    var extensions: [String] {
        switch self {
        case .nes: return ["nes"]
        case .gb: return ["gb"]
        case .gbc: return ["gbc"]
        case .gba: return ["gba"]
        case .n64: return ["z64", "n64", "v64"]
        }
    }

    /// The extension the phone keeps the file under: an N64 game is always
    /// kept in .z64 order, so a pack's page reads it the way it expects.
    var keptExtension: String { self == .n64 ? "z64" : rawValue }

    static let romExtensions: [String] = allCases.flatMap { $0.extensions }

    static func from(extension raw: String) -> ArcadeSystem? {
        let ext = raw.lowercased()
        return allCases.first { $0.extensions.contains(ext) }
    }
}

/// The three byte orders an N64 file comes in.
enum ArcadeN64Order: String, Codable, Equatable {
    /// .z64, the console's own order: 80 37 12 40.
    case bigEndian = "z64"
    /// .v64, every pair of bytes swapped: 37 80 40 12.
    case byteSwapped = "v64"
    /// .n64, every 4-byte word reversed: 40 12 37 80.
    case wordSwapped = "n64"

    /// From the file's first four bytes, or nil when they are none of the three.
    static func detect(_ head: [UInt8]) -> ArcadeN64Order? {
        guard head.count >= 4 else { return nil }
        let first = Array(head[0..<4])
        if first == [0x80, 0x37, 0x12, 0x40] { return .bigEndian }
        if first == [0x37, 0x80, 0x40, 0x12] { return .byteSwapped }
        if first == [0x40, 0x12, 0x37, 0x80] { return .wordSwapped }
        return nil
    }

    static func byExtension(_ raw: String) -> ArcadeN64Order? {
        ArcadeN64Order(rawValue: raw.lowercased())
    }

    /// Puts whole words into .z64 order in place; a tail shorter than a word is left as it is.
    static func toBigEndian(_ bytes: inout [UInt8], from order: ArcadeN64Order) {
        switch order {
        case .bigEndian:
            return
        case .byteSwapped:
            var i = 0
            while i + 1 < bytes.count {
                bytes.swapAt(i, i + 1)
                i += 2
            }
        case .wordSwapped:
            var i = 0
            while i + 3 < bytes.count {
                bytes.swapAt(i, i + 3)
                bytes.swapAt(i + 1, i + 2)
                i += 4
            }
        }
    }
}

/// What an added file is.
struct ArcadeROMKind: Equatable {
    let system: ArcadeSystem
    /// N64 only: the order the file came in.
    let n64Order: ArcadeN64Order?
    /// Bytes No-Intro leaves out at the start: the 16-byte iNES header.
    let headerBytes: Int
}

enum ArcadeROMDetect {
    /// "NES" and 0x1A, the iNES header's first four bytes.
    static let inesMagic: [UInt8] = [0x4E, 0x45, 0x53, 0x1A]

    /// The system from the file name, checked against the first bytes: an
    /// NES file's iNES header, an N64 file's byte order, and a handheld
    /// file's colour flag (0xC0 at 0x143: it runs in colour only). Nil
    /// when the extension is not a v1 one.
    static func kind(fileName: String, head: Data) -> ArcadeROMKind? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let system = ArcadeSystem.from(extension: ext) else { return nil }
        let bytes = [UInt8](head.prefix(0x200))
        switch system {
        case .nes:
            let headed = bytes.count >= 16 && Array(bytes[0..<4]) == inesMagic
            return ArcadeROMKind(system: .nes, n64Order: nil, headerBytes: headed ? 16 : 0)
        case .n64:
            let order = ArcadeN64Order.detect(bytes) ?? ArcadeN64Order.byExtension(ext) ?? .bigEndian
            return ArcadeROMKind(system: .n64, n64Order: order, headerBytes: 0)
        case .gb, .gbc:
            let colourOnly = bytes.count > 0x143 && bytes[0x143] == 0xC0
            return ArcadeROMKind(system: colourOnly ? .gbc : system, n64Order: nil, headerBytes: 0)
        case .gba:
            return ArcadeROMKind(system: .gba, n64Order: nil, headerBytes: 0)
        }
    }
}

// MARK: - Identity

/// CRC-32 (the zip and No-Intro one: reflected, polynomial 0xEDB88320).
struct ArcadeCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        let table = Self.table
        var c = state
        for byte in bytes {
            let index = Int((c ^ UInt32(byte)) & 0xFF)
            c = table[index] ^ (c >> 8)
        }
        state = c
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }
    var hex: String { String(format: "%08x", value) }
}

/// Who an added ROM is.
struct ArcadeROMIdentity: Codable, Equatable {
    /// No-Intro's sha1: NES without its iNES header, N64 in .z64 order, others whole.
    let sha1: String
    /// crc32 of the same bytes, 8 lowercase hex characters.
    let crc32: String
    /// sha1 of the file exactly as it was added: the import's local id.
    let localId: String
    /// The file's size as it was added.
    let size: Int64
}

/// One pass over a ROM, in pieces of any size: the raw sha1, the No-Intro
/// sha1 and crc32, and the bytes the phone keeps (an N64 file turned into
/// .z64 order; anything else exactly as it came, iNES header included,
/// because the emulator needs it).
struct ArcadeROMHasher {
    let kind: ArcadeROMKind
    private var raw = Insecure.SHA1()
    private var normal = Insecure.SHA1()
    private var crc = ArcadeCRC32()
    private var skipLeft: Int
    /// N64: the bytes of a word not yet whole.
    private var carry: [UInt8] = []
    private var count: Int64 = 0

    init(kind: ArcadeROMKind) {
        self.kind = kind
        skipLeft = kind.headerBytes
    }

    /// Feeds the next raw bytes; answers the bytes to keep for them.
    mutating func update(_ data: Data) -> Data {
        raw.update(data: data)
        count += Int64(data.count)
        guard let order = kind.n64Order, order != .bigEndian else {
            var bytes = [UInt8](data)
            if skipLeft > 0 {
                let drop = min(skipLeft, bytes.count)
                bytes.removeFirst(drop)
                skipLeft -= drop
            }
            feed(bytes)
            return data
        }
        var bytes = carry + [UInt8](data)
        let whole = bytes.count - bytes.count % 4
        carry = Array(bytes[whole...])
        bytes.removeLast(bytes.count - whole)
        ArcadeN64Order.toBigEndian(&bytes, from: order)
        feed(bytes)
        return Data(bytes)
    }

    /// The identity, and any last bytes still to keep (an N64 file whose
    /// size is not a whole number of words ends as it came).
    mutating func finish() -> (identity: ArcadeROMIdentity, tail: Data) {
        let tail = carry
        carry = []
        feed(tail)
        let identity = ArcadeROMIdentity(sha1: Self.hex(normal.finalize()), crc32: crc.hex,
                                         localId: Self.hex(raw.finalize()), size: count)
        return (identity, Data(tail))
    }

    private mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        normal.update(data: bytes)
        crc.update(bytes)
    }

    static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The whole thing at once (tests, small files): the identity and the bytes kept.
    static func identify(_ data: Data, kind: ArcadeROMKind) -> (identity: ArcadeROMIdentity, kept: Data) {
        var hasher = ArcadeROMHasher(kind: kind)
        var kept = hasher.update(data)
        let end = hasher.finish()
        kept.append(end.tail)
        return (end.identity, kept)
    }
}

// MARK: - Problems, in words

/// Why a file could not be added. Each one is said to the person as it is.
enum ArcadeImportProblem: Error, Equatable {
    case notAGame
    case empty
    case tooBig
    case unreadable
    case busy
    case notAZip
    case zipTooNew
    case zipLocked
    case zipMethod
    case zipDamaged
    case zipNoGame
    case zipSeveralGames

    var spoken: String {
        switch self {
        case .notAGame:
            return "That file is not a game the Arcade can play. Add an NES, Game Boy, Game Boy Color, Game Boy Advance or N64 game file, or a zip holding one."
        case .empty:
            return "That file is empty."
        case .tooBig:
            return "That file is bigger than 128 MB, the most the Arcade takes."
        case .unreadable:
            return "That file could not be read. If it is in iCloud Drive, open its folder in Files so it downloads, then try again."
        case .busy:
            return "Another game is being added. Wait for it to finish, then try again."
        case .notAZip:
            return "That zip could not be opened. It may be damaged."
        case .zipTooNew:
            return "That zip uses a format the Arcade cannot open. Unzip it in Files and add the game file itself."
        case .zipLocked:
            return "That zip has a password. Unzip it in Files and add the game file itself."
        case .zipMethod:
            return "That zip is packed in a way the Arcade cannot open. Unzip it in Files and add the game file itself."
        case .zipDamaged:
            return "That zip is damaged: the game inside it did not check out."
        case .zipNoGame:
            return "That zip holds no game the Arcade can play. It needs exactly one NES, Game Boy, Game Boy Color, Game Boy Advance or N64 file."
        case .zipSeveralGames:
            return "That zip holds more than one game. Unzip it in Files and add the games one at a time."
        }
    }
}

enum ArcadeImportLimits {
    /// The biggest file (a zip, or the game inside it) the Arcade takes.
    static let maxBytes: Int64 = 128 * 1024 * 1024
    /// A zip's central directory is small; anything far bigger is not a game's zip.
    static let maxDirectoryBytes = 4 * 1024 * 1024
    static let maxEntries = 10_000
}

// MARK: - Zip

/// One file listed in a zip's central directory.
struct ArcadeZipEntry: Equatable {
    let name: String
    let flags: UInt16
    /// 0 stored, 8 deflate.
    let method: UInt16
    let crc32: UInt32
    let compressedSize: Int64
    let size: Int64
    let localHeaderOffset: Int64

    var isDirectory: Bool { name.hasSuffix("/") }

    /// The name without its folders.
    var fileName: String {
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? name
    }

    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    /// Extras a Mac or Files adds ("__MACOSX/", "._name", ".DS_Store"): never a game.
    var isHiddenExtra: Bool {
        name.hasPrefix("__MACOSX/") || name.contains("/__MACOSX/") || fileName.hasPrefix(".")
    }
}

/// A minimal zip reader: the central directory, then one entry, stored or
/// raw DEFLATE (the Compression framework's COMPRESSION_ZLIB is raw DEFLATE,
/// RFC 1951, exactly what a zip holds). No ZIP64, no spanning, no passwords.
enum ArcadeZip {
    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        let low = UInt16(b[i])
        let high = UInt16(b[i + 1])
        return low | (high << 8)
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        let b0 = UInt32(b[i])
        let b1 = UInt32(b[i + 1]) << 8
        let b2 = UInt32(b[i + 2]) << 16
        let b3 = UInt32(b[i + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func read(_ handle: FileHandle, at offset: Int64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        return [UInt8](data)
    }

    /// Every entry in the zip's central directory.
    static func entries(of url: URL) throws -> [ArcadeZipEntry] {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ArcadeImportProblem.unreadable }
        defer { try? handle.close() }
        let fileSize = try Int64(handle.seekToEnd())
        guard fileSize >= 22 else { throw ArcadeImportProblem.notAZip }
        let tailLength = Int(min(fileSize, 22 + 65_535))
        let tail = try read(handle, at: fileSize - Int64(tailLength), count: tailLength)
        guard tail.count == tailLength else { throw ArcadeImportProblem.unreadable }
        // The end-of-directory record, searched from the end (a comment may follow it).
        var end = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06 {
                end = i
                break
            }
            i -= 1
        }
        guard end >= 0 else { throw ArcadeImportProblem.notAZip }
        let disk = u16(tail, end + 4)
        let directoryDisk = u16(tail, end + 6)
        let onThisDisk = u16(tail, end + 8)
        let total = u16(tail, end + 10)
        let directorySize = u32(tail, end + 12)
        let directoryOffset = u32(tail, end + 16)
        if total == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ArcadeImportProblem.zipTooNew
        }
        if disk != 0 || directoryDisk != 0 || onThisDisk != total { throw ArcadeImportProblem.zipTooNew }
        guard Int(total) <= ArcadeImportLimits.maxEntries,
              Int(directorySize) <= ArcadeImportLimits.maxDirectoryBytes,
              Int64(directoryOffset) + Int64(directorySize) <= fileSize else { throw ArcadeImportProblem.notAZip }
        let directory = try read(handle, at: Int64(directoryOffset), count: Int(directorySize))
        guard directory.count == Int(directorySize) else { throw ArcadeImportProblem.notAZip }

        var entries: [ArcadeZipEntry] = []
        var p = 0
        for _ in 0..<Int(total) {
            guard p + 46 <= directory.count, u32(directory, p) == 0x0201_4B50 else { throw ArcadeImportProblem.notAZip }
            let flags = u16(directory, p + 8)
            let method = u16(directory, p + 10)
            let crc = u32(directory, p + 16)
            let compressed = u32(directory, p + 20)
            let size = u32(directory, p + 24)
            let nameLength = Int(u16(directory, p + 28))
            let extraLength = Int(u16(directory, p + 30))
            let commentLength = Int(u16(directory, p + 32))
            let local = u32(directory, p + 42)
            guard p + 46 + nameLength <= directory.count else { throw ArcadeImportProblem.notAZip }
            if compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF || local == 0xFFFF_FFFF {
                throw ArcadeImportProblem.zipTooNew
            }
            let name = String(decoding: directory[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(ArcadeZipEntry(name: name, flags: flags, method: method, crc32: crc,
                                          compressedSize: Int64(compressed), size: Int64(size),
                                          localHeaderOffset: Int64(local)))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The one game in the zip: exactly one entry of a v1 type (folders and
    /// a Mac's extras do not count), stored or deflated, no password, 128 MB at most.
    static func gameEntry(in entries: [ArcadeZipEntry]) throws -> ArcadeZipEntry {
        let games = entries.filter {
            !$0.isDirectory && !$0.isHiddenExtra && ArcadeSystem.from(extension: $0.fileExtension) != nil
        }
        guard !games.isEmpty else { throw ArcadeImportProblem.zipNoGame }
        guard games.count == 1 else { throw ArcadeImportProblem.zipSeveralGames }
        let game = games[0]
        if game.flags & 1 != 0 { throw ArcadeImportProblem.zipLocked }
        guard game.method == 0 || game.method == 8 else { throw ArcadeImportProblem.zipMethod }
        guard game.size > 0 else { throw ArcadeImportProblem.empty }
        guard game.size <= ArcadeImportLimits.maxBytes else { throw ArcadeImportProblem.tooBig }
        if game.method == 0 && game.compressedSize != game.size { throw ArcadeImportProblem.zipDamaged }
        return game
    }

    /// Unpacks one entry piece by piece into `write`, and checks its size and crc32.
    static func extract(_ entry: ArcadeZipEntry, from url: URL, write: (Data) throws -> Void) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ArcadeImportProblem.unreadable }
        defer { try? handle.close() }
        let header = try read(handle, at: entry.localHeaderOffset, count: 30)
        guard header.count == 30, u32(header, 0) == 0x0403_4B50 else { throw ArcadeImportProblem.zipDamaged }
        let start = entry.localHeaderOffset + 30 + Int64(u16(header, 26)) + Int64(u16(header, 28))
        try handle.seek(toOffset: UInt64(start))

        var crc = ArcadeCRC32()
        var produced: Int64 = 0
        var remaining = entry.compressedSize
        let piece = 1 << 20

        func nextPiece() throws -> Data {
            guard remaining > 0 else { return Data() }
            let data = try handle.read(upToCount: Int(min(remaining, Int64(piece)))) ?? Data()
            remaining -= Int64(data.count)
            if data.isEmpty { remaining = 0 }
            return data
        }

        if entry.method == 0 {
            while true {
                let data = try nextPiece()
                if data.isEmpty { break }
                produced += Int64(data.count)
                guard produced <= entry.size else { throw ArcadeImportProblem.zipDamaged }
                crc.update(data)
                try write(data)
            }
        } else {
            try inflate(next: { try nextPiece() }, out: { data in
                produced += Int64(data.count)
                guard produced <= entry.size else { throw ArcadeImportProblem.zipDamaged }
                crc.update(data)
                try write(data)
            })
        }
        guard produced == entry.size, crc.value == entry.crc32 else { throw ArcadeImportProblem.zipDamaged }
    }

    /// Raw DEFLATE through the Compression framework: `next` gives the
    /// compressed bytes piece by piece (empty once there are no more), `out`
    /// takes each piece of the result.
    static func inflate(next: () throws -> Data, out: (Data) throws -> Void) throws {
        let capacity = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ArcadeImportProblem.zipDamaged
        }
        defer { compression_stream_destroy(stream) }
        var ended = false
        while !ended {
            let given = [UInt8](try next())
            let last = given.isEmpty
            // The stream needs a pointer even with nothing left to give.
            let input: [UInt8] = last ? [0] : given
            try input.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { throw ArcadeImportProblem.zipDamaged }
                stream.pointee.src_ptr = base
                stream.pointee.src_size = last ? 0 : source.count
                while true {
                    let before = stream.pointee.src_size
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = capacity
                    let flags: Int32 = last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(stream, flags)
                    let made = capacity - stream.pointee.dst_size
                    if made > 0 { try out(Data(bytes: buffer, count: made)) }
                    if status == COMPRESSION_STATUS_END {
                        ended = true
                        return
                    }
                    guard status == COMPRESSION_STATUS_OK else { throw ArcadeImportProblem.zipDamaged }
                    if last {
                        // Asked to finish and nothing came: the stream was cut short.
                        if made == 0 { throw ArcadeImportProblem.zipDamaged }
                    } else if stream.pointee.src_size == 0 && made < capacity {
                        return   // this piece is used up
                    } else if made == 0 && stream.pointee.src_size == before {
                        throw ArcadeImportProblem.zipDamaged   // no progress at all
                    }
                }
            }
        }
    }
}

// MARK: - The import store

/// A pack an added game uses (the kit, or its accessibility pack).
struct ArcadeImportPack: Codable, Equatable {
    let kind: String
    let id: String
    let version: String
    let sha256: String
    /// "public" or "family": a family pack opens only inside the Family feature pack.
    var access: String?

    /// The pack's folder key under Arcade/, "<id>/<version>".
    var key: String { id + "/" + version }
}

/// The last answer from /match, kept for the row's status.
struct ArcadeMatchSummary: Codable, Equatable {
    /// False: the server knows no accessibility pack for this game.
    let found: Bool
    var gameId: String?
    var title: String?
    var version: String?
    var size: Int64?
    /// "public" or "family".
    var access: String?
    var locked: Bool
    var note: String?

    static let noMatch = ArcadeMatchSummary(found: false, locked: false)
}

/// One added game, as record.json beside its ROM.
struct ArcadeImportRecord: Codable, Equatable, Identifiable {
    /// sha1 of the file as it was added (40 hex): the folder name and the saves' key.
    let localId: String
    /// The file's name at first; she may rename it.
    var title: String
    let system: ArcadeSystem
    /// The file's name as it was added.
    let fileName: String
    /// The ROM's name inside the folder ("rom.gb", "rom.z64").
    let romFile: String
    /// No-Intro sha1 and crc32.
    let sha1: String
    let crc32: String
    let size: Int64
    let added: Date
    var match: ArcadeMatchSummary? = nil
    /// The kit the player (and the accessibility pack) runs on.
    var kit: ArcadeImportPack? = nil
    var emulatorData: String? = nil
    /// The accessibility pack on this iPhone, when one was downloaded.
    var accessPack: ArcadeImportPack? = nil
    /// Where the pack's page expects the ROM (pack.json romPath).
    var romPath: String? = nil
    /// The pack's page.
    var entry: String? = nil

    var id: String { localId }
}

struct ArcadeImportStore {
    /// Application Support/Arcade/imports.
    let root: URL

    init(root: URL) { self.root = root }

    static func standard() throws -> ArcadeImportStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let store = ArcadeImportStore(root: support.appendingPathComponent("Arcade", isDirectory: true)
            .appendingPathComponent("imports", isDirectory: true))
        try store.prepare()
        return store
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    static func isLocalId(_ text: String) -> Bool {
        text.count == 40 && text.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
    }

    /// Where files are put together before they are whole (hidden, so never listed).
    var incoming: URL { root.appendingPathComponent(".incoming", isDirectory: true) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
    }

    func folder(_ localId: String) -> URL? {
        guard Self.isLocalId(localId) else { return nil }
        return root.appendingPathComponent(localId, isDirectory: true)
    }

    func romURL(_ record: ArcadeImportRecord) -> URL? {
        guard let folder = folder(record.localId), let clean = ArcadePaths.normalize(record.romFile),
              !clean.contains("/") else { return nil }
        return folder.appendingPathComponent(clean)
    }

    func record(_ localId: String) -> ArcadeImportRecord? {
        guard let folder = folder(localId),
              let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
              let record = try? JSONDecoder().decode(ArcadeImportRecord.self, from: data),
              record.localId == localId else { return nil }
        return record
    }

    func save(_ record: ArcadeImportRecord) throws {
        guard let folder = folder(record.localId) else { throw ArcadeImportProblem.unreadable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
        Self.excludeFromBackup(folder)
    }

    /// Every added game whose ROM is still there, by title.
    func records() -> [ArcadeImportRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        var found: [ArcadeImportRecord] = []
        for folder in folders {
            guard let record = self.record(folder.lastPathComponent), let rom = romURL(record),
                  FileManager.default.fileExists(atPath: rom.path) else { continue }
            found.append(record)
        }
        return found.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.added < $1.added : order == .orderedAscending
        }
    }

    func delete(_ localId: String) {
        guard let folder = folder(localId) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Every pack folder ("<id>/<version>") an added game uses, so pruning a
    /// shelf game never takes them.
    func packKeys() -> Set<String> {
        var keys = Set<String>()
        for record in records() {
            if let kit = record.kit { keys.insert(kit.key) }
            if let pack = record.accessPack { keys.insert(pack.key) }
        }
        return keys
    }
}

// MARK: - Adding a file

enum ArcadeImporter {
    struct Added: Equatable {
        let record: ArcadeImportRecord
        /// The same file was added before: the existing one is answered.
        let already: Bool
    }

    /// Adds a game file or a zip holding one. Every problem is an ArcadeImportProblem.
    static func add(_ source: URL, store: ArcadeImportStore, now: Date = Date()) throws -> Added {
        do {
            try store.prepare()
            let ext = source.pathExtension.lowercased()
            let size = try fileSize(source)
            guard size > 0 else { throw ArcadeImportProblem.empty }
            guard size <= ArcadeImportLimits.maxBytes else { throw ArcadeImportProblem.tooBig }
            if ext == "zip" {
                let entry = try ArcadeZip.gameEntry(in: ArcadeZip.entries(of: source))
                let unpacked = store.incoming.appendingPathComponent(UUID().uuidString + "." + entry.fileExtension)
                defer { try? FileManager.default.removeItem(at: unpacked) }
                guard FileManager.default.createFile(atPath: unpacked.path, contents: nil) else {
                    throw ArcadeImportProblem.unreadable
                }
                let out = try FileHandle(forWritingTo: unpacked)
                do {
                    try ArcadeZip.extract(entry, from: source) { data in try out.write(contentsOf: data) }
                    try out.close()
                } catch {
                    try? out.close()
                    throw error
                }
                return try addROM(unpacked, fileName: entry.fileName, store: store, now: now)
            }
            guard ArcadeSystem.from(extension: ext) != nil else { throw ArcadeImportProblem.notAGame }
            return try addROM(source, fileName: source.lastPathComponent, store: store, now: now)
        } catch let problem as ArcadeImportProblem {
            throw problem
        } catch {
            throw ArcadeImportProblem.unreadable
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Reads the ROM once: checks it, hashes it, and keeps it (N64 in .z64 order).
    static func addROM(_ file: URL, fileName: String, store: ArcadeImportStore, now: Date) throws -> Added {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 0x200) ?? Data()
        guard !head.isEmpty else { throw ArcadeImportProblem.empty }
        guard let kind = ArcadeROMDetect.kind(fileName: fileName, head: head) else { throw ArcadeImportProblem.notAGame }
        try handle.seek(toOffset: 0)

        let part = store.incoming.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw ArcadeImportProblem.unreadable }
        defer { try? FileManager.default.removeItem(at: part) }
        let writer = try FileHandle(forWritingTo: part)
        var hasher = ArcadeROMHasher(kind: kind)
        var total: Int64 = 0
        let identity: ArcadeROMIdentity
        do {
            while true {
                let chunk: Data = try autoreleasepool { try handle.read(upToCount: 1 << 20) ?? Data() }
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
                guard total <= ArcadeImportLimits.maxBytes else { throw ArcadeImportProblem.tooBig }
                try writer.write(contentsOf: hasher.update(chunk))
            }
            let end = hasher.finish()
            if !end.tail.isEmpty { try writer.write(contentsOf: end.tail) }
            try writer.close()
            identity = end.identity
        } catch {
            try? writer.close()
            throw error
        }

        guard let folder = store.folder(identity.localId) else { throw ArcadeImportProblem.unreadable }
        if let existing = store.record(identity.localId), let rom = store.romURL(existing),
           FileManager.default.fileExists(atPath: rom.path) {
            return Added(record: existing, already: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let romFile = "rom." + kind.system.keptExtension
        let target = folder.appendingPathComponent(romFile)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        let record = ArcadeImportRecord(localId: identity.localId, title: ArcadeImportText.title(fromFileName: fileName),
                                        system: kind.system, fileName: fileName, romFile: romFile,
                                        sha1: identity.sha1, crc32: identity.crc32, size: identity.size, added: now)
        try store.save(record)
        return Added(record: record, already: false)
    }
}

// MARK: - GET /api/kade/arcade/match

/// The server's answer for one ROM's No-Intro sha1:
/// `{match: null}` or `{match: {id, title, console, version, size, sha256,
/// access, locked?, note?}}` where `version` is the accessibility pack's own
/// version. Read leniently: `accessVersion`/`accessSize`/`accessSha256`
/// are taken too, and so are a `signPath`, the pack's file table inline
/// (`files` or `index`, the manifest's row shape), its `romPath` and its
/// page (`entry`), when the server sends them.
struct ArcadeMatch: Decodable, Equatable {
    let id: String
    let title: String
    let console: String?
    /// The accessibility pack's version.
    let version: String
    let size: Int64?
    let sha256: String?
    let access: ArcadeAccess
    let locked: Bool
    let note: String?
    let signPath: String?
    let files: [ArcadePackFile]?
    let romPath: String?
    let entry: String?

    enum CodingKeys: String, CodingKey {
        case id, title, console, version, accessVersion, size, bytes, accessSize, sha256, accessSha256
        case access, locked, note, signPath, files, index, romPath, entry, page
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.arcadeText(.id), ArcadePaths.isSafeName(id),
              let version = c.arcadeText(.accessVersion) ?? c.arcadeText(.version), ArcadePaths.isSafeName(version) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A match needs a plain id and version")
        }
        self.id = id
        self.version = version
        title = c.arcadeText(.title) ?? id
        console = c.arcadeText(.console)
        size = c.arcadeNumber(.accessSize) ?? c.arcadeNumber(.size) ?? c.arcadeNumber(.bytes)
        let sha = (c.arcadeText(.accessSha256) ?? c.arcadeText(.sha256))?.lowercased()
        sha256 = sha.flatMap { ArcadeHash.isHex64($0) ? $0 : nil }
        // Anything but an explicit "public" is the family shelf: the safer side.
        access = c.arcadeText(.access)?.lowercased() == "public" ? .open : .family
        locked = c.arcadeFlag(.locked) ?? false
        note = c.arcadeText(.note)
        signPath = c.arcadeText(.signPath)
        let primary: [ArcadeLenient<ArcadePackFile>]? = try? c.decodeIfPresent([ArcadeLenient<ArcadePackFile>].self, forKey: .files)
        let alternate: [ArcadeLenient<ArcadePackFile>]? = try? c.decodeIfPresent([ArcadeLenient<ArcadePackFile>].self, forKey: .index)
        let rows: [ArcadePackFile] = (primary ?? alternate ?? []).compactMap { $0.value }
        files = rows.isEmpty ? nil : rows
        romPath = c.arcadeText(.romPath).flatMap { ArcadePaths.normalize($0) }
        entry = (c.arcadeText(.entry) ?? c.arcadeText(.page)).flatMap { ArcadePaths.normalize($0) }
    }

    /// The accessibility pack to download: only when it is not locked and
    /// the answer says its size and sha256.
    var pack: ArcadePackRef? {
        guard !locked, let size, size > 0, let sha256 else { return nil }
        return ArcadePackRef(kind: "game", id: id, version: version, size: size, sha256: sha256,
                             signPath: signPath, index: files)
    }

    var summary: ArcadeMatchSummary {
        ArcadeMatchSummary(found: true, gameId: id, title: title, version: version, size: size,
                           access: access.rawValue, locked: locked, note: note)
    }
}

struct ArcadeMatchAnswer: Decodable {
    /// The answer had a `match` key at all (null or not).
    let answered: Bool
    let match: ArcadeMatch?

    enum CodingKeys: String, CodingKey { case match }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answered = c.contains(.match)
        match = try? c.decodeIfPresent(ArcadeMatch.self, forKey: .match)
    }
}

// MARK: - What a row says

enum ArcadeImportStatus: Equatable {
    /// Its accessibility pack is on this iPhone.
    case pack
    /// An accessibility pack is made for it and may be downloaded.
    case packReady(size: Int64?)
    /// No accessibility pack: it plays as the original game.
    case plain
    /// A pack exists but is not open here; the reason is said first.
    case locked(String)
    /// The server has not been asked yet (offline, or the ask failed).
    case unchecked

    var words: String {
        switch self {
        case .pack: return "Accessibility pack"
        case .packReady: return "Accessibility pack ready to download"
        case .plain: return "Plays as the original game"
        case .locked(let reason): return reason
        case .unchecked: return "Not checked for an accessibility pack yet"
        }
    }

    var isPackReady: Bool {
        if case .packReady = self { return true }
        return false
    }

    /// `familyOpen` is nil while the Arcade's shelf has not answered (offline).
    static func of(_ record: ArcadeImportRecord, packOnPhone: Bool, familyOpen: Bool?) -> ArcadeImportStatus {
        if let pack = record.accessPack, packOnPhone {
            if pack.access != "public" && familyOpen != true {
                return .locked(familyOpen == nil ? ArcadeImportText.checkOnline : ArcadeImportText.familyPack)
            }
            return .pack
        }
        guard let match = record.match else { return .unchecked }
        guard match.found else { return .plain }
        if match.locked {
            return .locked(match.access == "public" ? (match.note ?? ArcadeImportText.notOpen) : ArcadeImportText.familyPack)
        }
        if match.access != "public" && familyOpen != true {
            return .locked(familyOpen == nil ? ArcadeImportText.checkOnline : ArcadeImportText.familyPack)
        }
        return .packReady(size: match.size)
    }
}

enum ArcadeImportText {
    static let about = "Add a game file you own from Files: NES, Game Boy, Game Boy Color, Game Boy Advance or N64, or a zip holding one. It stays on this iPhone, for you, and is never uploaded. When Kade has made an accessibility pack for that game, it is offered to you."
    static let familyPack = "The accessibility pack for this game is on the family shelf"
    static let notOpen = "The accessibility pack for this game is not open on this account"
    static let checkOnline = "Connect to the internet to use this game's accessibility pack"
    static let fileMissing = "The game file is missing from this iPhone. Delete it from My games and add it again."
    static let playerMissing = "The player for added games is not on this iPhone yet. Connect to the internet and try again."
    static let playerNotReady = "The Arcade's player for added games is not ready yet. Try again after the next Arcade update."

    /// The name a new import starts with: the file's name without its extension.
    static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return cleanTitle(base) ?? "Added game"
    }

    /// A usable title (trimmed, one line, 80 characters at most), or nil when nothing is left.
    static func cleanTitle(_ raw: String) -> String? {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    /// What VoiceOver says for a row: the status (or the reason) first, then the title.
    static func rowLabel(title: String, status: ArcadeImportStatus) -> String {
        ArcadeShelf.lockedLabel(title: title, reason: status.words)
    }

    /// The download slot an added game's packs use in ArcadeService.downloading.
    static func downloadKey(_ localId: String) -> String { "import-" + localId }
}

// MARK: - Where an added game plays

/// An added game's ROM file, served by the scheme handler at a pack path.
struct ArcadeOverlay: Equatable {
    /// The path under kadearcade://game/ or kadearcade://kit/ ("games/<id>/local/rom.z64").
    let path: String
    let file: URL
    let length: Int64
    var mime: String? = nil
}

enum ArcadeImportPlay {
    /// The kit's generic plain player (games/_plain/play.html?system=..&rom=..).
    static let plainEntry = "games/_plain/play.html"
    static let plainBase = "games/_plain/"

    /// The ROM's path relative to the plain player's folder, unique per import
    /// so the emulator's own storage never mixes two games.
    static func plainROM(_ record: ArcadeImportRecord) -> String {
        "local/" + record.localId + "." + record.system.keptExtension
    }

    /// Where the scheme handler serves it: under the plain player's folder.
    static func plainROMPath(_ record: ArcadeImportRecord) -> String { plainBase + plainROM(record) }

    /// The plain player's query: the system, and the ROM relative to the page.
    static func plainQuery(_ record: ArcadeImportRecord) -> String {
        "system=" + record.system.rawValue + "&rom=" + plainROM(record)
    }

    /// Where an accessibility pack's page expects the ROM: pack.json's
    /// romPath, else the kit's own layout, games/<id>/local/rom.<ext>.
    static func packROMPath(_ romPath: String?, gameId: String, system: ArcadeSystem) -> String {
        if let romPath, let clean = ArcadePaths.normalize(romPath) { return clean }
        return "games/" + gameId + "/local/rom." + system.keptExtension
    }

    /// The saves' key: the import's local id, never a pack's id, so two
    /// people's copies of a game on one phone never share a save file.
    static func saveKey(_ record: ArcadeImportRecord) -> String { "import-" + record.localId }

    /// Report a problem: the No-Intro sha1 names the game for Kade, not the file.
    static func reportTarget(_ record: ArcadeImportRecord) -> ArcadeReportTarget {
        let version = record.accessPack.map { "accessibility pack " + $0.version } ?? "plays as the original game"
        return ArcadeReportTarget(gameId: "import-" + record.system.rawValue + "-" + record.sha1,
                                  title: record.title, version: version)
    }
}
