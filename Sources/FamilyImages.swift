import SwiftUI
import UIKit
import ImageIO

// MARK: - Family history: pictures (Sep 29 2026)
//
// Every family picture is private: it is fetched from a signed link that
// lasts an hour, never from a public address, and it is kept only for the
// signed-in account.
// - Links: the one a payload carried (a thumbnail, a face crop), else a
//   150 ms coalescing queue asks POST /media/sign for a screenful at once.
//   A refused or expired link is signed again once; after that the picture
//   stays its initials or its words (never an empty frame).
// - Session: its own ephemeral URLSession with no sign-in header and no
//   URL cache, so nothing lands anywhere wipe() would miss, and signed links
//   never wait on the site's pacing gate.
// - Memory: an NSCache keyed by account, media id, size and drawn pixels
//   (500 pictures, 64 MB).
// - Disk: Caches/FamilyHistory/<account>/<media id>.<size>.jpg, readable only
//   after the phone's first unlock, trimmed to 250 MB least recently used
//   first. Caches are never backed up.
// - At most six downloads at once, first come first served, in the order the
//   screen asks (the tree asks nearest first). Pictures decode straight to
//   the size they are drawn (ImageIO), so a large scan is never a full
//   bitmap in memory.

@MainActor
final class FamilyImageLoader {
    static let shared = FamilyImageLoader()

    private struct Link {
        let url: URL
        let at: Date
    }

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let slots = 6
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Signed links by "<media id>.<size>".
    private var links: [String: Link] = [:]
    private var signWanted: [FHSize: [String]] = [:]
    private var signWaiters: [String: [CheckedContinuation<URL?, Never>]] = [:]
    private var signScheduled = false
    /// Moves on at every wipe, so a download that finishes after a sign-out
    /// is never kept or drawn.
    private var generation = 0
    private var saves = 0
    /// Links last an hour; one older than this is signed again first.
    private let linkLife: TimeInterval = 50 * 60

    private init() {
        memory.countLimit = 500
        memory.totalCostLimit = 64 * 1024 * 1024
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    private static func linkKey(_ id: String, _ size: FHSize) -> String {
        "\(id).\(size.rawValue)"
    }

    private func memoryKey(_ id: String, _ size: FHSize, _ pixels: Int) -> NSString? {
        guard let userId = FamilySession.shared.userId else { return nil }
        return FamilyCacheNames.memoryKey(userId: userId, mediaId: id, size: size, pixels: pixels) as NSString
    }

    // MARK: Asking for a picture

    /// Keeps the signed links a payload carried, so they are used before any
    /// signing.
    func remember(_ image: FHImage?) {
        guard let image, !image.id.isEmpty else { return }
        let now = Date()
        if let thumb = image.thumb, links[Self.linkKey(image.id, .t)] == nil {
            links[Self.linkKey(image.id, .t)] = Link(url: thumb, at: now)
        }
        if let face = image.face, links[Self.linkKey(image.id, .f)] == nil {
            links[Self.linkKey(image.id, .f)] = Link(url: face, at: now)
        }
    }

    /// The picture, if it is already in memory at this size.
    func cached(_ image: FHImage, size: FHSize, pixels: Int) -> UIImage? {
        guard !image.id.isEmpty, let key = memoryKey(image.id, size, pixels) else { return nil }
        return memory.object(forKey: key)
    }

    /// The picture at `size`, decoded to `pixels` on its longer side: from
    /// memory, this account's disk cache, or its signed link. Nil when it
    /// cannot be had (the caller keeps the initials or the words).
    func image(for image: FHImage, size: FHSize, pixels: Int) async -> UIImage? {
        let id = image.id
        guard !id.isEmpty, let userId = FamilySession.shared.userId,
              let key = memoryKey(id, size, pixels) else { return nil }
        if let hit = memory.object(forKey: key) { return hit }
        remember(image)
        let asked = generation
        await takeSlot()
        defer { giveSlot() }
        if Task.isCancelled || asked != generation { return nil }
        if let hit = memory.object(forKey: key) { return hit }
        let file = FamilyDiskStore.folder(userId: userId)?
            .appendingPathComponent(FamilyCacheNames.imageFile(mediaId: id, size: size), isDirectory: false)
        if let file, let fromDisk = await Self.decodeFile(file, pixels: pixels) {
            guard asked == generation else { return nil }
            FamilyDiskStore.touch(file)
            keep(fromDisk, key: key)
            return fromDisk
        }
        guard let data = await download(id, size: size, asked: asked), asked == generation else { return nil }
        guard let picture = await Self.decode(data, pixels: pixels), asked == generation else { return nil }
        if let file { save(data, to: file) }
        keep(picture, key: key)
        return picture
    }

    /// The picture's file, to save to Photos or share (her Sep 29 yes, for
    /// every picture, restored copies too): the screen size when it has one,
    /// named plainly, with "restored with AI" in a restored copy's name.
    func shareFile(for image: FHImage) async -> URL? {
        guard !image.id.isEmpty, let userId = FamilySession.shared.userId else { return nil }
        let size = image.best(.s)
        let asked = generation
        let kept: URL? = FamilyDiskStore.folder(userId: userId)?
            .appendingPathComponent(FamilyCacheNames.imageFile(mediaId: image.id, size: size), isDirectory: false)
        var bytes: Data? = kept.flatMap { FamilyDiskStore.load($0) }
        if bytes == nil {
            remember(image)
            bytes = await download(image.id, size: size, asked: asked)
            if let fetched = bytes, let keptFile = kept, asked == generation { save(fetched, to: keptFile) }
        }
        guard let data = bytes, asked == generation else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FamilyShare", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(Self.shareName(image) + ".jpg", isDirectory: false)
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return nil
        }
        return file
    }

    /// The server's own file name when it sent one ("Photo of Ada Example,
    /// about 1920", with "restored with AI" on a restored copy), made safe
    /// for a file; else "Family photo", "Grave photo", "Record scan", and a
    /// restored copy adds "(restored with AI)".
    static func shareName(_ image: FHImage) -> String {
        if let said = FamilyAccessRules.nonEmpty(image.shareName) {
            let bad = Set("/\\:?*\"<>|")
            let cleaned = String(said.map { bad.contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = String(cleaned.prefix(120))
            if !trimmed.isEmpty { return trimmed }
        }
        let base: String
        switch image.categoryKind {
        case .portrait, .photo, .restored, .other: base = "Family photo"
        case .grave: base = "Grave photo"
        case .record: base = "Record scan"
        case .document, .story: base = "Family document"
        }
        return image.isRestoredCopy ? base + " (restored with AI)" : base
    }

    // MARK: Sign-out

    /// Sign-out, or access lost: memory, links, waiting signatures and every
    /// family file on disk go.
    func wipe() {
        generation += 1
        memory.removeAllObjects()
        links = [:]
        signWanted = [:]
        let waiters = signWaiters
        signWaiters = [:]
        for (_, list) in waiters {
            for waiter in list { waiter.resume(returning: nil) }
        }
        FamilyDiskStore.wipeAll()
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("FamilyShare", isDirectory: true))
    }

    // MARK: Downloading

    private func keep(_ picture: UIImage, key: NSString) {
        let cost: Int = picture.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(picture, forKey: key, cost: cost)
    }

    private func save(_ data: Data, to file: URL) {
        FamilyDiskStore.save(data, to: file)
        saves += 1
        guard saves % 25 == 1 else { return }
        let folder = file.deletingLastPathComponent()
        let limit = FamilyCacheNames.diskLimit
        Task.detached(priority: .background) {
            FamilyDiskStore.trim(folder: folder, limit: limit)
        }
    }

    /// The bytes, from a fresh link (signed again once if refused).
    private func download(_ id: String, size: FHSize, asked: Int) async -> Data? {
        var url: URL? = freshLink(id, size)
        if url == nil { url = await signedLink(id, size: size) }
        guard let first = url, asked == generation else { return nil }
        if let data = await fetch(first) { return data }
        // Refused or expired: sign once more, then give up quietly.
        links[Self.linkKey(id, size)] = nil
        guard let again = await signedLink(id, size: size), again != first, asked == generation else { return nil }
        return await fetch(again)
    }

    private func freshLink(_ id: String, _ size: FHSize) -> URL? {
        let key = Self.linkKey(id, size)
        guard let link = links[key] else { return nil }
        guard Date().timeIntervalSince(link.at) < linkLife else {
            links[key] = nil
            return nil
        }
        return link.url
    }

    private func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else { return nil }
        return data
    }

    private func takeSlot() async {
        if running < slots {
            running += 1
            return
        }
        // giveSlot hands its place straight to the first one waiting.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiting.append(c)
        }
    }

    private func giveSlot() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Signing a screenful at once

    private func signedLink(_ id: String, size: FHSize) async -> URL? {
        let key = Self.linkKey(id, size)
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            signWaiters[key, default: []].append(c)
            if !(signWanted[size] ?? []).contains(id) {
                signWanted[size, default: []].append(id)
            }
            scheduleSigning()
        }
    }

    private func scheduleSigning() {
        guard !signScheduled else { return }
        signScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await FamilyImageLoader.shared.signNow()
        }
    }

    private func signNow() async {
        signScheduled = false
        let wanted = signWanted
        signWanted = [:]
        for (size, ids) in wanted {
            for chunk in FamilyBatches.chunks(ids, size: 100) {
                let answer: FHSigned? = try? await FamilyHistoryService.shared.sign(ids: chunk, size: size)
                let now = Date()
                for id in chunk {
                    let key = Self.linkKey(id, size)
                    let url: URL? = answer?.urls[id]
                    if let url { links[key] = Link(url: url, at: now) }
                    let list = signWaiters.removeValue(forKey: key) ?? []
                    for waiter in list { waiter.resume(returning: url) }
                }
            }
        }
    }

    // MARK: Decoding (off the main actor)

    private static func decode(_ data: Data, pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            FamilyImageLoader.thumbnail(data, maxPixels: pixels)
        }.value
    }

    private static func decodeFile(_ file: URL, pixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return FamilyImageLoader.thumbnail(data, maxPixels: pixels)
        }.value
    }

    /// Decodes straight to the drawn size (ImageIO), orientation applied.
    nonisolated static func thumbnail(_ data: Data, maxPixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixels),
        ] as CFDictionary
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: small)
    }
}

// MARK: - One picture on screen

/// A family picture, or the person's initials in their side's colour while
/// it loads or when there is none. Always hidden from VoiceOver: the row,
/// card or cell it sits in carries the words (the alt text, the person's
/// sentence). Smart Invert leaves it alone.
struct FamilyPhoto: View {
    let image: FHImage?
    /// The size asked for (a thumbnail, the screen size, a face crop).
    var size: FHSize = .t
    /// The drawn size in points, on the longer side.
    let drawn: CGFloat
    var initials: String = ""
    var side: FHSide = .unknown
    var circle: Bool = false

    @Environment(\.displayScale) private var displayScale
    @KadeContrastPolicy private var highContrast: Bool
    @State private var loaded: Loaded?

    private struct Loaded {
        let key: String
        let picture: UIImage
    }

    /// What the load waits on: this picture at this size, and whether it is drawn yet.
    private struct Want: Equatable {
        let key: String
        let drawn: Bool
    }

    private var pixels: Int {
        let scaled: CGFloat = drawn * max(1, displayScale)
        return max(32, Int(scaled.rounded(.up)))
    }

    private var chosen: FHSize { image?.best(size) ?? size }

    private var key: String { "\(image?.id ?? "").\(chosen.rawValue).\(pixels)" }

    var body: some View {
        let mine: UIImage? = loaded?.key == key ? loaded?.picture : nil
        let picture: UIImage? = mine ?? cachedPicture
        let isDrawn: Bool = picture != nil
        framed(picture)
            .accessibilityHidden(true)
            .accessibilityIgnoresInvertColors(true)
            .task(id: Want(key: key, drawn: isDrawn)) {
                await load(isDrawn)
            }
    }

    @MainActor
    private var cachedPicture: UIImage? {
        guard let image else { return nil }
        return FamilyImageLoader.shared.cached(image, size: chosen, pixels: pixels)
    }

    @ViewBuilder
    private func framed(_ picture: UIImage?) -> some View {
        if circle {
            content(picture)
                .frame(width: drawn, height: drawn)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(borderColor, lineWidth: highContrast ? 2 : 0))
        } else {
            content(picture)
                .frame(width: drawn, height: drawn)
                .clipShape(RoundedRectangle(cornerRadius: drawn * 0.12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: drawn * 0.12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: highContrast ? 2 : 0))
        }
    }

    @ViewBuilder
    private func content(_ picture: UIImage?) -> some View {
        if let picture {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
        } else {
            FamilyInitials(initials: initials, side: side, drawn: drawn)
        }
    }

    private var borderColor: Color {
        highContrast ? Color.primary : Color.clear
    }

    @MainActor
    private func load(_ isDrawn: Bool) async {
        // Already drawn (from memory or this view's own load), or nothing to load.
        if isDrawn { return }
        guard let image, !image.id.isEmpty else { return }
        let wanted = key
        let picture = await FamilyImageLoader.shared.image(for: image, size: chosen, pixels: pixels)
        if Task.isCancelled { return }
        if let picture { loaded = Loaded(key: wanted, picture: picture) }
    }
}

/// Initials on the side's colour: never a silhouette, never an empty frame.
struct FamilyInitials: View {
    let initials: String
    let side: FHSide
    let drawn: CGFloat
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        let tint: Color = FamilySideColor.color(side, contrast: highContrast)
        ZStack {
            Rectangle().fill(tint.opacity(highContrast ? 0.3 : 0.18))
            Text(initials.isEmpty ? " " : initials)
                .font(.system(size: max(10, drawn * 0.36), weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .accessibilityHidden(true)
    }
}
