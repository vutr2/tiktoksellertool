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

    @Test("A failed rule cannot be rendered as a green pass")
    func failedViolationOverridesPassBadge() {
        let asset = ReviewAsset(StoredAssetDTO(
            id: "a1", type: "title", marketplace: "amazon", content: "Unsafe claim", status: "pass",
            violations: [ViolationDTO(code: "claim", severity: "fail", field: "title",
                                      message: "Remove the unverified claim.", detail: nil)]))
        #expect(asset.displayedStatus == .fail)
    }

    @Test("Offline listing snapshots keep failed marketplaces and full rule explanations")
    func offlineComplianceSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoded = try JSONDecoder().decode(ListingAssetsDTO.self, from: Data(stored.utf8))
        let listing = ListingAssetsDTO(product: decoded.product, assets: decoded.assets,
                                       failures: [GenerationFailureDTO(marketplace: "etsy", reason: "No usable listing was generated.")])
        let cache = ListingSnapshotCache(directory: directory)
        try cache.save(listing)

        // Reopen through a new helper to prove the warning comes from disk.
        let saved = try ListingSnapshotCache(directory: directory).load(productID: "p1")
        let reopened = try #require(saved)
        #expect(reopened.assets == listing.assets)
        #expect(reopened.failures == listing.failures)
        #expect(reopened.assets[1].violations.first?.detail == "Found: best price.")
        #expect(reopened.assets[1].compliance == .warn)
    }

    @Test("Credit-funded listings remain usable when their refresh loses connectivity")
    func offlineRefreshPreservesListingAndCompliance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listing = try JSONDecoder().decode(ListingAssetsDTO.self, from: Data(stored.utf8))
        try ListingSnapshotCache(directory: directory).save(listing)
        let server = StubbedServer(.json(#"{"error":"Temporarily unavailable"}"#, status: 503))
        let store = GenerationStore(api: server.client, cacheDirectory: directory)
        let reopened = try #require(await store.loadAssets(productID: "p1", token: "jwt"))
        #expect(reopened.assets == listing.assets)
        #expect(store.listingLoadWarning != nil)
        #expect(store.errorMessage == nil)
    }

    @Test("A server denial never revives a cached credit-funded listing")
    func deniedListingDoesNotFallBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listing = try JSONDecoder().decode(ListingAssetsDTO.self, from: Data(stored.utf8))
        try ListingSnapshotCache(directory: directory).save(listing)
        let server = StubbedServer(.json(#"{"error":"That product could not be found."}"#, status: 404))
        let store = GenerationStore(api: server.client, cacheDirectory: directory)
        #expect(await store.loadAssets(productID: "p1", token: "jwt") == nil)
    }
}
