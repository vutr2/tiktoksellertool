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

    private static let generated = """
    {"productId":"p1","language":"vi",
     "facts":{"suggestedName":"A","suggestedCategory":"B","material":null,"colour":null,
              "keyFeatures":[],"visibleText":[]},
     "assets":[],"failures":[],"creditsCharged":0,"balanceAfter":10}
    """
}
