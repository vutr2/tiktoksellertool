//
//  ProductStoreTests.swift
//  ListingForgeTests
//
//  The contract with api/src/lib/products.ts. A rename on either side should
//  break here, not on a seller's upload.
//

import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Product store")
struct ProductStoreTests {

    /// Exactly what the server returned in a live run.
    private let created = """
    {"id":"36ba14f2-3bab-4b13-bb05-c7cb3d6e31d2","name":"Ceramic pour-over dripper",
     "category":"Home & Kitchen › Coffee",
     "cutoutPath":"0cbd9820-9229-49d6-9747-671735c41caf/36ba14f2-3bab-4b13-bb05-c7cb3d6e31d2.png",
     "createdAt":"2026-09-13T06:18:36.674469+00:00"}
    """

    private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    @Test("Creating a product sends the shape the API validates")
    func createSendsExpectedBody() async throws {
        let server = StubbedServer(.json(created, status: 201))
        let store = ProductStore(api: server.client)

        let product = await store.create(
            name: "Ceramic pour-over dripper",
            category: "Home & Kitchen › Coffee",
            keyFeatures: ["Hand-glazed", "Fits 02 filters"],
            cutoutPNG: pngData,
            token: "jwt"
        )

        #expect(product?.id == "36ba14f2-3bab-4b13-bb05-c7cb3d6e31d2")
        #expect(store.errorMessage == nil)
        #expect(!store.isSaving)

        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/products")
        #expect(request.method == "POST")
        #expect(request.header("Authorization") == "Bearer jwt")

        let body = try #require(request.jsonObject)
        #expect(body["name"] as? String == "Ceramic pour-over dripper")
        #expect(body["category"] as? String == "Home & Kitchen › Coffee")
        #expect(body["keyFeatures"] as? [String] == ["Hand-glazed", "Fits 02 filters"])
        // Base64 of the PNG, which the server checks for the signature.
        #expect(body["cutoutPngBase64"] as? String == pngData.base64EncodedString())
    }

    @Test("A product with no photo omits the cutout instead of sending null")
    func createWithoutCutout() async throws {
        let server = StubbedServer(.json(created, status: 201))
        let store = ProductStore(api: server.client)

        _ = await store.create(name: "Dripper", category: nil, keyFeatures: [],
                               cutoutPNG: nil, token: "jwt")

        let body = try #require(server.lastRequest?.jsonObject)
        #expect(body["cutoutPngBase64"] == nil)
        #expect(body["category"] == nil)
        #expect(body["keyFeatures"] as? [String] == [])
    }

    @Test("A created product appears at the top of the list, matching the API's order")
    func createPrependsToList() async {
        let server = StubbedServer(.json(created, status: 201))
        let store = ProductStore(api: server.client)

        _ = await store.create(name: "Dripper", category: nil, keyFeatures: [],
                               cutoutPNG: nil, token: "jwt")

        #expect(store.products.count == 1)
        #expect(store.products.first?.name == "Ceramic pour-over dripper")
    }

    @Test("A rejected product surfaces the server's reason and saves nothing")
    func createFailureIsReported() async {
        let server = StubbedServer(.json(#"{"error":"Give the product a name."}"#, status: 400))
        let store = ProductStore(api: server.client)

        let product = await store.create(name: "", category: nil, keyFeatures: [],
                                         cutoutPNG: nil, token: "jwt")

        #expect(product == nil)
        #expect(store.errorMessage == "Give the product a name.")
        #expect(store.products.isEmpty, "nothing may be cached when the server refused")
        #expect(!store.isSaving)
    }

    @Test("Loading replaces the list from the server, the source of truth")
    func loadFetchesProducts() async throws {
        let list = #"{"products":[{"id":"p1","name":"Dripper","category":null,"cutoutPath":null,"createdAt":"2026-09-13T06:18:36.674469+00:00"}]}"#
        let server = StubbedServer(.json(list))
        let store = ProductStore(api: server.client)

        await store.load(token: "jwt")

        #expect(store.products.count == 1)
        #expect(store.products.first?.category == nil)
        #expect(server.lastRequest?.url?.path == "/api/products")
        #expect(server.lastRequest?.method == "GET")
    }
}

@Suite("Product cache mapping")
struct ProductCacheMapperTests {

    @Test("Postgres microsecond timestamps parse — three-digit parsing would silently fail")
    func parsesMicrosecondTimestamps() throws {
        // This is the literal value Supabase returned. ISO8601DateFormatter's
        // fractional-seconds option is documented around milliseconds, so this
        // is checked rather than assumed: falling back to .now would date every
        // cached product to whenever it was synced.
        let date = try #require(ProductCacheMapper.iso8601("2026-09-13T06:18:36.674469+00:00"))

        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 13)
        #expect(components.hour == 6)
        #expect(components.minute == 18)
    }

    @Test("A timestamp without fractional seconds still parses")
    func parsesPlainTimestamps() {
        #expect(ProductCacheMapper.iso8601("2026-09-13T06:18:36Z") != nil)
    }

    @Test("Nonsense returns nil rather than a wrong date")
    func rejectsGarbage() {
        #expect(ProductCacheMapper.iso8601("not a date") == nil)
        #expect(ProductCacheMapper.iso8601("") == nil)
    }

    @Test("The cache mirrors the server record faithfully")
    func mapsAllFields() {
        let dto = ProductDTO(
            id: "p1", name: "Dripper", category: "Home & Kitchen",
            cutoutPath: "org/p1.png", createdAt: "2026-09-13T06:18:36.674469+00:00"
        )

        let cached = ProductCacheMapper.cached(from: dto)

        #expect(cached.serverID == "p1")
        #expect(cached.name == "Dripper")
        #expect(cached.category == "Home & Kitchen")
        #expect(cached.cutoutURL == "org/p1.png")
    }

    @Test("A product with no category caches an empty string, never the word nil")
    func missingCategoryIsEmpty() {
        let dto = ProductDTO(id: "p1", name: "D", category: nil, cutoutPath: nil,
                             createdAt: "2026-09-13T06:18:36Z")
        #expect(ProductCacheMapper.cached(from: dto).category == "")
    }
}

@Suite("Product details input")
struct ProductDetailsInputTests {

    @Test("Key features split on newlines — one feature per line")
    func featuresSplit() {
        #expect(ProductDetailsView.features(from: "Hand-glazed\nFits 02 filters")
            == ["Hand-glazed", "Fits 02 filters"])
    }

    @Test("A comma inside a feature is kept, not treated as a separator")
    func commasAreNotSeparators() {
        // Splitting on commas turned "Fits 02, 03 and 04 filters" into two
        // features, neither of them true.
        #expect(ProductDetailsView.features(from: "Fits 02, 03 and 04 filters")
            == ["Fits 02, 03 and 04 filters"])
    }

    @Test("Blank lines are dropped, not sent as empty features")
    func featuresAreCleaned() {
        #expect(ProductDetailsView.features(from: "  \n\n Ceramic \n ")
            == ["Ceramic"])
        #expect(ProductDetailsView.features(from: "").isEmpty)
        #expect(ProductDetailsView.features(from: "   ").isEmpty)
    }

    @Test("A blank optional field becomes nil so the server stores null, not an empty string")
    func blankBecomesNil() {
        #expect(ProductDetailsView.trimmedOrNil("   ") == nil)
        #expect(ProductDetailsView.trimmedOrNil("") == nil)
        #expect(ProductDetailsView.trimmedOrNil("  Coffee  ") == "Coffee")
    }
}
