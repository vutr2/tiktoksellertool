//
//  AppConfigTests.swift
//  ListingForgeTests
//
//  API_BASE_URL is injected from project.yml into Info.plist at build time. If
//  that substitution ever breaks, every request silently goes to the localhost
//  fallback instead — which looks fine in the simulator and fails in the field.
//
//  These tests are hosted by the app, so Bundle.main is ListingForge.app.
//

import Foundation
import Testing
@testable import ListingForge

@Suite("AppConfig")
struct AppConfigTests {

    @Test("The base URL is read from the host app's Info.plist, not the fallback")
    func baseURLComesFromInfoPlist() throws {
        let configured = try #require(
            Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
            "API_BASE_URL is missing from Info.plist"
        )

        #expect(configured.isEmpty == false)
        #expect(configured.hasPrefix("$(") == false, "Build setting was not substituted: \(configured)")
        #expect(AppConfig.apiBaseURL.absoluteString == configured)
    }

    @Test("The base URL is absolute, so appended paths resolve to real endpoints")
    func baseURLIsAbsolute() throws {
        let url = AppConfig.apiBaseURL

        let scheme = try #require(url.scheme)
        #expect(["http", "https"].contains(scheme))
        #expect(url.host?.isEmpty == false)
        // APIClient builds every request this way.
        #expect(url.appendingPathComponent("api/health").path == "/api/health")
    }

    @Test("The base URL carries no trailing path that would corrupt appended routes")
    func baseURLHasNoTrailingPath() {
        // "http://host/api" would turn api/health into /api/api/health.
        #expect(AppConfig.apiBaseURL.path.isEmpty || AppConfig.apiBaseURL.path == "/")
    }
}
