import SwiftUI

/// Read-only Usage & Balance — the native counterpart of the web "You" hub's
/// Usage & Balance page, reachable from Settings > Account. Shows what this
/// account has spent this month and overall, the current balance, and a
/// plain link to the same PayPal page the web offers. Deliberately READ-ONLY:
/// no payment is ever initiated here; the one button just opens her own
/// chip-in page in the browser, exactly like the web page's link.
struct UsageView: View {
    let apiClient: KadeAPIClient

    @StateObject private var service: UsageService

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: UsageService(client: apiClient))
    }

    var body: some View {
        List {
            if let error = service.loadError, service.usage == nil {
                Section {
                    Text(error)
                    Button("Try again") { Task { await service.load() } }
                }
            } else if service.usage == nil {
                Section {
                    ProgressView("Loading your usage…")
                        .accessibilityLabel("Loading your usage")
                }
            }
            if let u = service.usage {
                Section {
                    row("Total", u.monthToDate.totalUSD, prominent: true)
                    row("Chat and thinking", u.monthToDate.llmUSD)
                    // July 21 2026, Kade's pick: voice is included free with
                    // her Inworld plan and no longer draws from balances --
                    // the dollar figure here will read $0.00 going forward
                    // (any nonzero remainder is history from before the
                    // switch), so the detail line carries the real story.
                    row("Voices read aloud", u.monthToDate.ttsUSD,
                        detail: quantity(u.monthToDate.tts_chars, "characters spoken").map {
                            $0 + " — included free with Kade's voice plan"
                        })
                    row("Pictures made", u.monthToDate.fluxUSD,
                        detail: quantity(u.monthToDate.flux_images, "images"))
                    row("Phone calls", u.monthToDate.phoneUSD,
                        detail: quantity(u.monthToDate.phone_minutes, "minutes"))
                    row("Everything else", u.monthToDate.otherUSD)
                } header: {
                    Text(u.monthLabel)
                } footer: {
                    Text("What this account has cost so far this month, by kind of thing.")
                }
                Section("All time") {
                    row("Total", u.allTime.totalUSD, prominent: true)
                }
                Section {
                    row("Balance", u.balanceUSD)
                    if let paypal = u.paypal, let url = URL(string: paypal) {
                        Link(destination: url) {
                            Label("Chip in (opens PayPal in your browser)", systemImage: "heart")
                        }
                        .accessibilityHint("Opens the chip-in page in your browser. Nothing is charged from inside this app.")
                    }
                } header: {
                    Text("Balance")
                }
            }
        }
        .navigationTitle("Usage & Balance")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await service.load() }
        .task { await service.load() }
    }

    private func row(_ label: String, _ usd: Double, detail: String? = nil, prominent: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(prominent ? .headline : .body)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Self.dollars(usd))
                .font(prominent ? .headline : .body)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label). \(Self.spokenDollars(usd))\(detail.map { ". \($0)" } ?? "")")
    }

    private func quantity(_ value: Double, _ unit: String) -> String? {
        guard value > 0 else { return nil }
        let whole = value.rounded() == value
        let number = whole ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(unit)"
    }

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// "one dollar and five cents" reads better than "dollar sign one point
    /// zero five" — VoiceOver handles "$1.05" fine these days, but spelling
    /// the label out keeps it deterministic across voices and verbosity
    /// settings.
    static func spokenDollars(_ value: Double) -> String {
        let cents = Int((value * 100).rounded())
        let d = cents / 100
        let c = cents % 100
        if c == 0 { return "\(d) dollar\(d == 1 ? "" : "s")" }
        return "\(d) dollar\(d == 1 ? "" : "s") and \(c) cent\(c == 1 ? "" : "s")"
    }
}
