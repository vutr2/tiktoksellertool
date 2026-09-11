//
//  ListingForgeTests.swift
//  ListingForgeTests
//
//  Placeholder. Real tests (credit accounting, compliance rules, cost) land in
//  later milestones per spec §0.
//

import Testing
@testable import ListingForge

struct ListingForgeTests {
    @Test func apiBaseURLIsConfigured() {
        #expect(!AppConfig.apiBaseURL.absoluteString.isEmpty)
    }
}
