//
//  AppConfig.swift
//  ListingForge
//
//  Reads build-time configuration. API_BASE_URL is injected via project.yml so
//  it can differ per environment without touching code.
//

import Foundation

enum AppConfig {
    static var apiBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }
}
