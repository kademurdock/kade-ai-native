import SwiftUI
import Combine
import UIKit

/// Sep 23 2026 redesign (A2) — the app-level home of the Library player, so a
/// book keeps playing while you move around the app.
///
/// Before this, `ReadingRoomView` owned its player and closed it in
/// `.onDisappear`, so tapping anywhere outside the Library killed the book.
/// Now the ONE `ReadingRoomService` and `ReadingRoomPlayer` live here for the
/// whole app. Only the OWNER moved: the streaming engine inside the player
/// (chunk fetch, buffer scheduling, the whole-chunk-wait and mixWithOthers
/// traps) is exactly as it was.
///
/// The root calls (names fixed by the contract stub):
///   - `LibraryNowPlaying.shared`
///   - `bind(client:voice:)`          once signed in; idempotent
///   - `stop()`                       on sign-out; closes the player completely
///   - `showPlayerRequest`            bump it; the Library tab shows the player
///   - `openItemRequest`              set an item id; it opens here, the Library
///                                    tab shows the player, and it goes back to nil
///   - `NowPlayingBar(openPlayer:)`   above the tab bar; draws nothing when idle
///
/// Her Library rule (Part 181) holds: nothing auto-plays. The book only ever
/// pauses BY ITSELF — for a voice message, a recording or a call — and never
/// resumes by itself; "Resume" is always her press.
///
/// One speaker for the player's announcements (chapter changes, errors, "the
/// end"): the Library screen on display says them, exactly as before. With no
/// Library screen on display, only what stopped the book (an error, the end)
/// is spoken, so a chapter change never talks over a chat.
@MainActor
final class LibraryNowPlaying: ObservableObject {
    static let shared = LibraryNowPlaying()

    /// Bumped by the root to ask the Library tab to show the player screen.
    @Published var showPlayerRequest = 0
    /// A Library item id the root wants opened on the Library tab. Opened
    /// here (so it works before the Library tab was ever visited), then set
    /// back to nil.
    @Published var openItemRequest: String?

    /// What is open in the player, for the bar and the Library's Continue row;
    /// nil when nothing is. Changes on open/close, play/pause and chapter
    /// changes only, never on the player's twice-a-second clock.
    @Published private(set) var current: LibraryNowPlayingItem?
    /// Why the book paused itself ("a voice message", "a recording", "a
    /// call"). Cleared by any play, and when the item changes or closes.
    @Published private(set) var pausedFor: String?
    /// True while a Library screen on display is showing its player screen.
    /// The Now Playing bar steps aside then (the full transport is right there).
    @Published private(set) var playerScreenOnDisplay = false
    /// The latest line for the Library screen on display to show and speak.
    @Published private(set) var message: LibraryMessage?

    /// The app's one Library service and player (nil until `bind` or the
    /// first Library screen creates them).
    private(set) var service: ReadingRoomService?
    private(set) var player: ReadingRoomPlayer?

    /// Something is open in the player (the bar will draw).
    var hasOpenItem: Bool { current != nil }

    private var playerWatch: [AnyCancellable] = []
    private var voiceWatch: [AnyCancellable] = []
    private weak var watchedVoice: VoiceService?
    private var requestWatch: AnyCancellable?
    /// Library screens on display, and whether each is showing the player.
    /// Keyed per screen, because two Library screens can be alive at once
    /// (the share sheet pushes a second over the Library tab's own).
    private var screens: [UUID: Bool] = [:]
    /// The item `pausedFor` belongs to.
    private var pausedBookID: String?
    private var showPlayerHandled = 0
    private var messageCount = 0
    private var openingRequest = false

    init() {
        requestWatch = $openItemRequest.sink { [weak self] id in
            guard id != nil else { return }
            Task { @MainActor in await self?.openRequestedItem() }
        }
    }

    // MARK: - The root's calls

    func bind(client: KadeAPIClient, voice: VoiceService) {
        ensure(client: client)
        guard watchedVoice !== voice else { return }
        watchedVoice = voice
        // A voice message starting, or the chat's microphone starting, pauses
        // the book. The microphone matters as much as the speaker: a book
        // playing into a recording ends up in the transcript.
        voiceWatch = [
            voice.$isClipPlaying.removeDuplicates().sink { [weak self] playing in
                guard playing else { return }
                Task { @MainActor in self?.pauseForOtherAudio("a voice message") }
            },
            voice.$isRecording.removeDuplicates().sink { [weak self] recording in
                guard recording else { return }
                Task { @MainActor in self?.pauseForOtherAudio("a recording") }
            },
        ]
    }

    /// The shared service and player, created on first use from `client`.
    /// Library screens call this too, so the Library works even if `bind`
    /// was never called.
    @discardableResult
    func ensure(client: KadeAPIClient) -> (service: ReadingRoomService, player: ReadingRoomPlayer) {
        if let service, let player { return (service, player) }
        let newService = ReadingRoomService(client: client)
        let newPlayer = ReadingRoomPlayer(service: newService)
        service = newService
        player = newPlayer
        // Collection playback carries on from here, wherever you are in the
        // app; the Library screen follows the player when it is on display.
        newPlayer.onQueueNext = { [weak self] id in
            Task { @MainActor in await self?.playNextInCollection(id) }
        }
        playerWatch = [
            newPlayer.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            newPlayer.$announcement.sink { [weak self] text in
                guard text != nil else { return }
                Task { @MainActor in self?.routeAnnouncement() }
            },
        ]
        if openItemRequest != nil {
            Task { await openRequestedItem() }
        }
        return (newService, newPlayer)
    }

    /// Closes the player completely (sign-out) and forgets the shelf, so the
    /// next person to sign in never sees this one's books.
    func stop() {
        if let player, player.book != nil {
            player.queue = []
            player.close()
        }
        service?.shelf = nil
        pausedFor = nil
        pausedBookID = nil
        openItemRequest = nil
        showPlayerHandled = showPlayerRequest
        refresh()
    }

    /// Another sound is starting (a voice message, a recording, a call):
    /// pause the book and remember why. Never resumes by itself.
    func pauseForOtherAudio(_ reason: String) {
        guard let player, player.book != nil else { return }
        if player.isPlaying {
            player.pause()
            pausedFor = reason
            pausedBookID = player.book?.id
        }
        // A call also takes the lock-screen and headphone buttons, and its own
        // wiring removes EVERY target on play/pause when it hangs up. So the
        // book lets go of them now (the headphone button belongs to the call)
        // and takes them back the next time it plays. Part 291: the described
        // video player wires the same buttons while it plays outside the app,
        // so the book lets go for it too (two targets would both fire).
        if reason == "a call" || reason == "a described video" { player.yieldRemoteControls() }
    }

    // MARK: - The bar's buttons

    /// Play or pause. Resuming re-prepares the book's own audio session.
    func togglePlay() {
        player?.togglePlay()
    }

    /// "Stop and close": stops playback, saves the place, hides the bar.
    func closePlayer() {
        guard let player, let book = player.book else { return }
        player.queue = []
        player.close()
        say("Stopped \(book.title). Your place is saved.")
    }

    // MARK: - Library screens

    /// A Library screen on display reports itself, and whether it is
    /// showing the player screen.
    func libraryScreen(_ id: UUID, showsPlayer: Bool) {
        screens[id] = showsPlayer
        screensChanged()
    }

    /// A Library screen left the display (another tab, a push on top, gone).
    func libraryScreenGone(_ id: UUID) {
        screens[id] = nil
        screensChanged()
    }

    /// True once per bump of `showPlayerRequest` when something is open, so
    /// only one Library screen answers it even with two alive.
    func takeShowPlayerRequest() -> Bool {
        guard showPlayerRequest != showPlayerHandled else { return false }
        showPlayerHandled = showPlayerRequest
        return player?.book != nil
    }

    /// One line for the Library to say. A Library screen on display shows it
    /// in its status line and speaks it; with none on display, it is spoken.
    func say(_ text: String) {
        if screens.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            messageCount += 1
            message = LibraryMessage(id: messageCount, text: text)
        }
    }

    // MARK: - Private

    private func screensChanged() {
        let showing = screens.values.contains(true)
        guard showing != playerScreenOnDisplay else { return }
        playerScreenOnDisplay = showing
        // A video needs its picture: it pauses (and stays open) when the
        // player screen leaves the display. Books and recordings play on.
        if !showing, let player, player.isPlaying, Self.isVideo(player) {
            player.pause()
        }
    }

    private static func isVideo(_ player: ReadingRoomPlayer) -> Bool {
        guard let book = player.book, book.isAudio, book.tracks.indices.contains(player.s) else { return false }
        // The same test VideoPane uses to show its picture.
        return (book.tracks[player.s].mime ?? "").hasPrefix("video/")
    }

    private func refresh() {
        var next: LibraryNowPlayingItem?
        if let player, let book = player.book {
            next = LibraryNowPlayingItem(book: book, part: player.s, isPlaying: player.isPlaying)
        }
        // Any play, or a different item (or none), ends the automatic pause.
        if pausedFor != nil && (next == nil || next?.id != pausedBookID || next?.isPlaying == true) {
            pausedFor = nil
            pausedBookID = nil
        }
        if next != current { current = next }
    }

    private func routeAnnouncement() {
        guard let player, let text = player.announcement else { return }
        player.announcement = nil
        if screens.isEmpty {
            // Away from the Library: only what STOPPED the book is worth
            // interrupting for (an error, the end). Chapter changes and
            // skips stay quiet.
            if !player.isPlaying { UIAccessibility.post(notification: .announcement, argument: text) }
        } else {
            say(text)
        }
    }

    private func playNextInCollection(_ id: String) async {
        guard let service, let player else { return }
        do {
            let book = try await service.openBook(id)
            player.open(book)
            player.play()
        } catch {
            say(error.localizedDescription)
        }
    }

    private func openRequestedItem() async {
        guard !openingRequest, let service, let player else { return }
        openingRequest = true
        while let id = openItemRequest {
            if player.book?.id != id {
                do {
                    let book = try await service.openBook(id)
                    player.open(book)
                } catch {
                    say(error.localizedDescription)
                }
            }
            if player.book?.id == id { showPlayerRequest += 1 }
            if openItemRequest == id { openItemRequest = nil }
        }
        openingRequest = false
    }
}

/// What the Now Playing bar and the Library's Continue row show.
struct LibraryNowPlayingItem: Equatable {
    let id: String
    let title: String
    let kind: String
    let category: String
    let isAudio: Bool
    /// Zero-based chapter (a book) or part (a recording).
    let part: Int
    let partCount: Int
    let isPlaying: Bool

    init(book: RRBook, part: Int, isPlaying: Bool) {
        id = book.id
        title = book.title
        kind = book.kind
        category = book.category
        isAudio = book.isAudio
        self.part = part
        partCount = book.partCount
        self.isPlaying = isPlaying
    }

    /// "Chapter 3 of 12", "Part 2 of 5".
    var position: String {
        "\(isAudio ? "Part" : "Chapter") \(part + 1) of \(max(partCount, part + 1))"
    }
}

/// One line the Library wants said. The id makes the same words said twice
/// ("Forward 10 seconds.") a new line both times.
struct LibraryMessage: Equatable {
    let id: Int
    let text: String
}

/// The mini player above the tab bar (A2). Draws nothing unless something is
/// open in the Library's player, and steps aside while a Library player
/// screen is on display (its transport is right there, and two Pause buttons
/// would be one too many under VoiceOver). It pads itself, so the root can
/// place it bare.
///
/// VoiceOver: three sibling controls, never flattened (the Amber rule):
///   1. "Now playing: <title>, <position>" (+ ". Paused for a call"), opens the player
///   2. "Play" / "Pause", and "Resume" after an automatic pause
///   3. "Stop and close"
/// The jacket is decoration and hidden. No animation, so nothing to gate.
struct NowPlayingBar: View {
    var openPlayer: () -> Void
    @ObservedObject private var model: LibraryNowPlaying
    @Environment(\.dynamicTypeSize) private var typeSize
    @KadeContrastPolicy private var highContrast: Bool

    init(openPlayer: @escaping () -> Void) {
        self.openPlayer = openPlayer
        _model = ObservedObject(wrappedValue: LibraryNowPlaying.shared)
    }

    var body: some View {
        if let item = model.current, !model.playerScreenOnDisplay {
            bar(item)
        }
    }

    /// Two lines from xxxLarge up, the same threshold as `KadeToolRow`.
    private var stacked: Bool { typeSize >= .xxxLarge }

    private func bar(_ item: LibraryNowPlayingItem) -> some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        LibraryJacket(kind: item.kind, category: item.category, title: item.title, width: 36, height: 36)
                        titleButton(item)
                    }
                    HStack(spacing: 12) {
                        playButton(item)
                        closeButton
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    LibraryJacket(kind: item.kind, category: item.category, title: item.title, width: 36, height: 36)
                    titleButton(item)
                    playButton(item)
                    closeButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .kadeGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func titleButton(_ item: LibraryNowPlayingItem) -> some View {
        Button(action: openPlayer) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(stacked ? 3 : 1)
                Text(item.position)
                    .font(.caption)
                    .foregroundStyle(highContrast ? Color.primary : Color.secondary)
                    .lineLimit(stacked ? 2 : 1)
                if let why = model.pausedFor {
                    Text("Paused for \(why)")
                        .font(.caption2)
                        .foregroundStyle(highContrast ? Color.primary : Color.secondary)
                        .lineLimit(stacked ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenTitle(item))
        .accessibilityHint("Opens the Library player.")
    }

    private func spokenTitle(_ item: LibraryNowPlayingItem) -> String {
        var words = "Now playing: \(item.title), \(item.position)"
        if let why = model.pausedFor { words += ". Paused for \(why)" }
        return words
    }

    private func playButton(_ item: LibraryNowPlayingItem) -> some View {
        let word = item.isPlaying ? "Pause" : (model.pausedFor != nil ? "Resume" : "Play")
        let symbol = item.isPlaying ? "pause.fill" : "play.fill"
        return Button {
            model.togglePlay()
        } label: {
            Group {
                if stacked {
                    Label(word, systemImage: symbol)
                        .font(.body.weight(.semibold))
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(highContrast ? Color.primary : Color.accentColor)
        .accessibilityLabel(word)
    }

    private var closeButton: some View {
        Button {
            model.closePlayer()
        } label: {
            Group {
                if stacked {
                    Label("Stop and close", systemImage: "xmark")
                        .font(.body.weight(.semibold))
                } else {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(highContrast ? Color.primary : Color.secondary)
        .accessibilityLabel("Stop and close")
        .accessibilityHint("Stops playback and hides this bar. Your place is saved.")
    }
}

/// A drawn jacket for Library rows, the Continue row and the Now Playing bar
/// (B7). The Library has no cover pictures: `RRBook.jacket` is the spoken
/// NLS-style blurb (title, author, publisher, synopsis), not an image, and the
/// shelf sends no picture at all. So this draws one, the way
/// `KadePaintedHeader` stands in for a missing painting: a colour that stays
/// the same for the same title, and a symbol for what the item is. A fixed
/// frame, so it never moves a row, and always hidden from VoiceOver; the row's
/// own label already says the title.
///
/// Part 292 (Sep 25 2026): where Kade's painted jacket exists for what the
/// item is (a book, an audiobook, a movie, TV, commercials, radio, music), it
/// fills the same frame instead (KadeArt.jacket). "Painted pictures" off,
/// high contrast, and cassettes or "other" recordings keep the drawn jacket.
/// Same frame, same hiding, same place in the row: nothing is said or moved.
struct LibraryJacket: View {
    let kind: String
    var category: String = ""
    let title: String
    var width: CGFloat = 40
    var height: CGFloat = 56
    @KadeContrastPolicy private var highContrast: Bool
    @AppStorage(KadeArt.showKey) private var showPictures = true

    /// The painted jacket, or nil for the drawn one.
    private var painting: UIImage? {
        guard showPictures, !highContrast, let name = KadeArt.jacket(kind: kind, category: category) else { return nil }
        return UIImage(named: name)
    }

    var body: some View {
        Group {
            if let painting {
                Color.clear
                    .overlay {
                        Image(uiImage: painting)
                            .resizable()
                            .scaledToFill()
                            .accessibilityIgnoresInvertColors(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                drawn
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private var drawn: some View {
        let tint = Self.tint(for: title)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(
                colors: highContrast ? [tint, tint] : [tint.opacity(0.9), tint.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            Image(systemName: symbol)
                .font(.system(size: min(width, height) * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .overlay {
            if highContrast { shape.stroke(Color.primary.opacity(0.65), lineWidth: 1.5) }
        }
    }

    private var symbol: String {
        if kind == "text" { return "book.closed.fill" }
        if kind == "video" { return "film.fill" }
        switch category {
        case "audiobook": return "headphones"
        case "music": return "music.note"
        case "radio": return "radio"
        case "cassette": return "recordingtape"
        case "movie", "tv", "vhs", "commercials", "psa": return "film.fill"
        default: return "waveform"
        }
    }

    /// Stable across launches (Swift's own hashValue is not).
    private static func tint(for title: String) -> Color {
        let palette: [Color] = [.indigo, .teal, .orange, .pink, .blue, .green, .purple, .brown, .red, .cyan, .mint]
        var hash = 0
        for scalar in title.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return palette[hash % palette.count]
    }
}
