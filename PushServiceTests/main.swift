import Foundation

@main struct PushTests {
    @MainActor static func main() async {
        var requests: [URLRequest] = []
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let service = PushService { request in
            requests.append(request)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func body(_ index: Int) -> [String: Any] {
            try! JSONSerialization.jsonObject(with: requests[index].httpBody!) as! [String: Any]
        }
        func complete() {
            let continuation = pending!
            pending = nil
            continuation.resume(returning: (Data(), HTTPURLResponse(url: requests.last!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        }
        func waitFor(_ count: Int) async {
            for _ in 0..<10000 {
                if requests.count == count && pending != nil { return }
                await Task.yield()
            }
            fatalError("Expected \(count) requests, got \(requests.count)")
        }
        service.setUserId("first-account")
        service.setDeviceToken(Data([1,2,3]))
        await waitFor(1)
        service.setUserId(nil)
        await Task.yield()
        precondition(requests.count == 1, "Registration requests must be serialized")
        complete()
        await waitFor(2)
        precondition(body(0)["userId"] as? String == "first-account")
        precondition(body(1)["userId"] is NSNull, "Sign-out must explicitly clear the server link")
        service.setUserId("second-account")
        complete()
        await waitFor(3)
        precondition(body(2)["userId"] as? String == "second-account")
        complete()
        for _ in 0..<100 { await Task.yield() }
        service.refreshRegistration()
        for _ in 0..<100 { await Task.yield() }
        precondition(requests.count == 3, "Acknowledged state must not be sent again")
        precondition(requests[0].value(forHTTPHeaderField: "Authorization") == nil,
                     "No bearer reader means no Authorization header")

        // IOS-19 (Nov 12 2026 audit): a link carries the signed-in user's
        // bearer; a sign-out never does.
        var proofRequests: [URLRequest] = []
        let proven = PushService(send: { request in
            proofRequests.append(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, bearer: { "tok" })
        func waitForProof(_ count: Int) async {
            for _ in 0..<10000 {
                if proofRequests.count == count { return }
                await Task.yield()
            }
            fatalError("Expected \(count) proof requests, got \(proofRequests.count)")
        }
        proven.setUserId("linked-account")
        proven.setDeviceToken(Data([4,5,6]))
        await waitForProof(1)
        for _ in 0..<100 { await Task.yield() }
        precondition(proofRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok",
                     "A link must carry the signed-in user's bearer")
        proven.setUserId(nil)
        await waitForProof(2)
        let signOutBody = try! JSONSerialization.jsonObject(with: proofRequests[1].httpBody!) as! [String: Any]
        precondition(signOutBody["userId"] is NSNull, "Sign-out must explicitly clear the server link")
        precondition(proofRequests[1].value(forHTTPHeaderField: "Authorization") == nil,
                     "Sign-out must not send a bearer")
        print("Push registration tests passed: sign-out, account switch, ordering, deduplication, and link proof")
    }
}
