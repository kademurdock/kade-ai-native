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
                // Part 132 (Sep 5 2026), her ask from Part 131: what this
                // person has ACTUALLY cost the server since the 1st, beside
                // the balance -- the same line the web's Feed the Server
                // page carries. Charged / multiplier + metered extras.
                if let c = service.myCost {
                    Section {
                        row("What you actually cost the server", c.totalUSD, prominent: true)
                    } header: {
                        Text("Real cost this month")
                    } footer: {
                        Text(costFooter(c))
                    }
                }
                Section("All time") {
                    row("Total", u.allTime.totalUSD, prominent: true)
                }
                Section {
                    row("Balance", u.balanceUSD)
                    // APP STORE (July 31 2026, the submission build): the
                    // "Chip in" PayPal link is REMOVED from native, not
                    // gated -- an external payment link next to a digital
                    // balance is Guideline 3.1.1's single most common
                    // rejection, and the family tops up through Kade
                    // anyway. The WEB keeps its link (outside Apple's
                    // walls); if native ever needs one back, it goes
                    // through StoreKit External Purchase entitlements,
                    // not a plain Link.
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

    private func costFooter(_ c: UsageService.MyCost) -> String {
        var parts: [String] = []
        if let spoken = c.spoken, !spoken.isEmpty { parts.append(spoken) }
        if let m = c.multiplier, m != 1 {
            let mult = m.rounded() == m ? String(Int(m)) : String(format: "%.1f", m)
            parts.append("Balances are charged \(mult) times real model cost to help cover the rest of the platform.")
        }
        return parts.joined(separator: " ")
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
