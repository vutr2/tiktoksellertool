//
//  AppConfig.swift
//  ListingForge
//
//  Reads build-time configuration. API_BASE_URL is injected via project.yml so
//  it can differ per environment without touching code.
//

import Foundation

enum AppConfig {
    static var privacyPolicyURL: URL? { configuredURL("PRIVACY_POLICY_URL") }
    static var supportURL: URL? { configuredURL("SUPPORT_URL") }
    static var termsURL: URL? { configuredURL("TERMS_URL") }

    private static func configuredURL(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static var apiBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }
}
