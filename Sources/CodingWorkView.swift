import SwiftUI

private struct CodingSpending: Decodable {
    let limitUsd: Double
    let confirmedUsd: Double
    let reservedUsd: Double
    let complete: Bool
}

private struct CodingResult: Decodable {
    let summary: String?
    let answer: String?
    let spokenDiff: String?
    let spokenTrace: String?
    let branch: String?
    let baseSha: String?
    let spending: CodingSpending?
}

private struct CodingJob: Decodable, Identifiable {
    let runId: String
    let task: String?
    let state: String
    let error: String?
    let needsAttention: Bool?
    let result: CodingResult
    var id: String { runId }
    enum CodingKeys: String, CodingKey { case runId, task, state, error, needsAttention, result }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runId = try values.decode(String.self, forKey: .runId)
        task = try values.decodeIfPresent(String.self, forKey: .task)
        state = try values.decode(String.self, forKey: .state)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        needsAttention = try values.decodeIfPresent(Bool.self, forKey: .needsAttention)
        result = try values.decodeIfPresent(CodingResult.self, forKey: .result) ?? CodingResult(from: decoder)
    }
    var statusLabel: String {
        switch state {
        case "done": return "Checks passed"
        case "running": return "Working"
        case "interrupted": return "Interrupted"
        case "stopped": return "Stopped"
        case "failed": return "Checks failed"
        default: return "Could not finish"
        }
    }
}

private struct CodingPage: Decodable { let jobs: [CodingJob]; let hasMore: Bool }

struct CodingWorkView: View {
    let apiClient: KadeAPIClient
    var runId: String? = nil
    @State private var jobs: [CodingJob] = []
    @State private var hasMore = false
    @State private var loading = false
    @State private var blocked = false
    @State private var status = "Loading coding jobs…"
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(status).accessibilityAddTraits(.updatesFrequently)
                Button("Refresh coding jobs") { checkTask = Task { await load() } }
                    .disabled(loading || blocked)
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(job.task ?? "Coding job \(job.runId)").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(job.statusLabel).fontWeight(.semibold)
                        if job.needsAttention == true { Text("Waiting on you: review this result before continuing or publishing.") }
                        if let error = job.error { Text(error) }
                        if let summary = job.result.summary { Text(summary) }
                        if let spending = job.result.spending {
                            Text("Job ceiling: $\(spending.limitUsd, specifier: "%.2f"). Confirmed provider charges: $\(spending.confirmedUsd, specifier: "%.6f").")
                            if !spending.complete { Text("Cost is incomplete. Reserved pending reconciliation: $\(spending.reservedUsd, specifier: "%.6f").") }
                        } else { Text("Itemized costs are not available for this older job.") }
                        if let answer = job.result.answer { DisclosureGroup("Result") { Text(answer).textSelection(.enabled) } }
                        if let diff = job.result.spokenDiff { DisclosureGroup("Changes") { Text(diff).textSelection(.enabled) } }
                        if let trace = job.result.spokenTrace { DisclosureGroup("Actions performed") { Text(trace).textSelection(.enabled) } }
                        if let branch = job.result.branch { Text("Saved branch: \(branch)").textSelection(.enabled) }
                        if let base = job.result.baseSha { Text("Started from commit \(base)").textSelection(.enabled) }
                    }
                    .padding().background(.background, in: RoundedRectangle(cornerRadius: 14))
                }
                if hasMore { Button("Show older coding jobs") { checkTask = Task { await load(older: true) } }.disabled(loading || blocked) }
            }.padding().frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .navigationTitle("Coding jobs")
        .task(id: runId) { await load() }
        .onDisappear { checkTask?.cancel() }
    }

    @MainActor private func load(older: Bool = false) async {
        guard !loading && !blocked else { return }
        loading = true
        defer { loading = false }
        do {
            if let runId, runId.range(of: "^r[a-z0-9]{8,40}$", options: .regularExpression) == nil {
                status = "This job link is invalid."
                return
            }
            let path = "api/kade/harness/jobs" + (runId.map { "/" + $0 } ?? "")
            let request = apiClient.request(path: path, authorized: true,
                queryItems: runId == nil ? [URLQueryItem(name: "offset", value: String(older ? jobs.count : 0))] : [])
            let (data, response) = try await apiClient.send(request)
            try Task.checkCancellation()
            guard response.statusCode == 200 else {
                if response.statusCode == 403 { blocked = true }
                status = response.statusCode == 404 ? "No saved record for this exact job. Nothing was sent again."
                    : response.statusCode == 401 ? "Please sign in again to check your coding jobs."
                    : "Could not check coding jobs. Your previous results are still here."
                return
            }
            let decoder = JSONDecoder()
            if let runId {
                let job = try decoder.decode(CodingJob.self, from: data)
                guard job.runId == runId else { status = "The job identifier did not match."; return }
                jobs = [job]; hasMore = false
            } else {
                let page = try decoder.decode(CodingPage.self, from: data)
                jobs = older ? jobs + page.jobs : page.jobs
                hasMore = page.hasMore
            }
            status = "\(jobs.count) coding jobs shown."
        } catch is CancellationError {
        } catch { status = "Connection lost. Your previous results are still here. Try Refresh." }
    }
}
