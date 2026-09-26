import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

// MARK: - The described video player (Sep 25 2026, Part 291)
//
// Moved out of DescribedVideoView.swift. Her words after her first real
// described video (a Looney Tunes short): "Video doesn't continue playing
// audio when you leave the app" and "live captions are appreciated but
// voiceover does read them by default and it talks over the film".
//
// 1. LEAVING THE APP. project.yml already declares UIBackgroundModes audio and
//    the sheet already used a non-mixing .playback session, and the "Listen to
//    the described audio" copy (M4A) always carried on in the background. The
//    VIDEO stopped because AVPlayer's audiovisualBackgroundPlaybackPolicy
//    defaults to .automatic, which pauses a player whose item has a picture
//    when the app leaves the foreground or the screen locks.
//    .continuesIfPossible keeps the sound going. The Lock Screen and headphone
//    buttons are wired here the Library's way (ReadingRoomPlayer.wireRemote):
//    SwiftUI's VideoPlayer does not publish Now Playing by itself.
//
// 2. CAPTIONS. The described MP4 carries two text tracks, "Captions" first and
//    "Audio descriptions (text)". ffmpeg's MP4 muxer always enables the first
//    text track, so AVKit shows the captions, and VoiceOver's Media
//    Descriptions setting (Settings, Accessibility, VoiceOver, Verbosity)
//    speaks whatever captions the system player shows, over the film.
//    With VoiceOver on, the player now turns the SYSTEM captions off and draws
//    the same captions itself, hidden from VoiceOver, so anyone watching with
//    her still sees them. "Read captions with VoiceOver" (off by default, kept
//    in kade.describedVideo.readCaptions) puts the system captions back, and
//    VoiceOver then follows her Media Descriptions choice: speech, braille, or
//    both. Sent to a TV with AirPlay, the system captions stay on: the TV
//    shows them and the phone has nothing on screen to read.
//
// 3. STILL READ (Sep 26 2026, Part 295). After a Road Runner short with no
//    dialogue: "the onscreen captioning is read out by voiceover still and
//    talks over the film". That copy's only text track is "Audio
//    descriptions (text)", switched off in the file (media.ts
//    quietTextTracks), so the phone switched it back on. The film started
//    playing BEFORE the captions file had downloaded and the captions were
//    turned off, and until then AVPlayer's automatic media selection
//    (appliesMediaSelectionCriteriaAutomatically, on by default) was free to
//    pick a text track in her language because of her Subtitles & Captioning
//    settings (Closed Captions + SDH); AVKit's "Auto" can ask for the same
//    pick later. Now, while quiet: the automatic pick is off on the player
//    before the film is loaded, every text track is switched off BEFORE Play,
//    again when the film is ready, and again whenever anything switches one
//    on (AVPlayerItem.mediaSelectionDidChangeNotification, with a check on
//    the clock as a backstop). AVKit's subtitle menu cannot tell the player
//    whether a change was hers or automatic, so while quiet a track picked
//    there goes straight back off; the Read captions button is how she has
//    them read. The rule is DescribedCaptionPlan (DescribedCaptions.swift,
//    tested in DescribedCaptionsTests).
//
// Her Library rule holds: nothing resumes by itself. A call or another app's
// sound pauses the film (AVPlayer does that); Play is always her press.

/// Owns the described copy's AVPlayer while the player sheet is up: the sound
/// that carries on outside the app, the Lock Screen, and which captions show.
@MainActor
final class DescribedVideoPlayback: ObservableObject {
    let player = AVPlayer()
    /// The caption the app is drawing (only while `drawsCaptions`).
    @Published private(set) var caption = ""
    /// True while the app, not AVKit, shows the captions: VoiceOver is on, she
    /// has not asked for them to be read, and the film plays on the phone.
    @Published private(set) var drawsCaptions = false

    private var title = ""
    private var isVideo = true
    private var cues: [DescribedCaptionCue] = []
    /// nil until the captions file has been read; then whether it had any.
    private var hasDialogue: Bool?
    private var voiceOver = false
    private var readAloud = false
    /// The open film's list of text tracks, once loaded.
    private var legible: AVMediaSelectionGroup?
    private var timeObserver: Any?
    private var watches: [NSKeyValueObservation] = []
    /// AVPlayerItem.mediaSelectionDidChangeNotification for the open film.
    private var selectionWatch: NSObjectProtocol?
    private var remoteWired = false
    private var nowPlayingSecond = -1

    init() {
        // THE background fix (see 1 above).
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    // MARK: Open and close

    /// Opens the film and plays it. Her caption choice comes in with it, so a
    /// quiet film has every text track off before it plays (see 3 above).
    func open(url: URL, title: String, isVideo: Bool, voiceOver: Bool, readAloud: Bool) async {
        guard player.currentItem == nil else { return }
        self.title = title
        self.isVideo = isVideo
        self.voiceOver = voiceOver
        self.readAloud = readAloud
        // Not mixing: a mixing session is never the Now Playing app, so the
        // headphone and Lock Screen buttons would do nothing (the Library's
        // lesson). close() puts the app's usual mixing session back.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        let item = AVPlayerItem(url: url)
        item.externalMetadata = [
            Self.metadata(.commonIdentifierTitle, title),
            Self.metadata(.commonIdentifierArtist, "Described by Kade-AI"),
        ]
        // Before the item is current: AVPlayer makes its automatic pick the
        // moment an item becomes current.
        player.appliesMediaSelectionCriteriaAutomatically = plan.systemMayPick
        player.replaceCurrentItem(with: item)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        watches = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateNowPlaying() }
            },
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in await self?.applyCaptions() }
            },
            // Ready to play is when AVPlayer and AVKit settle the text
            // tracks, so her choice goes back on top then.
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                Task { @MainActor in await self?.applyCaptions() }
            },
        ]
        selectionWatch = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.keepQuiet() }
        }
        wireRemote()
        // Text tracks off BEFORE Play when quiet. Their list comes from the
        // same header AVPlayer reads before it can play, so this adds next to
        // no wait.
        await applyCaptions()
        // Done or the escape gesture while it loaded: close() already ran.
        guard player.currentItem === item else { return }
        player.play()
        updateNowPlaying()
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        watches.forEach { $0.invalidate() }
        watches = []
        if let selectionWatch { NotificationCenter.default.removeObserver(selectionWatch) }
        selectionWatch = nil
        legible = nil
        unwireRemote()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    // MARK: Captions

    /// The captions file, from its six-hour signed link (a plain download, no
    /// sign-in). If it cannot be read nothing is drawn; playback is unaffected.
    func loadCaptions(from url: URL?) async {
        guard let url, hasDialogue == nil,
              let fetched = try? await URLSession.shared.data(from: url),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200 else { return }
        cues = DescribedCaptions.parse(String(decoding: fetched.0, as: UTF8.self))
        hasDialogue = !cues.isEmpty
    }

    func setCaptionChoice(voiceOver: Bool, readAloud: Bool) async {
        self.voiceOver = voiceOver
        self.readAloud = readAloud
        await applyCaptions()
    }

    /// The rule for right now (DescribedCaptionPlan, see 3 above).
    private var plan: DescribedCaptionPlan {
        DescribedCaptionPlan.choose(voiceOver: voiceOver, readAloud: readAloud,
                                    external: player.isExternalPlaybackActive, hasDialogue: hasDialogue)
    }

    /// Quiet (VoiceOver on, not asked to read, on the phone): the system
    /// captions go OFF, AVPlayer's automatic pick is off so it cannot put
    /// them back, and the app draws them. Otherwise the system shows the
    /// Captions track, never "Audio descriptions (text)", which the narrator
    /// already says. An explicit selection also stops AVPlayer re-applying
    /// the system's automatic caption choice to this item.
    private func applyCaptions() async {
        // At once, before any wait, so a change of choice leaves no gap.
        player.appliesMediaSelectionCriteriaAutomatically = plan.systemMayPick
        guard let item = player.currentItem else {
            drawsCaptions = false
            caption = ""
            return
        }
        let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard player.currentItem === item else { return }
        // Read again: the choice, or AirPlay, can change while the list loads.
        let chosen = plan
        player.appliesMediaSelectionCriteriaAutomatically = chosen.systemMayPick
        if let group {
            legible = group
            switch chosen {
            case .quiet, .off:
                if group.allowsEmptySelection { item.select(nil, in: group) }
            case .captions:
                // media.ts assemble() puts Captions FIRST whenever the copy has dialogue.
                item.select(group.options.first, in: group)
            case .automatic:
                // The captions file could not be read: leave it to the system.
                item.selectMediaOptionAutomatically(in: group)
            }
        }
        // No list yet (readiness tries again) or no text tracks at all: the
        // system shows nothing, so the drawn captions still follow the plan.
        if case .quiet(let draws) = chosen { drawsCaptions = draws } else { drawsCaptions = false }
        caption = drawsCaptions ? DescribedCaptions.caption(at: player.currentTime().seconds, in: cues) : ""
    }

    /// While quiet, a text track that comes back on (AVPlayer, AVKit's
    /// "Auto", her settings, or AVKit's subtitle menu: none of them says
    /// which) goes straight back off. Only a track actually showing is
    /// touched, so switching it off (which posts the same notification) ends
    /// there.
    private func keepQuiet() {
        guard let item = player.currentItem, let legible, legible.allowsEmptySelection,
              plan.mustSwitchOff(trackShowing: item.currentMediaSelection.selectedMediaOption(in: legible) != nil)
        else { return }
        player.appliesMediaSelectionCriteriaAutomatically = false
        item.select(nil, in: legible)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        // The backstop for 3 above: a track that came back on without the
        // notification goes off within a quarter of a second.
        keepQuiet()
        if drawsCaptions {
            let now = DescribedCaptions.caption(at: seconds, in: cues)
            if now != caption { caption = now }
        }
        // The Lock Screen's clock, once a second (and on every seek: the
        // periodic observer also fires when time jumps).
        let second = Int(seconds)
        if second != nowPlayingSecond {
            nowPlayingSecond = second
            updateNowPlaying()
        }
    }

    // MARK: Transport (the Lock Screen and headphone buttons)

    func play() {
        player.play()
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        updateNowPlaying()
    }

    func togglePlay() {
        if player.rate == 0 { play() } else { pause() }
    }

    /// How fast the whole video plays (Sep 25 2026, remembered for her
    /// account). Play uses it from then on; a playing film changes at once.
    /// AVPlayer keeps voices at their own pitch when sped up.
    func setSpeed(_ value: Double) {
        let speed = Float(min(3, max(0.5, value)))
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
        updateNowPlaying()
    }

    func skip(_ delta: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        seek(to: now + delta)
    }

    func seek(to seconds: Double) {
        var target = max(0, seconds)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            target = min(target, max(0, duration - 0.5))
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    private func updateNowPlaying() {
        guard let item = player.currentItem else { return }
        let elapsed = player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Described by Kade-AI",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? max(0, elapsed) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? Double(player.rate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: (isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue,
        ]
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The Library's shape (ReadingRoomPlayer.wireRemote). The Library's book
    /// let go of these buttons when this player opened
    /// (LibraryNowPlaying.pauseForOtherAudio("a described video")) and takes
    /// them back the next time she presses Play on the book.
    private func wireRemote() {
        guard !remoteWired else { return }
        remoteWired = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-10) }; return .success }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(10) }; return .success }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func unwireRemote() {
        guard remoteWired else { return }
        remoteWired = false
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.skipBackwardCommand, center.skipForwardCommand, center.changePlaybackPositionCommand,
        ]
        for command in commands { command.removeTarget(nil) }
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private static func metadata(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

// MARK: - The sheet

/// AVKit's own player (its controls are VoiceOver-labelled by Apple), with a
/// Done button and the escape gesture, the Sound Booth's player rule.
struct DescribedVideoPlayerSheet: View {
    let url: URL
    let title: String
    let isVideo: Bool
    let captionsURL: URL?
    /// The speed she last chose for finished videos, and where a new choice
    /// goes to be kept (her account, via the describer screen).
    var playbackRate: Double = 1
    var onPlaybackRate: ((Double) -> Void)? = nil
    @State private var speed: Double = 1
    @State private var keptSpeed: Double = 1
    static let playbackSpeeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    @StateObject private var playback = DescribedVideoPlayback()
    @AppStorage("kade.describedVideo.readCaptions") private var readCaptions = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: playback.player) {
                captionOverlay
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // `.task` can start before onAppear, so the player opens here.
            .task {
                let start = Self.playbackSpeeds.min(by: { abs($0 - playbackRate) < abs($1 - playbackRate) }) ?? 1
                keptSpeed = start
                speed = start
                playback.setSpeed(start)
                // Her caption choice goes in with the film (Part 295), so a
                // quiet film is quiet from its first frame, not only once the
                // captions file has downloaded.
                await playback.open(url: url, title: title, isVideo: isVideo,
                                    voiceOver: voiceOverOn, readAloud: readCaptions)
                await playback.loadCaptions(from: captionsURL)
                await playback.setCaptionChoice(voiceOver: voiceOverOn, readAloud: readCaptions)
            }
            .onChange(of: voiceOverOn) { _, on in
                Task { await playback.setCaptionChoice(voiceOver: on, readAloud: readCaptions) }
            }
            .onChange(of: readCaptions) { _, read in
                Task { await playback.setCaptionChoice(voiceOver: voiceOverOn, readAloud: read) }
            }
            .onChange(of: speed) { _, value in
                playback.setSpeed(value)
                guard value != keptSpeed else { return }
                keptSpeed = value
                onPlaybackRate?(value)
            }
            .onDisappear { playback.close() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Stops playing and goes back.")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    speedMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    if isVideo && voiceOverOn {
                        Button(readCaptions ? "Stop reading captions" : "Read captions") {
                            readCaptions.toggle()
                        }
                        .accessibilityHint(readCaptions
                            ? "VoiceOver stops reading the captions. They stay on screen for anyone watching with you."
                            : "VoiceOver reads the captions over the film, the way Media Descriptions in VoiceOver's Verbosity settings says.")
                    }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
        }
    }

    /// Playback speed for the whole video, one menu (a real control, said
    /// with its value). The choice is kept for her account.
    private var speedMenu: some View {
        Menu {
            Picker("Playback speed", selection: $speed) {
                ForEach(Self.playbackSpeeds, id: \.self) { value in
                    Text(Self.speedName(value)).tag(value)
                }
            }
        } label: {
            Label("Playback speed", systemImage: "speedometer")
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Self.speedName(speed))
        .accessibilityHint("How fast the whole video plays, dialogue and narration together. Remembered for your account.")
    }

    static func speedName(_ value: Double) -> String {
        let number = value == value.rounded() ? String(Int(value)) : String(value)
        return value == 1 ? "\(number)×, normal" : "\(number)×"
    }

    /// Drawn only while the system captions are off. Hidden from VoiceOver on
    /// purpose: it is for whoever is watching with her. Above the picture and
    /// below AVKit's controls (VideoPlayer's overlay), never touchable.
    @ViewBuilder
    private var captionOverlay: some View {
        if playback.drawsCaptions && !playback.caption.isEmpty {
            VStack {
                Spacer()
                Text(playback.caption)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 56)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
