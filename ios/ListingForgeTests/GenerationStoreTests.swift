//
//  GenerationStoreTests.swift
//  ListingForgeTests
//
//  Credit arithmetic belongs to the server; these pin that the app displays what
//  it is told and never computes entitlement itself (SPEC §12).
//

import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Generation store")
struct GenerationStoreTests {

    /// The shape the live endpoint returned in a real run.
    private let generated = """
    {"productId":"p1",
     "facts":{"suggestedName":"Ceramic dripper","suggestedCategory":"Coffee",
              "material":null,"colour":null,"keyFeatures":[],"visibleText":[]},
     "assets":[
       {"type":"title","marketplace":"amazon","content":"A title","status":"pass","violations":[]},
       {"type":"description","marketplace":"amazon","content":"Bullets","status":"warn",
        "violations":[{"code":"title.promo_language","severity":"warn","field":"title.forbid",
                       "message":"Amazon does not allow promotional wording in a title.","detail":null}]},
       {"type":"title","marketplace":"tiktok_shop","content":"Another","status":"pass","violations":[]}
     ],
     "failures":[],
     "creditsCharged":6,"balanceAfter":394}
    """

    @Test("A quote is fetched from the server, never computed on the device")
    func quoteComesFromServer() async throws {
        let server = StubbedServer(.json(#"{"credits":6}"#))
        let store = GenerationStore(api: server.client)

        await store.quote(productID: "p1", marketplaces: ["amazon", "tiktok_shop"],
                          scriptCount: 1, token: "jwt")

        #expect(store.quotedCredits == 6)
        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/products/p1/generate")
        #expect(request.url?.query?.contains("marketplaces=amazon,tiktok_shop") == true)
        #expect(request.url?.query?.contains("scriptCount=1") == true)
    }

    @Test("Selecting nothing costs nothing, without asking the server")
    func emptySelectionQuotesZero() async {
        let server = StubbedServer(.json(#"{"credits":99}"#))
        let store = GenerationStore(api: server.client)

        await store.quote(productID: "p1", marketplaces: [], scriptCount: 0, token: "jwt")

        #expect(store.quotedCredits == 0)
        #expect(server.requests.isEmpty)
    }

    @Test("Generating posts the selection and records what the server charged")
    func generateSendsSelection() async throws {
        let server = StubbedServer(.json(generated))
        let store = GenerationStore(api: server.client)

        await store.generate(productID: "p1", marketplaces: ["amazon", "tiktok_shop"],
                             scriptCount: 1, token: "jwt")

        #expect(store.result?.creditsCharged == 6)
        // The balance shown comes from the server's own accounting.
        #expect(store.balance == 394)
        #expect(store.errorMessage == nil)
        #expect(!store.isGenerating)

        let body = try #require(server.lastRequest?.jsonObject)
        #expect(body["marketplaces"] as? [String] == ["amazon", "tiktok_shop"])
        #expect(body["scriptCount"] as? Int == 1)
        #expect(server.lastRequest?.header("Authorization") == "Bearer jwt")
    }

    @Test("A 402 means show the paywall, not an error message")
    func insufficientCreditsIsNotAnError() async {
        // SPEC §6: "a Starter user tapping Amazon sees the paywall sheet, not an error."
        let server = StubbedServer(
            .json(#"{"error":"This needs 6 credits and you have 0.","required":6,"available":0}"#, status: 402))
        let store = GenerationStore(api: server.client)

        await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")

        #expect(store.needsMoreCredits)
        #expect(store.errorMessage == "This needs 6 credits and you have 0.")
        #expect(store.result == nil)
    }

    @Test("Any other failure is an ordinary error, not a paywall")
    func otherFailuresAreNotPaywalls() async {
        let server = StubbedServer(.json(#"{"error":"Generation failed."}"#, status: 500))
        let store = GenerationStore(api: server.client)

        await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")

        #expect(!store.needsMoreCredits)
        #expect(store.errorMessage == "Generation failed.")
    }

    @Test("Assets are grouped per marketplace for the Review chips")
    func assetsAreGroupedByMarketplace() async {
        let server = StubbedServer(.json(generated))
        let store = GenerationStore(api: server.client)
        await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")

        #expect(store.assets(for: "amazon").count == 2)
        #expect(store.assets(for: "tiktok_shop").count == 1)
        #expect(store.assets(for: "etsy").isEmpty)
    }

    @Test("A marketplace chip shows its worst asset's status, not its best")
    func marketplaceStatusIsTheWorst() async {
        let server = StubbedServer(.json(generated))
        let store = GenerationStore(api: server.client)
        await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")

        // Amazon has one pass and one warn — showing "pass" would hide the problem.
        #expect(store.status(for: "amazon") == .warn)
        #expect(store.status(for: "tiktok_shop") == .pass)
    }

    @Test("Violations survive decoding so Review can name the rule in plain English")
    func violationsDecode() async throws {
        let server = StubbedServer(.json(generated))
        let store = GenerationStore(api: server.client)
        await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")

        let description = try #require(store.assets(for: "amazon").first { $0.type == "description" })
        let violation = try #require(description.violations.first)
        #expect(violation.message == "Amazon does not allow promotional wording in a title.")
        #expect(!violation.isFailure, "a warn must not read as a hard failure")
    }

    @Test("A failure after a success never leaves the earlier result on screen")
    func failureClearsEarlierResult() async {
        // Codex found this: the view read `result` after awaiting, so a failed
        // request dismissed as though the previous success had just happened.
        let server = StubbedServer(
            .json(generated),
            .json(#"{"error":"This needs 6 credits and you have 0."}"#, status: 402))
        let store = GenerationStore(api: server.client)

        let first = await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")
        #expect(first != nil)
        #expect(store.result != nil)

        let second = await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")

        #expect(second == nil, "a failed request must not hand back a result")
        #expect(store.result == nil, "the earlier success must not survive a failure")
        #expect(store.needsMoreCredits)
    }

    @Test("A marketplace that failed outright shows fail, never a green pass")
    func failedMarketplaceIsNotPass() async {
        let withFailure = """
        {"productId":"p1",
         "facts":{"suggestedName":"D","suggestedCategory":"C","material":null,"colour":null,
                  "keyFeatures":[],"visibleText":[]},
         "assets":[{"type":"title","marketplace":"amazon","content":"A","status":"pass","violations":[]}],
         "failures":[{"marketplace":"etsy","reason":"Claude returned no usable scripts."}],
         "creditsCharged":2,"balanceAfter":10}
        """
        let server = StubbedServer(.json(withFailure))
        let store = GenerationStore(api: server.client)
        await store.generate(productID: "p1", marketplaces: ["amazon", "etsy"], scriptCount: 0, token: "jwt")

        #expect(store.status(for: "amazon") == .pass)
        // Reporting green for a marketplace that errored is the worst answer.
        #expect(store.status(for: "etsy") == .fail)
        // A marketplace with no assets at all is also not a pass.
        #expect(store.status(for: "ebay") == .fail)
    }

    @Test("A second generate is refused while one is already running")
    func concurrentGenerateIsRefused() async {
        let server = StubbedServer(.json(generated), .json(generated))
        let store = GenerationStore(api: server.client)

        async let first = store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")
        async let second = store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")
        let results = await [first, second]

        // Double-tapping Generate must not charge twice.
        #expect(results.compactMap { $0 }.count == 1)
        #expect(server.requests.count == 1)
    }

    @Test("A balance that cannot be read does not block the screen")
    func balanceFailureIsTolerated() async {
        let server = StubbedServer(.json(#"{"error":"down"}"#, status: 500))
        let store = GenerationStore(api: server.client)

        await store.loadBalance(token: "jwt")

        // The server refuses an unaffordable request anyway, so a missing
        // balance is cosmetic.
        #expect(store.balance == nil)
        #expect(store.errorMessage == nil)
    }
    @Test("A lost generation response recovers the committed result without a second charge")
    func recoverCommittedGeneration() async throws {
        let server = StubbedServer(.transportFailure(URLError(.networkConnectionLost)), .json(generated))
        let store = GenerationStore(api: server.client)
        let result = await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")
        #expect(result?.creditsCharged == 6)
        #expect(server.requests.map(\.method) == ["POST", "GET"])
        let requestID = try #require(server.requests.first?.jsonObject?["requestId"] as? String)
        #expect(server.requests.last?.url?.query == "requestId=" + requestID)
        #expect(store.pendingRequest(productID: "p1") == nil)
    }

    @Test("An uncertain charge keeps its request ID through relaunch and rejects changed inputs")
    func durableGenerationRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstServer = StubbedServer(.transportFailure(URLError(.timedOut)),
            .json(#"{"error":"still running"}"#, status: 409))
        let first = GenerationStore(api: firstServer.client, cacheDirectory: directory)
        _ = await first.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")
        let pending = try #require(first.pendingRequest(productID: "p1"))
        let secondServer = StubbedServer(.json(generated))
        let relaunched = GenerationStore(api: secondServer.client, cacheDirectory: directory)
        #expect(relaunched.pendingRequest(productID: "p1")?.requestId == pending.requestId)
        let changed = await relaunched.generate(productID: "p1", marketplaces: ["etsy"], scriptCount: 0, token: "jwt")
        #expect(changed == nil)
        #expect(secondServer.requests.isEmpty)
        _ = await relaunched.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0, token: "jwt")
        #expect(secondServer.lastRequest?.jsonObject?["requestId"] as? String == pending.requestId.uuidString)
        #expect(relaunched.pendingRequest(productID: "p1") == nil)
    }

}
