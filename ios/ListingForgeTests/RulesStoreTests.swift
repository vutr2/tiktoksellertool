//
//  RulesStoreTests.swift
//  ListingForgeTests
//
//  The capture overlay draws whatever this store says. If it picks the wrong
//  marketplace, every photo is framed for the wrong rule.
//

import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Rules store")
struct RulesStoreTests {

    /// The shape `GET /api/rules` actually returns (api/src/app/api/rules/route.ts).
    private let payload = """
    {
      "versions": { "amazon": "2026-09-draft", "tiktok_shop": "2026-09-draft" },
      "marketplaces": [
        {
          "id": "tiktok_shop", "version": "2026-09-draft", "displayName": "TikTok Shop",
          "tier": "included", "summary": "1:1 · video cover · overlay text OK",
          "images": { "main": { "aspectRatio": "1:1", "forbid": [] } }
        },
        {
          "id": "amazon", "version": "2026-09-draft", "displayName": "Amazon",
          "tier": "pro", "summary": "Pure white main · no text · 1600px",
          "images": {
            "main": {
              "aspectRatio": "1:1", "minLongestEdge": 1600,
              "productFillRatio": { "min": 0.85 },
              "forbid": ["text", "logo", "watermark", "border", "human"]
            }
          }
        }
      ]
    }
    """

    @Test("Decodes the payload the rules endpoint returns")
    func decodesServerShape() async throws {
        let server = StubbedServer(.json(payload))
        let store = RulesStore(api: server.client)

        await store.load()

        #expect(store.marketplaces.count == 2)
        #expect(!store.loadFailed)
        #expect(server.lastRequest?.url?.path == "/api/rules")

        let amazon = try #require(store.marketplaces.first { $0.id == "amazon" })
        #expect(amazon.displayName == "Amazon")
        #expect(amazon.requiresProPlan)
        #expect(amazon.mainImage?.minLongestEdge == 1600)
        #expect(amazon.mainImage?.productFillRatio?.min == 0.85)

        let tiktok = try #require(store.marketplaces.first { $0.id == "tiktok_shop" })
        #expect(!tiktok.requiresProPlan, "TikTok Shop is the included tier")
    }

    @Test("The framing guide follows the strictest marketplace, not the first one")
    func picksTheStrictestFill() async throws {
        let server = StubbedServer(.json(payload))
        let store = RulesStore(api: server.client)

        await store.load()

        // Framing for the tightest rule is what lets a seller choose
        // marketplaces after shooting instead of before.
        let strictest = try #require(store.strictestMainFill)
        #expect(strictest.ratio == 0.85)
        #expect(strictest.marketplace == "Amazon")
        #expect(store.framingCaption == "85% fill · Amazon main image")
    }

    @Test("The strictest minimum resolution is used so one shot serves every marketplace")
    func picksTheLargestMinimumEdge() async {
        let server = StubbedServer(.json(payload))
        let store = RulesStore(api: server.client)

        await store.load()

        #expect(store.strictestMinimumLongestEdge == 1600)
    }

    @Test("Marketplaces with no fill rule do not drag the requirement down")
    func marketplacesWithoutFillAreIgnored() async {
        let onlyLoose = """
        {"versions":{},"marketplaces":[
          {"id":"etsy","version":"v","displayName":"Etsy","tier":"pro","summary":"s",
           "images":{"main":{"forbid":[]}}}
        ]}
        """
        let server = StubbedServer(.json(onlyLoose))
        let store = RulesStore(api: server.client)

        await store.load()

        // No rule at all means no caption — better than inventing a number.
        #expect(store.strictestMainFill == nil)
        #expect(store.framingCaption == nil)
    }

    @Test("A failed load is reported rather than leaving a silent empty list")
    func failureIsReported() async {
        let server = StubbedServer(.json(#"{"error":"Server is down."}"#, status: 500))
        let store = RulesStore(api: server.client)

        await store.load()

        #expect(store.loadFailed)
        #expect(store.marketplaces.isEmpty)
        #expect(!store.isLoading)
    }

    @Test("Rules are fetched once per session, not on every screen appearance")
    func doesNotRefetchWhenLoaded() async {
        let server = StubbedServer(.json(payload), .json(payload))
        let store = RulesStore(api: server.client)

        await store.load()
        await store.load()
        await store.load()

        #expect(server.requests.count == 1, "the config is versioned and stable within a session")
    }
}
