//
//  RulesStore.swift
//  ListingForge
//
//  Fetches the versioned marketplace rules the server publishes (SPEC §7) and
//  caches them for the session.
//
//  The capture overlay needs to know what fill ratio to draw. Hardcoding 85%
//  here is exactly what SPEC §12 lists as a problem — "Marketplace limits
//  hardcoded instead of served as config" — because a rule change would then
//  need an App Store review. So the number comes from the API.
//

import Foundation
import Observation

// MARK: - Wire format (mirrors api/src/lib/rules/types.ts)

struct FillRatioDTO: Codable, Hashable {
    let min: Double?
    let max: Double?
}

struct ImageRuleDTO: Codable, Hashable {
    let aspectRatio: String?
    let minLongestEdge: Int?
    let productFillRatio: FillRatioDTO?
    let forbid: [String]?
}

struct MarketplaceRulesDTO: Codable, Hashable, Identifiable {
    let id: String
    let version: String
    let displayName: String
    /// "included" or "pro" — drives the Pro badge in the marketplace picker.
    let tier: String
    let summary: String
    let images: [String: ImageRuleDTO]

    var mainImage: ImageRuleDTO? { images["main"] }
    var requiresProPlan: Bool { tier == "pro" }
}

struct RulesResponse: Codable {
    let versions: [String: String]
    let marketplaces: [MarketplaceRulesDTO]
}

// MARK: - Store

@MainActor
@Observable
final class RulesStore {

    private(set) var marketplaces: [MarketplaceRulesDTO] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    #if DEBUG
    /// Seeds marketplaces for screenshots. `load()` then no-ops because the list
    /// is already populated.
    func seedDemo(_ marketplaces: [MarketplaceRulesDTO]) {
        self.marketplaces = marketplaces
    }
    #endif

    func load() async {
        guard marketplaces.isEmpty, !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        do {
            let response: RulesResponse = try await api.get("api/rules")
            marketplaces = response.marketplaces
        } catch {
            // The overlay still has to draw something, so the caller falls back
            // to the strictest rule we know rather than blocking capture.
            loadFailed = true
        }
    }

    /// The tightest main-image fill requirement across every marketplace.
    ///
    /// Framing for the strictest rule means one shot works everywhere — which
    /// is what lets the seller pick marketplaces *after* shooting, as the
    /// design's step order requires.
    var strictestMainFill: (ratio: Double, marketplace: String)? {
        marketplaces
            .compactMap { rules -> (Double, String)? in
                guard let min = rules.mainImage?.productFillRatio?.min else { return nil }
                return (min, rules.displayName)
            }
            .max { $0.0 < $1.0 }
            .map { (ratio: $0.0, marketplace: $0.1) }
    }

    /// The caption under the framing guide, e.g. "85% fill · Amazon main image".
    var framingCaption: String? {
        guard let strictest = strictestMainFill else { return nil }
        return "\(Int((strictest.ratio * 100).rounded()))% fill · \(strictest.marketplace) main image"
    }

    /// Largest minimum resolution any marketplace asks for, so one capture
    /// satisfies all of them.
    var strictestMinimumLongestEdge: Int? {
        marketplaces.compactMap { $0.mainImage?.minLongestEdge }.max()
    }
}
