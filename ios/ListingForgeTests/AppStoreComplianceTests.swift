//
//  AppStoreComplianceTests.swift
//  ListingForgeTests
//
//  Catches the submission blockers that are cheap to check and expensive to
//  discover from a rejection email. Each test names the guideline it guards.
//
//  These run against the host app bundle, so they see exactly what would ship.
//

import Foundation
import Testing
@testable import ListingForge

@Suite("App Store compliance")
struct AppStoreComplianceTests {

    private func infoValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    private func privacyManifest() throws -> [String: Any] {
        let url = try #require(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy is not in the app bundle — App Store Connect rejects the upload."
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any], "Privacy manifest is not a dictionary")
    }

    // MARK: Privacy manifest — required since 1 May 2024

    @Test("The privacy manifest ships inside the app bundle")
    func privacyManifestIsBundled() throws {
        _ = try privacyManifest()
    }

    @Test("The app declares that it does not track")
    func declaresNoTracking() throws {
        let manifest = try privacyManifest()

        let tracking = try #require(manifest["NSPrivacyTracking"] as? Bool)
        #expect(tracking == false, "Tracking would require an ATT prompt we do not show.")

        let domains = try #require(manifest["NSPrivacyTrackingDomains"] as? [String])
        #expect(domains.isEmpty, "Tracking domains listed while NSPrivacyTracking is false: \(domains)")
    }

    @Test("Everything the app collects is declared, linked, and not used for tracking")
    func declaresCollectedData() throws {
        let manifest = try privacyManifest()
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])

        let types = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        // SPEC §5.4 wants the inventory kept accurate. This test previously
        // checked only the sign-in types, so the manifest could fall behind the
        // app without anything failing — which is exactly what happened when
        // photo upload shipped.
        #expect(types.contains("NSPrivacyCollectedDataTypeEmailAddress"))
        #expect(types.contains("NSPrivacyCollectedDataTypeUserID"))
        #expect(
            types.contains("NSPrivacyCollectedDataTypePhotosorVideos"),
            "The app uploads product photos — the manifest must declare them."
        )
        #expect(
            types.contains("NSPrivacyCollectedDataTypeOtherUserContent"),
            "Product name, category and features are sent to a model provider."
        )

        for entry in collected {
            let name = entry["NSPrivacyCollectedDataType"] as? String ?? "unknown"
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false, "\(name) claims tracking")
            let purposes = entry["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []
            #expect(!purposes.isEmpty, "\(name) declares no purpose")
        }
    }

    @Test("Required-reason API declarations stay in sync with what the app calls")
    func declaresAccessedAPIs() throws {
        let manifest = try privacyManifest()
        // Empty today: the Keychain is not a required-reason API and SwiftData
        // is first-party. Adding a dependency means re-auditing this.
        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        for entry in accessed {
            #expect(entry["NSPrivacyAccessedAPIType"] as? String != nil)
            let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            #expect(!reasons.isEmpty, "A declared API with no reason is rejected")
        }
    }

    // MARK: Info.plist

    @Test("Every permission the app requests explains why, in a full sentence")
    func usageDescriptionsAreMeaningful() throws {
        // Apple rejects terse strings like "Camera access". The description has
        // to tell the seller what they get for saying yes.
        for key in [
            "NSCameraUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
        ] {
            let text = try #require(infoValue(key), "\(key) is missing — the app crashes on first use of that API")
            #expect(text.count >= 30, "\(key) is too terse to pass review: \"\(text)\"")
            #expect(text.hasSuffix("."), "\(key) should read as a sentence: \"\(text)\"")
            #expect(text.contains("Listing Force"), "\(key) should say who is asking")
        }
    }

    @Test("The encryption declaration is present so uploads are not held for export compliance")
    func declaresEncryptionUsage() {
        let declared = Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption")
        #expect(declared as? Bool == false, "Missing ITSAppUsesNonExemptEncryption blocks every TestFlight build")
    }

    @Test("Version and build strings are present and well formed")
    func versionStringsAreValid() throws {
        let short = try #require(infoValue("CFBundleShortVersionString"))
        let build = try #require(infoValue("CFBundleVersion"))

        #expect(short.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil, "bad version: \(short)")
        #expect(!build.isEmpty)
    }

    @Test("The bundle identifier matches the one Sign in with Apple is configured for")
    func bundleIdentifierMatchesAppleAudience() {
        // The server verifies the identity token against this audience
        // (APPLE_AUDIENCE). A mismatch fails every Apple sign-in silently.
        #expect(Bundle.main.bundleIdentifier == "com.ctt.listingforge")
    }

    // MARK: Guideline 5.1 — payments must be IAP

    @Test("No external checkout host is linked from the shipped binary")
    func noExternalPaymentLinks() throws {
        // Guideline 3.1.1 / SPEC §5.1: an external purchase link is an instant
        // rejection. Scanning the binary catches one added by accident.
        let executable = try #require(Bundle.main.executableURL)
        let binary = try Data(contentsOf: executable)

        let forbidden = [
            "checkout.stripe.com", "buy.stripe.com",
            "paypal.com/checkout", "www.paypal.com/cgi-bin",
            "checkout.paddle.com", "gumroad.com/l/",
        ]

        for host in forbidden {
            let needle = Data(host.utf8)
            #expect(binary.range(of: needle) == nil, "External payment link found in the binary: \(host)")
        }
    }

    // MARK: Guideline 5.3 — account deletion

    @Test("Account deletion is a real endpoint, not a mailto link")
    func accountDeletionIsImplemented() async throws {
        // SPEC §5.3. AuthStoreTests covers the behaviour; this pins the route
        // so a rename cannot quietly turn deletion into a no-op.
        let server = StubbedServer(.empty())
        let auth = await AuthStore(api: server.client)

        let stored = Session(token: "jwt", user: UserDTO(id: "u_1", email: "seller@example.com"))
        KeychainStore().set(try JSONEncoder().encode(stored), for: "session")
        defer { KeychainStore().delete("session") }

        await auth.restore()
        await auth.deleteAccount()

        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/account/delete")
        #expect(request.method == "POST")
        #expect(request.header("Authorization") == "Bearer jwt")
    }
}
