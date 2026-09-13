//
//  ReviewTests.swift
//  ListingForgeTests
//
//  Review is the screen the seller paid for. These pin that a listing survives
//  the round trip and that nothing broken is shown as clean.
//

import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Listing review")
struct ReviewTests {

    /// The shape `GET /api/products/:id/assets` returned in a live run.
    private let stored = """
    {"product":{"id":"p1","name":"Ceramic pour-over dripper","category":"Coffee"},
     "assets":[
       {"id":"a1","type":"title","marketplace":"amazon","content":"A title",
        "status":"pass","violations":[]},
       {"id":"a2","type":"description","marketplace":"amazon","content":"Bullets",
        "status":"warn","violations":[{"code":"title.promo_language","severity":"warn",
          "field":"title.forbid","message":"Amazon does not allow promotional wording in a title.",
          "detail":"Found: best price."}]}
     ]}
    """

    @Test("A stored listing is loaded so work already paid for stays reachable")
    func loadsStoredListing() async throws {
        let server = StubbedServer(.json(stored))
        let store = GenerationStore(api: server.client)

        let listing = try #require(await store.loadAssets(productID: "p1", token: "jwt"))

        #expect(listing.product.name == "Ceramic pour-over dripper")
        #expect(listing.assets.count == 2)
        #expect(server.lastRequest?.url?.path == "/api/products/p1/assets")
        #expect(server.lastRequest?.header("Authorization") == "Bearer jwt")
    }

    @Test("Violations survive the round trip with their plain-English wording")
    func violationsSurvive() async throws {
        let server = StubbedServer(.json(stored))
        let store = GenerationStore(api: server.client)
        let listing = try #require(await store.loadAssets(productID: "p1", token: "jwt"))

        let description = try #require(listing.assets.first { $0.type == "description" })
        let violation = try #require(description.violations.first)
        #expect(violation.message == "Amazon does not allow promotional wording in a title.")
        #expect(violation.detail == "Found: best price.")
        #expect(!violation.isFailure)
    }

    @Test("An unrecognised status degrades to warn rather than hiding the listing")
    func unknownStatusDegradesSafely() {
        // A status written by a newer build must not make the whole listing
        // fail to decode — that would lose work the seller was charged for.
        let asset = StoredAssetDTO(id: "a1", type: "title", marketplace: "amazon",
                                   content: "x", status: "something-new", violations: [])
        #expect(asset.compliance == .warn)
    }

    @Test("Known statuses map exactly")
    func knownStatusesMap() {
        for (raw, expected) in [("pass", ComplianceStatus.pass), ("warn", .warn), ("fail", .fail)] {
            let asset = StoredAssetDTO(id: "a", type: "title", marketplace: "m",
                                       content: "", status: raw, violations: [])
            #expect(asset.compliance == expected)
        }
    }

    @Test("Review shows the same asset whether it was just generated or reopened")
    func bothSourcesProduceTheSameAsset() {
        // One view serves both paths, so the two DTOs must converge.
        let fresh = GeneratedAssetDTO(type: "title", marketplace: "amazon",
                                      content: "A title", status: .pass, violations: [])
        let reopened = StoredAssetDTO(id: "a1", type: "title", marketplace: "amazon",
                                      content: "A title", status: "pass", violations: [])

        let a = ReviewAsset(fresh)
        let b = ReviewAsset(reopened)

        #expect(a.type == b.type)
        #expect(a.marketplace == b.marketplace)
        #expect(a.content == b.content)
        #expect(a.status == b.status)
    }

    @Test("A listing that could not be loaded reports why instead of showing blank")
    func loadFailureIsReported() async {
        let server = StubbedServer(.json(#"{"error":"That product could not be found."}"#, status: 404))
        let store = GenerationStore(api: server.client)

        let listing = await store.loadAssets(productID: "missing", token: "jwt")

        #expect(listing == nil)
        #expect(store.errorMessage == "That product could not be found.")
    }
}
