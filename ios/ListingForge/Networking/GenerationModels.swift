//
//  GenerationModels.swift
//  ListingForge
//
//  Mirrors api/src/lib/generate.ts and the rules engine's Violation shape.
//

import Foundation

/// One rule a generated asset broke. `message` is plain English and is shown
/// verbatim — the server never sends a code to the screen (SPEC §10).
struct ViolationDTO: Codable, Hashable, Identifiable {
    let code: String
    let severity: String
    let field: String
    let message: String
    let detail: String?

    var id: String { code + field }
    var isFailure: Bool { severity == "fail" }
}

/// The pass / warn / fail badge in Review.
enum ComplianceStatus: String, Codable {
    case pass, warn, fail
}

struct GeneratedAssetDTO: Codable, Hashable, Identifiable {
    let type: String
    let marketplace: String
    let content: String
    let status: ComplianceStatus
    let violations: [ViolationDTO]

    var id: String { marketplace + type + content.prefix(24) }
}

struct ProductFactsDTO: Codable, Hashable {
    let suggestedName: String
    let suggestedCategory: String
    let material: String?
    let colour: String?
    let keyFeatures: [String]
    let visibleText: [String]
}

struct GenerationFailureDTO: Codable, Hashable {
    let marketplace: String
    let reason: String
}

struct GenerateRequest: Encodable {
    let marketplaces: [String]
    let scriptCount: Int
}

struct GenerateResultDTO: Codable, Identifiable {
    var id: String { productId }

    let productId: String
    let facts: ProductFactsDTO
    let assets: [GeneratedAssetDTO]
    /// Partial success is normal: one marketplace can fail while others land.
    let failures: [GenerationFailureDTO]
    let creditsCharged: Int
    let balanceAfter: Int
}

struct CreditQuoteDTO: Decodable {
    let credits: Int
}

struct CreditBalanceDTO: Decodable {
    let balance: Int
    /// True when the summed ledger disagrees with the recorded balance.
    let drifted: Bool
}

/// A stored asset, as `GET /api/products/:id/assets` returns it.
///
/// Deliberately a separate type from `GeneratedAssetDTO`: the stored row keeps
/// its database id and its status as a plain string, so a status written by an
/// older build cannot fail to decode and hide a whole listing.
struct StoredAssetDTO: Codable, Hashable, Identifiable {
    let id: String
    let type: String
    let marketplace: String
    let content: String
    let status: String
    let violations: [ViolationDTO]

    var compliance: ComplianceStatus { ComplianceStatus(rawValue: status) ?? .warn }
}

struct ListingProductDTO: Codable, Hashable {
    let id: String
    let name: String
    let category: String?
}

struct ListingAssetsDTO: Decodable {
    let product: ListingProductDTO
    let assets: [StoredAssetDTO]
}
