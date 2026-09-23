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
        print("Push registration tests passed: sign-out, account switch, ordering, and deduplication")
    }
}
