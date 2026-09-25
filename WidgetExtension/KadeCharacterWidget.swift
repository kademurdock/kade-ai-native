import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Sep 23 2026 redesign (C2): "Talk to your character"
//
// A home-screen and Lock Screen widget: the character's face, a different
// expression by time of day, and a way to start talking. The face is always
// decoration (hidden from VoiceOver); the words beside it say who it is.
//
// The widget can't see the app's data: the extension has no App Group, on
// purpose (see project.yml). So the character is picked in the widget's own
// settings (touch and hold, Edit Widget), and every tap is a kadeai:// link
// the app routes (see KadeWidgetLinks).

/// The four characters with drawn faces. Their images are cut from the app's
/// face sheets into WidgetExtension/Assets.xcassets as <Name><Expression>.
enum CharacterChoice: String, AppEnum {
    case kiana, harley, della, lilly

    static var typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Character")
    static var caseDisplayRepresentations: [CharacterChoice: DisplayRepresentation] = [
        .kiana: DisplayRepresentation(title: "Kiana"),
        .harley: DisplayRepresentation(title: "Harley"),
        .della: DisplayRepresentation(title: "Della"),
        .lilly: DisplayRepresentation(title: "Lilly")
    ]

    var name: String {
        switch self {
        case .kiana: return "Kiana"
        case .harley: return "Harley"
        case .della: return "Della"
        case .lilly: return "Lilly"
        }
    }

    /// The same ids as `CharacterMotion.kianaID` and friends in the app. That
    /// file isn't compiled into this extension, so they are spelled out here.
    var agentID: String {
        switch self {
        case .kiana: return "agent_6llV0eMu4fmIaj8f2x1Sb"
        case .harley: return "agent_d26Mtu8mgOzkVGQECqO1a"
        case .della: return "agent_BSOLa3eNEZyjs-7abCjMt"
        // Sep 25 2026: the public Lilly (Skylee's own stays private to her).
        case .lilly: return "agent_TOdYS8v-bRxeNw0dia_Md"
        }
    }

    var talkURL: URL { KadeWidgetLinks.talk(agentID: agentID) }
}

/// The widget's one setting.
struct KadeCharacterWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a character"
    static var description = IntentDescription("Pick whose face the widget shows, and who you talk to when you tap it.")

    @Parameter(title: "Character", default: .kiana)
    var character: CharacterChoice
}

/// The face follows the clock: a smile in the morning, playful in the
/// afternoon, tender in the evening, tired late at night.
enum KadeDayPart: CaseIterable {
    case morning, afternoon, evening, lateNight

    /// The local hour (0-23) each part begins.
    var startHour: Int {
        switch self {
        case .morning: return 5
        case .afternoon: return 12
        case .evening: return 17
        case .lateNight: return 22
        }
    }

    /// The second half of the image set's name ("KianaSmile").
    var expression: String {
        switch self {
        case .morning: return "Smile"
        case .afternoon: return "Playful"
        case .evening: return "Tender"
        case .lateNight: return "Tired"
        }
    }

    static func at(_ date: Date, calendar: Calendar) -> KadeDayPart {
        let hour = calendar.component(.hour, from: date)
        if hour >= 22 || hour < 5 { return .lateNight }
        if hour >= 17 { return .evening }
        if hour >= 12 { return .afternoon }
        return .morning
    }
}

struct KadeCharacterEntry: TimelineEntry {
    let date: Date
    let character: CharacterChoice
    let dayPart: KadeDayPart

    /// "KianaSmile": an image set in WidgetExtension/Assets.xcassets.
    var faceAsset: String { character.name + dayPart.expression }
}

/// Nothing to fetch: the entry now, then one at each of the next four
/// time-of-day boundaries (a whole day's turn of faces). `.atEnd` asks for
/// the next day's timeline after the last one.
struct KadeCharacterProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> KadeCharacterEntry {
        let now = Date()
        return KadeCharacterEntry(date: now, character: .kiana, dayPart: KadeDayPart.at(now, calendar: Calendar.current))
    }

    func snapshot(for configuration: KadeCharacterWidgetIntent, in context: Context) async -> KadeCharacterEntry {
        let now = Date()
        return KadeCharacterEntry(date: now, character: configuration.character, dayPart: KadeDayPart.at(now, calendar: Calendar.current))
    }

    func timeline(for configuration: KadeCharacterWidgetIntent, in context: Context) async -> Timeline<KadeCharacterEntry> {
        let now = Date()
        let calendar = Calendar.current
        var entries = [KadeCharacterEntry(date: now, character: configuration.character, dayPart: KadeDayPart.at(now, calendar: calendar))]
        let boundaries = KadeDayPart.allCases
            .compactMap { part in
                calendar.nextDate(
                    after: now,
                    matching: DateComponents(hour: part.startHour, minute: 0, second: 0),
                    matchingPolicy: .nextTime
                )
            }
            .sorted()
        for boundary in boundaries {
            entries.append(KadeCharacterEntry(date: boundary, character: configuration.character, dayPart: KadeDayPart.at(boundary, calendar: calendar)))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

struct KadeCharacterWidget: Widget {
    let kind: String = "KadeCharacterWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: KadeCharacterWidgetIntent.self, provider: KadeCharacterProvider()) { entry in
            KadeCharacterWidgetView(entry: entry)
        }
        .configurationDisplayName("Talk to your character")
        .description("Your character's face, changing with the time of day. Tap to start talking.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        // The small widget's face runs edge to edge; everything else pads
        // itself with the system's own margins (`widgetContentMargins`).
        .contentMarginsDisabled()
    }
}

struct KadeCharacterWidgetView: View {
    let entry: KadeCharacterEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var name: String { entry.character.name }

    /// Increase Contrast or Reduce Transparency: the see-through scrim under
    /// the name turns into a solid band, and the outline gets heavier.
    private var solid: Bool { contrast == .increased || reduceTransparency }

    /// Tinted and clear home screens (iOS 18 and later). There the system
    /// paints every opaque shape and all text in one white, keeping only
    /// opacity, and drops the container background. Brown text on an amber
    /// pill would turn into white on white, and the brown scrim into a white
    /// fade behind white text, so in this mode pills are outlines and the
    /// scrim goes away.
    private var accented: Bool { renderingMode == .accented }

    var body: some View {
        content
            .widgetURL(entry.character.talkURL)
            .containerBackground(for: .widget) {
                containerFill
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .systemMedium:
            medium
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        default:
            small
        }
    }

    /// The icon's brown-into-amber on the home screen; nothing on the Lock
    /// Screen, where accessory widgets sit straight on the wallpaper.
    @ViewBuilder private var containerFill: some View {
        switch family {
        case .systemSmall, .systemMedium:
            KadeWidgetPalette.background
        default:
            Color.clear
        }
    }

    /// Decorative, like every face in the app. On a tinted or clear home
    /// screen the system tints an opaque image "with a single white color"
    /// (Apple's words), which would flatten the face into a blank square, so
    /// there it is drawn by its brightness in the person's tint instead.
    @ViewBuilder private var face: some View {
        if #available(iOS 18.0, *) {
            Image(entry.faceAsset)
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            Image(entry.faceAsset)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        }
    }

    /// The brown fade that keeps cream text readable over any part of a face
    /// (7.7:1 at the text even over pure white). Solid under Increase Contrast.
    @ViewBuilder private var scrim: some View {
        if accented {
            Color.clear
        } else if solid {
            KadeWidgetPalette.brown
        } else {
            LinearGradient(
                gradient: Gradient(stops: [
                    Gradient.Stop(color: KadeWidgetPalette.brown.opacity(0), location: 0),
                    Gradient.Stop(color: KadeWidgetPalette.brown.opacity(0.8), location: 0.45),
                    Gradient.Stop(color: KadeWidgetPalette.brown.opacity(0.95), location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: systemSmall: the face fills it; the name and "Talk" sit at the foot.

    /// One element for VoiceOver: "Kiana. Talk to Kiana". Nothing inside is a
    /// control (a small widget is one tap, its `widgetURL`), so flattening it
    /// is safe under the Amber rule.
    private var small: some View {
        ZStack(alignment: .bottom) {
            face
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            HStack(alignment: .center, spacing: 6) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(KadeWidgetPalette.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("Talk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accented ? Color.white : KadeWidgetPalette.brown)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background {
                        pillFill(Capsule(), primary: true)
                    }
            }
            .padding(.leading, margins.leading)
            .padding(.trailing, margins.trailing)
            .padding(.bottom, margins.bottom)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
            .background {
                scrim.accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name). Talk to \(name)")
    }

    // MARK: systemMedium: the face with its name tag, then two links.

    /// VoiceOver hears "Kiana", then "Talk to Kiana, link", then "Continue
    /// listening, link". The links are siblings with their own labels, never
    /// folded into a combined element (the Amber rule).
    private var medium: some View {
        GeometryReader { proxy in
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    face
                        .frame(width: proxy.size.height, height: proxy.size.height)
                        .clipped()
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(KadeWidgetPalette.cream)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            scrim.accessibilityHidden(true)
                        }
                }
                .frame(width: proxy.size.height, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 8) {
                    Link(destination: entry.character.talkURL) {
                        pill(title: "Talk to \(name)", symbol: "bubble.left.and.bubble.right.fill", primary: true)
                    }
                    .accessibilityLabel("Talk to \(name)")
                    Link(destination: KadeWidgetLinks.continueListening) {
                        pill(title: "Continue listening", symbol: "headphones", primary: false)
                    }
                    .accessibilityLabel("Continue listening")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(margins)
    }

    /// Each link is a tall block (over 44 points on every iPhone) with a
    /// solid fill: brown on the glow for Talk, cream on brown for the other.
    private func pill(title: String, symbol: String, primary: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(accented ? Color.white : (primary ? KadeWidgetPalette.brown : KadeWidgetPalette.cream))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            pillFill(RoundedRectangle(cornerRadius: 14, style: .continuous), primary: primary)
        }
    }

    /// A pill's backing: the glow for the main action, brown with a cream
    /// edge for the other, and a plain white outline on tinted and clear home
    /// screens, where any fill would swallow the words on it (see `accented`).
    @ViewBuilder private func pillFill<S: InsettableShape>(_ shape: S, primary: Bool) -> some View {
        if accented {
            shape.strokeBorder(Color.white, lineWidth: 1.5)
        } else if primary {
            shape.fill(KadeWidgetPalette.glow)
        } else {
            shape.fill(KadeWidgetPalette.brown)
                .overlay {
                    shape.strokeBorder(KadeWidgetPalette.cream.opacity(solid ? 0.9 : 0.55), lineWidth: solid ? 1.5 : 1)
                }
        }
    }

    // MARK: Lock Screen

    /// The face in a circle. It would say nothing on its own, so the circle
    /// carries the words: "Talk to Kiana".
    private var circular: some View {
        ZStack {
            face
        }
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk to \(name)")
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            face
                .frame(width: 42, height: 42)
                .clipShape(Circle())
            Text("Talk to \(name)")
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talk to \(name)")
    }
}
