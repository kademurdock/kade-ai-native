import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Sep 23 2026 redesign (C3): lock-screen progress for long jobs
//
// Draws the cards the app starts with `KadeJobActivity` (Sources/
// KadeJobActivity.swift). The contract between the two processes is
// Sources/KadeJobActivityAttributes.swift, compiled into both targets.
//
// VoiceOver reads Live Activities on the Lock Screen and in the Dynamic
// Island, so each shape carries one plain-words label ("Your song: Porch
// Light. Recording the song. 40 percent. Started at 3:42 PM.") instead of a
// symbol name and a progress bar read out piece by piece. Nothing here is a
// control; the whole card is one tap (kadeai://jobs), so flattening it is
// safe (the Amber rule).

/// What one card says, worked out once so the Lock Screen and every Dynamic
/// Island shape agree.
struct KadeJobSummary {
    let kind: String
    let title: String
    let startedAt: Date
    let status: String
    let progress: Double?
    let finished: Bool
    let failed: Bool
    let isStale: Bool

    init(_ context: ActivityViewContext<KadeJobActivityAttributes>) {
        kind = context.attributes.kind
        title = context.attributes.title
        startedAt = context.attributes.startedAt
        status = context.state.status
        progress = context.state.progress
        finished = context.state.finished
        failed = context.state.failed
        isStale = context.isStale
    }

    /// `KadeJobActivity` refreshes the stale date on every update, so a card
    /// that goes stale has not heard from the app for an hour.
    static let staleNote = "No news for a while. Open Kade-AI to check."

    /// Still working and still being heard from: the only time the clock runs.
    /// (A failed job is not `finished` in the state, but it has stopped.)
    var isRunning: Bool { !finished && !failed && !isStale }

    var isOver: Bool { finished || failed }

    /// 0...1, clamped, for the bar.
    var fraction: Double? {
        guard let progress else { return nil }
        return min(max(progress, 0), 1)
    }

    /// 0-100 while the job knows how far along it is and hasn't failed.
    var percent: Int? {
        guard let fraction, !failed else { return nil }
        return Int((fraction * 100).rounded())
    }

    var symbol: String {
        if failed { return "exclamationmark.triangle.fill" }
        if finished { return "checkmark.circle.fill" }
        switch kind {
        case "song": return "music.note"
        case "scene": return "theatermasks"
        case "sound": return "waveform"
        case "upload": return "arrow.up.circle"
        default: return "hourglass"
        }
    }

    /// Glow while working, green when ready, red when it failed. All three
    /// clear 6.8:1 on the card's brown.
    var tint: Color {
        if failed { return KadeWidgetPalette.failed }
        if finished { return KadeWidgetPalette.ready }
        return KadeWidgetPalette.glow
    }

    /// The whole card in plain words.
    var spokenSummary: String {
        [Self.sentence(title), spokenStatus]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The same without the title, for the Dynamic Island's bottom row, where
    /// the title is its own element just above.
    var spokenStatus: String {
        var parts: [String] = []
        if failed && !status.lowercased().hasPrefix("fail") {
            parts.append("Failed.")
        }
        parts.append(Self.sentence(status))
        if let percent, !finished {
            parts.append("\(percent) percent.")
        }
        if isRunning {
            // The visible clock ticks; the spoken words can't, so they say
            // when it started instead ("Started at 3:42 PM.").
            parts.append("Started at \(startedAt.formatted(date: .omitted, time: .shortened)).")
        }
        if isStale && !isOver {
            parts.append(Self.staleNote)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}

struct KadeJobLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KadeJobActivityAttributes.self) { context in
            KadeJobLockScreenView(job: KadeJobSummary(context))
                .activityBackgroundTint(KadeWidgetPalette.brown)
                .activitySystemActionForegroundColor(KadeWidgetPalette.cream)
                .widgetURL(KadeWidgetLinks.jobs)
        } dynamicIsland: { context in
            KadeJobLiveActivity.island(KadeJobSummary(context))
        }
    }

    static func island(_ job: KadeJobSummary) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                Image(systemName: job.symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(job.tint)
                    .accessibilityHidden(true)
            }
            DynamicIslandExpandedRegion(.trailing) {
                KadeJobShortStatus(job: job)
                    .accessibilityHidden(true)
            }
            DynamicIslandExpandedRegion(.center) {
                Text(job.title)
                    .font(.headline)
                    .foregroundStyle(KadeWidgetPalette.cream)
                    .lineLimit(1)
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.status)
                        .font(job.isOver ? Font.subheadline.weight(.semibold) : Font.subheadline)
                        .foregroundStyle(job.isOver ? job.tint : KadeWidgetPalette.cream)
                        .lineLimit(2)
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                            .tint(job.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(job.spokenStatus)
            }
        } compactLeading: {
            Image(systemName: job.symbol)
                .foregroundStyle(job.tint)
                .accessibilityLabel(job.spokenSummary)
        } compactTrailing: {
            // The leading symbol already speaks for the whole island.
            KadeJobShortStatus(job: job)
                .accessibilityHidden(true)
        } minimal: {
            Image(systemName: job.symbol)
                .foregroundStyle(job.tint)
                .accessibilityLabel(job.spokenSummary)
        }
        .widgetURL(KadeWidgetLinks.jobs)
        .keylineTint(job.tint)
    }
}

/// The Lock Screen card: symbol, title, status, bar and the time so far.
/// Ready turns the symbol into a green check and the status green and bold;
/// Failed turns them into a red warning. Neither shows the clock.
struct KadeJobLockScreenView: View {
    let job: KadeJobSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(job.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title)
                    .font(.headline)
                    .foregroundStyle(KadeWidgetPalette.cream)
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.status)
                        .font(job.isOver ? Font.subheadline.weight(.semibold) : Font.subheadline)
                        .foregroundStyle(job.isOver ? job.tint : KadeWidgetPalette.cream)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if job.isRunning {
                        // Counts up from the start. A timer Text takes all the
                        // width it is offered, so it is capped and right-aligned.
                        Text(timerInterval: job.startedAt...Date.distantFuture, countsDown: false)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(KadeWidgetPalette.cream)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 88, alignment: .trailing)
                    }
                }
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                        .tint(job.tint)
                }
                if job.isStale && !job.isOver {
                    Text(KadeJobSummary.staleNote)
                        .font(.footnote)
                        .foregroundStyle(KadeWidgetPalette.cream)
                }
            }
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(job.spokenSummary)
    }
}

/// The Dynamic Island's short word: a percent, a running clock, or a mark.
struct KadeJobShortStatus: View {
    let job: KadeJobSummary

    var body: some View {
        if job.isOver {
            Image(systemName: job.symbol)
                .foregroundStyle(job.tint)
        } else if let percent = job.percent {
            Text(verbatim: "\(percent)%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(job.tint)
        } else if job.isStale {
            Image(systemName: "ellipsis")
                .foregroundStyle(job.tint)
        } else {
            Text(timerInterval: job.startedAt...Date.distantFuture, countsDown: false, showsHours: false)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .foregroundStyle(job.tint)
        }
    }
}
