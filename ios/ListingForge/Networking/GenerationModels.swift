//
//  GenerationModels.swift
//  ListingForge
//
//  Mirrors api/src/lib/generate.ts and the rules engine's Violation shape.
//

import CryptoKit
import Foundation

/// One rule a generated asset broke. `message` is plain English and is shown
/// verbatim — the server never sends a code to the screen (SPEC §10).
struct ViolationDTO: Codable, Hashable, Identifiable {
    let code: String
    let severity: String
    let field: String
    let message: String
    let detail: String?

    var id: String { StableAssetIdentity.make([code, field, severity, message, detail ?? ""]) }
    var isFailure: Bool { severity == "fail" }
}

/// The pass / warn / fail badge in Review.
enum ComplianceStatus: String, Codable {
    case pass, warn, fail
}

struct GeneratedAssetDTO: Codable, Hashable, Identifiable {
    let serverID: String?
    let type: String
    let marketplace: String
    let content: String
    let status: ComplianceStatus
    let violations: [ViolationDTO]

    var id: String { serverID ?? StableAssetIdentity.make([marketplace, type, content]) }

    enum CodingKeys: String, CodingKey {
        case serverID = "id"
        case type, marketplace, content, status, violations
    }

    init(type: String, marketplace: String, content: String, status: ComplianceStatus,
         violations: [ViolationDTO], serverID: String? = nil) {
        self.serverID = serverID
        self.type = type
        self.marketplace = marketplace
        self.content = content
        self.status = status
        self.violations = violations
    }
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
    var requestId: UUID = UUID()
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

struct ListingAssetsDTO: Codable {
    let product: ListingProductDTO
    let assets: [StoredAssetDTO]
    let failures: [GenerationFailureDTO]

    init(product: ListingProductDTO, assets: [StoredAssetDTO], failures: [GenerationFailureDTO] = []) {
        self.product = product
        self.assets = assets
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey { case product, assets, failures }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        product = try values.decode(ListingProductDTO.self, forKey: .product)
        assets = try values.decode([StoredAssetDTO].self, forKey: .assets)
        failures = try values.decodeIfPresent([GenerationFailureDTO].self, forKey: .failures) ?? []
    }

    static func generated(_ result: GenerateResultDTO, productName: String) -> Self {
        Self(
            product: ListingProductDTO(id: result.productId, name: productName,
                                       category: result.facts.suggestedCategory),
            assets: result.assets.enumerated().map { index, asset in
                StoredAssetDTO(id: asset.serverID ?? "\(asset.id)-\(index)", type: asset.type,
                               marketplace: asset.marketplace, content: asset.content,
                               status: asset.status.rawValue, violations: asset.violations)
            },
            failures: result.failures
        )
    }
}

/// Stable across app launches, and sensitive to the entire asset rather than
/// only its opening sentence. Encoding the array also avoids delimiter clashes.
enum StableAssetIdentity {
    static func make(_ components: [String]) -> String {
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
