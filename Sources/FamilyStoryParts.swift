import SwiftUI
import UIKit

// MARK: - Family history: a story's text and its Listen bar (Sep 29 2026)
//
// - FamilyStoryBlocks: the server's blocks as native text. h2 and h3 are
//   headings at their levels; each paragraph, list item and quote is its own
//   element. Emphasis and links come from the runs; a source number is a
//   small link ("[3]") that jumps to the Sources list. The paragraph being
//   read aloud is highlighted (a tint and a bar at its edge, never colour
//   alone).
// - FamilyStorySources: the numbered sources, each its own element, with
//   its link when it has one.
// - FamilyListenBar: the caption strip (the sentence being read, two lines
//   at most, on a solid band, hidden from VoiceOver), then Back one part,
//   Play or Pause, Forward one part, the speed, Stop, and which part this is.

enum FamilyStoryText {
    /// Source chips link to "kadefamilysource://3".
    static let sourceScheme = "kadefamilysource"

    static func sourceLink(_ n: Int) -> URL? {
        URL(string: sourceScheme + "://" + String(n))
    }

    /// The source number a chip's link carries, or nil for any other link.
    static func sourceNumber(_ url: URL) -> Int? {
        guard url.scheme == sourceScheme, let host = url.host else { return nil }
        return Int(host)
    }

    /// One block's runs as one Text: emphasis, links, and source chips. The
    /// sentence being read (`mark`, character offsets in the block's words)
    /// is underlined in the accent colour, which never moves the text.
    static func text(_ block: FHBlock, mark: FHSpan? = nil) -> Text {
        var out = Text(verbatim: "")
        var at = 0
        for run in block.runs {
            if run.source != nil {
                out = out + piece(run)
                continue
            }
            let count: Int = run.text.count
            let start: Int = at
            at += count
            guard let mark, mark.end > start, mark.start < start + count else {
                out = out + piece(run)
                continue
            }
            let chars: [Character] = Array(run.text)
            let from: Int = min(count, max(0, mark.start - start))
            let upTo: Int = max(from, min(count, mark.end - start))
            let before = String(chars[0..<from])
            let inside = String(chars[from..<upTo])
            let after = String(chars[upTo..<count])
            if !before.isEmpty { out = out + piece(run, before) }
            if !inside.isEmpty { out = out + piece(run, inside).underline(true, color: Color.accentColor) }
            if !after.isEmpty { out = out + piece(run, after) }
        }
        return out
    }

    /// One run (or part of one: `words`) with its emphasis and link.
    static func piece(_ run: FHRun, _ words: String? = nil) -> Text {
        if let n = run.source {
            var chip = AttributedString(" [" + String(n) + "]")
            chip.link = sourceLink(n)
            return Text(chip).font(.caption)
        }
        let shown: String = words ?? run.text
        var made: Text
        if let link = run.link {
            var linked = AttributedString(shown)
            linked.link = link
            made = Text(linked)
        } else {
            made = Text(verbatim: shown)
        }
        if run.strong == true { made = made.bold() }
        if run.em == true { made = made.italic() }
        return made
    }
}

struct FamilyStoryBlocks: View {
    let blocks: [FHBlock]
    /// The block being read aloud, if any.
    let active: Int?
    /// The sentence being read, underlined inside that block when found.
    var sentence: String = ""

    @KadeContrastPolicy private var highContrast: Bool

    static func blockId(_ index: Int) -> String { "story-block-\(index)" }

    /// The sentence's place in block `index`, when that block is being read.
    private func mark(_ block: FHBlock, index: Int) -> FHSpan? {
        guard index == active, !sentence.isEmpty else { return nil }
        return FamilyGeometry.sentenceSpan(sentence, in: block.plainText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { pair in
                block(pair.element, index: pair.offset)
                    .id(Self.blockId(pair.offset))
            }
        }
    }

    @ViewBuilder
    private func block(_ block: FHBlock, index: Int) -> some View {
        switch block.type ?? "p" {
        case "h2":
            FamilyHeading(text: block.plainText, level: .h2)
        case "h3":
            FamilyHeading(text: block.plainText, level: .h3)
        case "li":
            listItem(block, mark: mark(block, index: index))
                .modifier(FamilyReadingHighlight(on: index == active, contrast: highContrast))
        case "quote":
            FamilyStoryText.text(block, mark: mark(block, index: index))
                .italic()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                }
                .modifier(FamilyReadingHighlight(on: index == active, contrast: highContrast))
        default:
            FamilyStoryText.text(block, mark: mark(block, index: index))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(FamilyReadingHighlight(on: index == active, contrast: highContrast))
        }
    }

    private func listItem(_ block: FHBlock, mark: FHSpan?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: block.n.map { String($0) + "." } ?? "\u{2022}")
                .accessibilityHidden(block.n == nil)
            FamilyStoryText.text(block, mark: mark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The paragraph being read: a soft tint behind it and a bar at its edge.
struct FamilyReadingHighlight: ViewModifier {
    let on: Bool
    let contrast: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, on ? 8 : 0)
            .padding(.vertical, on ? 4 : 0)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(contrast ? 0.28 : 0.14))
                }
            }
            .overlay(alignment: .leading) {
                if on {
                    Rectangle().fill(Color.accentColor).frame(width: contrast ? 4 : 3)
                }
            }
    }
}

// MARK: - Sources

struct FamilyStorySources: View {
    let sources: [FHSourceNote]
    var focus: AccessibilityFocusState<String?>.Binding

    static func key(_ n: Int) -> String { "story-source-\(n)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: "Sources", level: .h2)
            ForEach(Array(sources.enumerated()), id: \.offset) { pair in
                row(pair.element, position: pair.offset + 1)
            }
        }
    }

    @ViewBuilder
    private func row(_ source: FHSourceNote, position: Int) -> some View {
        let n: Int = source.n ?? position
        let words: String = String(n) + ". " + (source.title ?? "A source")
        Group {
            if let url = source.url {
                Link(destination: url) {
                    Text(words)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHint("Opens it in Safari.")
            } else {
                Text(words)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(Self.key(n))
        .accessibilityFocused(focus, equals: Self.key(n))
    }
}

// MARK: - Listen

struct FamilyListenBar: View {
    @ObservedObject var player: FamilyStoryPlayer

    @AccessibilityFocusState private var retryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            captionStrip
            controls
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    /// The sentence being read, on a solid band (never over the text), two
    /// lines at most. For anyone watching; VoiceOver hears the voice.
    @ViewBuilder
    private var captionStrip: some View {
        if !player.caption.isEmpty {
            Text(player.caption)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.black)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if let problem = player.problem {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try again") { player.retry() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityFocused($retryFocused)
                    Button("Stop listening") { player.stop() }
                        .buttonStyle(.bordered)
                }
            }
            .task(id: problem) {
                FamilyAnnounce.say(problem)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return }
                retryFocused = true
            }
        } else {
            transport
        }
    }

    private var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                Button { player.back() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .accessibilityLabel("Back one part")
                .accessibilityInputLabels(["Back"])
                playButton
                Button { player.forward() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(player.part + 1 >= player.partCount)
                .accessibilityLabel("Forward one part")
                .accessibilityInputLabels(["Forward"])
                speedMenu
                Button { player.stop() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Stop listening")
                .accessibilityInputLabels(["Stop"])
            }
            .font(.title3)
            .buttonStyle(.borderless)
            Text(position)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if player.loading {
            ProgressView()
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Getting the voice ready")
        } else {
            Button { player.togglePlay() } label: {
                Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
            }
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            .accessibilityHint(player.playing ? "" : "Reads the story aloud.")
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: speedBinding) {
                ForEach(FamilyStoryPlayer.speeds, id: \.self) { value in
                    Text(Self.speedWords(value)).tag(value)
                }
            }
        } label: {
            Text(Self.speedShort(player.speed))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityLabel("Speed, " + Self.speedWords(player.speed))
        .accessibilityInputLabels(["Speed"])
    }

    private var speedBinding: Binding<Float> {
        Binding(get: { player.speed }, set: { (value: Float) in player.setSpeed(value) })
    }

    /// "Part 2 of 6".
    private var position: String {
        guard player.partCount > 0 else { return "" }
        return "Part \(player.part + 1) of \(player.partCount)"
    }

    /// "Normal", "1.25 times".
    static func speedWords(_ value: Float) -> String {
        value == 1 ? "Normal" : FHText.number(Double(value)) + " times"
    }

    /// "1.25x".
    static func speedShort(_ value: Float) -> String {
        FHText.number(Double(value)) + "x"
    }
}
