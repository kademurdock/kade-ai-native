import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

for status in [401, 403, 408, 429, 500, 503] {
    require(!WorkspaceRetryPolicy.isDefinitiveRefusal(status), "An uncertain/auth/rate response discarded the pending request identity")
}
for status in [400, 404, 409, 422] {
    require(WorkspaceRetryPolicy.isDefinitiveRefusal(status), "A definitive refusal could not be corrected")
}
let edit = WorkspaceContinuationPolicy(account: "alice", projectId: "folder", runtime: "codex", model: nil, allowEdits: true)
let encoded = try JSONEncoder().encode(edit)
let restored = try JSONDecoder().decode(WorkspaceContinuationPolicy.self, from: encoded)
require(restored.allowEdits, "Edit permission was lost after a journal round trip")
require(restored.matches(account: "alice", projectId: "folder", runtime: "codex", model: nil), "The original conversation cannot continue")
require(!restored.matches(account: "bob", projectId: "folder", runtime: "codex", model: nil), "Policy leaked across accounts")
require(!restored.matches(account: "alice", projectId: "other-folder", runtime: "codex", model: nil), "Policy leaked across folders")
require(!restored.matches(account: "alice", projectId: "folder", runtime: "claude", model: nil), "Policy crossed runtimes")
require(!restored.matches(account: "alice", projectId: "folder", runtime: "codex", model: "different"), "Policy crossed requested models")
print("Workspace retry and continuation policy checks passed.")
