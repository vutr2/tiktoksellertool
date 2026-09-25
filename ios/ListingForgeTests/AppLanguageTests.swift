//
//  AppLanguageTests.swift
//  ListingForgeTests
//
//  The listing language is chosen at sign-in, before there is an account, and
//  changed in Settings. These pin the parts that would fail silently.
//

import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Listing language")
struct AppLanguageTests {

    private func emptyDefaults() throws -> UserDefaults {
        let suite = "language-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A Vietnamese phone starts on Vietnamese")
    func followsTheDevice() {
        // Defaulting everyone to English would make the picker look broken to
        // exactly the sellers the second language exists for.
        #expect(AppLanguage.deviceDefault(locale: Locale(identifier: "vi_VN")) == .vi)
        #expect(AppLanguage.deviceDefault(locale: Locale(identifier: "en_US")) == .en)
        #expect(AppLanguage.deviceDefault(locale: Locale(identifier: "fr_FR")) == .en)
    }

    @Test("A choice survives relaunch and outranks the device language")
    func choiceIsRemembered() throws {
        let defaults = try emptyDefaults()
        LanguagePreference(defaults: defaults).select(.vi)

        #expect(LanguagePreference(defaults: defaults).language == .vi)
    }

    @Test("Each language is named in itself")
    func namedInItsOwnLanguage() {
        // Someone who picked the wrong one cannot read a list written in the
        // language they do not speak.
        #expect(AppLanguage.vi.displayName == "Tiếng Việt")
        #expect(AppLanguage.en.displayName == "English")
    }

    @Test("A request written before this field existed still loads, as English")
    func legacyPendingRequestDecodes() throws {
        // Failing to decode would drop the durable retry the record exists for.
        let legacy = #"{"requestId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","productID":"p1","marketplaces":["amazon"],"scriptCount":0}"#
        let pending = try JSONDecoder().decode(
            GenerationStore.PendingGeneration.self, from: Data(legacy.utf8))

        #expect(pending.language == .en)
    }

    @Test("A result completed before this field existed still decodes, as English")
    func legacyResultDecodes() throws {
        // Those rows live in Postgres and are replayed verbatim by the recovery
        // path, so they cross the deploy unchanged.
        let legacy = """
        {"productId":"p1",
         "facts":{"suggestedName":"A","suggestedCategory":"B","material":null,"colour":null,
                  "keyFeatures":[],"visibleText":[]},
         "assets":[],"failures":[],"creditsCharged":0,"balanceAfter":10}
        """
        let result = try JSONDecoder().decode(GenerateResultDTO.self, from: Data(legacy.utf8))

        #expect(result.outputLanguage == .en)
    }

    @Test("The chosen language is sent with the generation")
    func languageIsSent() async throws {
        let server = StubbedServer(.json(Self.generated))
        let store = GenerationStore(api: server.client)

        _ = await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0,
                                 language: .vi, token: "jwt")

        let request = try #require(server.lastRequest)
        let body = try #require(request.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["language"] as? String == "vi")
    }

    @Test("Changing the language mid-flight is a new selection, not a retry")
    func changingLanguageIsRefused() async throws {
        // Language is part of the server's idempotency hash: resending the same
        // requestId with a different one would be answered 409.
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let failing = StubbedServer(.json(#"{"error":"Generation failed."}"#, status: 500))
        let store = GenerationStore(api: failing.client, cacheDirectory: directory)
        _ = await store.generate(productID: "p1", marketplaces: ["amazon"], scriptCount: 0,
                                 language: .en, token: "jwt")

        let relaunched = GenerationStore(api: StubbedServer(.json(Self.generated)).client,
                                         cacheDirectory: directory)
        let changed = await relaunched.generate(productID: "p1", marketplaces: ["amazon"],
                                                scriptCount: 0, language: .vi, token: "jwt")

        #expect(changed == nil)
        #expect(relaunched.errorMessage != nil)
    }

    @Test("A listing cached before this field existed still loads, as English")
    func legacyCachedListingDecodes() throws {
        // These sit in the on-device snapshot cache. A required field would
        // drop every offline listing a seller already has.
        let legacy = """
        {"product":{"id":"p1","name":"A","category":"B"},
         "assets":[],"failures":[]}
        """
        let listing = try JSONDecoder().decode(ListingAssetsDTO.self, from: Data(legacy.utf8))

        #expect(listing.outputLanguage == .en)
    }

    @Test("A listing carries the language it was generated in")
    func generatedListingKeepsItsLanguage() throws {
        let result = try JSONDecoder().decode(GenerateResultDTO.self, from: Data(Self.generated.utf8))
        let listing = ListingAssetsDTO.generated(result, productName: "A")

        // The free rules check sends this so the server knows whether its
        // English content checks could read the copy. Losing it here would make
        // Vietnamese copy report as fully checked.
        #expect(listing.outputLanguage == .vi)

        let roundTripped = try JSONDecoder().decode(
            ListingAssetsDTO.self, from: JSONEncoder().encode(listing))
        #expect(roundTripped.outputLanguage == .vi)
    }

    @Test("Each asset keeps the language of the generation that produced it")
    func assetsKeepTheirOwnLanguage() throws {
        // A product accumulates assets across generations. Labelling them all
        // with the newest run's language told the server that older Vietnamese
        // copy was English, and its content checks then reported copy they had
        // never read as clean.
        let mixed = """
        {"product":{"id":"p1","name":"A","category":"B"},
         "failures":[],
         "assets":[
           {"id":"a1","type":"title","marketplace":"tiktok_shop","content":"Máy pha cà phê",
            "status":"warn","violations":[],"language":"vi"},
           {"id":"a2","type":"title","marketplace":"etsy","content":"Ceramic dripper",
            "status":"pass","violations":[],"language":"en"},
           {"id":"a3","type":"title","marketplace":"amazon","content":"Older copy",
            "status":"pass","violations":[]}
         ]}
        """
        let listing = try JSONDecoder().decode(ListingAssetsDTO.self, from: Data(mixed.utf8))
        let review = listing.assets.map(ReviewAsset.init)

        #expect(review[0].language == .vi)
        #expect(review[1].language == .en)
        // Unrecorded origin stays unknown rather than becoming English here;
        // the server applies its own documented default.
        #expect(review[2].language == nil)
    }

    private static let generated = """
    {"productId":"p1","language":"vi",
     "facts":{"suggestedName":"A","suggestedCategory":"B","material":null,"colour":null,
              "keyFeatures":[],"visibleText":[]},
     "assets":[],"failures":[],"creditsCharged":0,"balanceAfter":10}
    """
}
