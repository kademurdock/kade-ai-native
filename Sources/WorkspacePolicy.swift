import Foundation

enum WorkspaceRetryPolicy {
    static func isDefinitiveRefusal(_ status: Int) -> Bool {
        [400, 404, 409, 422].contains(status)
    }
}

struct WorkspaceContinuationPolicy: Codable, Equatable {
    let account: String
    let projectId: String
    let runtime: String
    let model: String?
    let allowEdits: Bool

    func matches(account: String, projectId: String, runtime: String, model: String?) -> Bool {
        self.account == account && self.projectId == projectId && self.runtime == runtime && self.model == model
    }
}
