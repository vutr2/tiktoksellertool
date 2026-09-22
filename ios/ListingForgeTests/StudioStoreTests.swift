// Cost safety: cached/partially completed image batches must not resubmit
// their saved variations, and a failure must stop the remaining paid calls.
import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Studio image cost and retry safety")
struct StudioStoreTests {
    private func image(_ index: Int) -> String {
        """
        {"sceneId":"marble_podium","index":\(index),"assetId":"asset-\(index)","url":"https://example.invalid/\(index).png"}
        """
    }

    private func catalog(_ indices: [Int] = []) -> StubResponse {
        .json("""
        {"creditsPerImage":5,"catalog":{},"images":[\(indices.map(image).joined(separator: ","))]}
        """)
    }

    private func generated(_ index: Int) -> StubResponse {
        .json("""
        {"images":[\(image(index))],"creditsCharged":5,"balanceAfter":\(100 - (index + 1) * 5)}
        """)
    }

    private func generate(_ store: StudioStore) async {
        await store.generate(industry: .beauty, sceneID: "marble_podium", count: 3, token: "test-token")
    }

    @Test("Each paid variation has its own 200-second request and uses the server balance")
    func oneImagePerRequest() async throws {
        let server = StubbedServer(catalog(), generated(0), generated(1), generated(2))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)

        let posts = server.requests.filter { $0.method == "POST" }
        #expect(posts.count == 3)
        for (index, request) in posts.enumerated() {
            let body = try #require(request.jsonObject)
            #expect(body["index"] as? Int == index)
            #expect(body["count"] as? Int == 1)
            #expect(request.timeoutInterval == 200)
        }
        #expect(server.requests.first?.timeoutInterval == 60)
        #expect(store.results.map(\.index) == [0, 1, 2])
        #expect(store.balanceAfter == 85)
        #expect(store.errorMessage == nil)
        #expect(!store.isGenerating)
    }

    @Test("A fully cached batch makes no paid generation calls")
    func cachedBatch() async {
        let server = StubbedServer(catalog([0, 1, 2]))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.method == "GET")
        #expect(store.uncachedCount(sceneID: "marble_podium", count: 3) == 0)
        #expect(store.uncachedCount(sceneID: "different-style", count: 3) == 3)
    }

    @Test("Retry recovers an image saved after the timed-out response, without submitting it again")
    func recoverPartialBatch() async {
        let server = StubbedServer(
            catalog(), generated(0), .transportFailure(URLError(.timedOut)),
            catalog([0, 1]), generated(2))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)
        #expect(store.results.map(\.index) == [0])
        #expect(store.errorMessage?.contains("200 seconds") == true)
        #expect(store.balanceAfter == 95)

        await generate(store)
        let indices = server.requests.filter { $0.method == "POST" }.compactMap { $0.jsonObject?["index"] as? Int }
        #expect(indices == [0, 1, 2], "Neither the cached image nor the lost response should be generated twice")
        #expect(store.results.map(\.index) == [0, 1, 2])
        #expect(store.errorMessage == nil)
    }

    @Test("An insufficient balance stops remaining paid submissions and preserves earlier output")
    func insufficientBalance() async {
        let server = StubbedServer(catalog(), generated(0), .json(#"{"error":"Not enough credits."}"#, status: 402))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)
        #expect(server.requests.filter { $0.method == "POST" }.count == 2)
        #expect(store.results.map(\.index) == [0])
        #expect(store.errorMessage == "Not enough credits.")
        #expect(!store.isGenerating)
    }

    @Test("If the durable cache cannot be checked, do not risk new paid calls")
    func cacheUnavailable() async {
        let server = StubbedServer(.json(#"{"error":"Unavailable"}"#, status: 503))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)
        #expect(server.requests.count == 1)
        #expect(store.errorMessage == "Unavailable")
    }

    @Test("An older server that ignores the variation index cannot silently repeat a paid batch")
    func oldServer() async {
        let server = StubbedServer(catalog(), generated(0), generated(0))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)
        #expect(server.requests.filter { $0.method == "POST" }.count == 2)
        #expect(store.results.map(\.index) == [0])
        #expect(store.errorMessage?.contains("server needs to be updated") == true)
    }

    @Test("Closing the screen cancels remaining paid submissions without displaying a failure")
    func cancelBatch() async {
        let server = StubbedServer(catalog(), .transportFailure(URLError(.cancelled)))
        let store = StudioStore(api: server.client, productID: "product")
        await generate(store)
        #expect(server.requests.filter { $0.method == "POST" }.count == 1)
        #expect(store.errorMessage == nil)
        #expect(!store.isGenerating)
    }

    @Test("Relaunch restores paid output, then checks the server before generating only missing variations")
    func relaunchPartialBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstServer = StubbedServer(catalog(), generated(0), .transportFailure(URLError(.timedOut)))
        let first = StudioStore(api: firstServer.client, productID: "product", cacheDirectory: directory)
        await generate(first)
        first.invalidate()

        let secondServer = StubbedServer(catalog([0, 1]), generated(2))
        let relaunched = StudioStore(api: secondServer.client, productID: "product", cacheDirectory: directory)
        #expect(relaunched.results.map(\.index) == [0])
        #expect(secondServer.requests.isEmpty, "Restoring local state cannot start paid work")
        await generate(relaunched)
        #expect(secondServer.requests.map(\.method) == ["GET", "POST"])
        #expect(secondServer.lastRequest?.jsonObject?["index"] as? Int == 2)
        #expect(relaunched.results.map(\.index) == [0, 1, 2])
    }

    @Test("An expired preview URL cannot make a saved paid image eligible for generation again")
    func unavailablePreviewIsStillSaved() async {
        let saved = StubResponse.json(#"{"creditsPerImage":5,"catalog":{},"images":[{"sceneId":"marble_podium","index":0,"assetId":"saved","url":null}]}"#)
        let server = StubbedServer(saved, saved)
        let store = StudioStore(api: server.client, productID: "product")
        await store.load(token: "jwt")
        #expect(store.results.count == 1)
        #expect(store.uncachedCount(sceneID: "marble_podium", count: 1) == 0)
        await store.generate(industry: .beauty, sceneID: "marble_podium", count: 1, token: "jwt")
        #expect(server.requests.map(\.method) == ["GET", "GET"])
    }

    @Test("Switching accounts invalidates Studio and stops subsequent paid requests")
    func invalidatedAccount() async {
        let server = StubbedServer(catalog(), generated(0))
        let store = StudioStore(api: server.client, productID: "product")
        store.invalidate()
        await store.load(token: "old-account")
        await generate(store)
        #expect(server.requests.isEmpty)
        #expect(store.results.isEmpty)
    }

    @Test("A saved paid photo opens after relaunch without its expiring URL, isolated from other accounts")
    func offlinePhoto() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("saved-provider-image".utf8)
        let server = StubbedServer(StubResponse(body: bytes, headers: ["Content-Type": "image/png"]))
        let first = StudioStore(api: server.client, productID: "p1", cacheDirectory: directory, imageSession: server.session)
        let photo = StudioImage(sceneId: "marble_podium", index: 0, assetId: "paid-photo",
            url: server.baseURL.appendingPathComponent("photo.png").absoluteString)
        #expect(try await first.imageData(for: photo) == bytes)
        let withoutURL = StudioImage(sceneId: photo.sceneId, index: 0, assetId: photo.assetId, url: nil)
        let relaunched = StudioStore(api: server.client, productID: "p1", cacheDirectory: directory, imageSession: server.session)
        #expect(try await relaunched.imageData(for: withoutURL) == bytes)
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.method == "GET")
        let differentAccount = StudioStore(api: server.client, productID: "p1",
            cacheDirectory: directory.appendingPathComponent("other-account"), imageSession: server.session)
        await #expect(throws: (any Error).self) { try await differentAccount.imageData(for: withoutURL) }
        relaunched.invalidate()
        await #expect(throws: (any Error).self) { try await relaunched.imageData(for: withoutURL) }
    }
}
