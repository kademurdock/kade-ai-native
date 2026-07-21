import Foundation

/// GET /api/kade/my-usage — the signed-in user's own spend + balance.
/// Shape captured from a REAL live response July 21 2026 (not guessed):
/// { user:{name,email}, balanceUSD, monthToDate:{...}, allTime:{...},
///   suggestedDonationUSD, monthLabel, paypal }
/// Quantities are sent as numbers that can be fractional (phone_minutes
/// came back 11.6), so every quantity decodes as Double on purpose.
@MainActor
final class UsageService: ObservableObject {
    struct Bucket: Decodable {
        let llmUSD: Double
        let ttsUSD: Double
        let fluxUSD: Double
        let tavilyUSD: Double
        let phoneUSD: Double
        let otherUSD: Double
        let tts_chars: Double
        let flux_images: Double
        let tavily_searches: Double
        let phone_minutes: Double
        let totalUSD: Double
    }

    struct MyUsage: Decodable {
        struct User: Decodable {
            let name: String?
            let email: String?
        }
        let user: User?
        let balanceUSD: Double
        let monthToDate: Bucket
        let allTime: Bucket
        let suggestedDonationUSD: Double
        let monthLabel: String
        let paypal: String?
    }

    @Published private(set) var usage: MyUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let client: KadeAPIClient

    init(client: KadeAPIClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            var req = client.request(path: "api/kade/my-usage", method: "GET", authorized: true)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, http) = try await client.send(req)
            guard http.statusCode == 200 else {
                loadError = "Couldn't load your usage right now. Pull to try again."
                return
            }
            usage = try JSONDecoder().decode(MyUsage.self, from: data)
        } catch {
            loadError = "Couldn't load your usage right now. Pull to try again."
        }
    }
}
