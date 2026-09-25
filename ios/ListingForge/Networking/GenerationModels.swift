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
    let language: AppLanguage
    var requestId: UUID = UUID()
}

struct GenerateResultDTO: Codable, Identifiable {
    var id: String { productId }

    let productId: String
    /// Absent on generations that completed before the field existed. Those
    /// rows are stored in Postgres and replayed verbatim by the recovery path,
    /// so a required field here would break recovering an in-flight request
    /// across the deploy. They were all English.
    private let language: AppLanguage?
    var outputLanguage: AppLanguage { language ?? .en }
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
    /// What this one asset is written in. A product accumulates assets across
    /// generations, so the newest run's language is not a fact about the older
    /// copy beside it. Absent means the server could not trace this row to a
    /// stored result — unknown, which is not the same as English.
    let language: AppLanguage?

    var compliance: ComplianceStatus { ComplianceStatus(rawValue: status) ?? .warn }

    init(id: String, type: String, marketplace: String, content: String,
         status: String, violations: [ViolationDTO], language: AppLanguage? = nil) {
        self.id = id
        self.type = type
        self.marketplace = marketplace
        self.content = content
        self.status = status
        self.violations = violations
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        marketplace = try values.decode(String.self, forKey: .marketplace)
        content = try values.decode(String.self, forKey: .content)
        status = try values.decode(String.self, forKey: .status)
        violations = try values.decodeIfPresent([ViolationDTO].self, forKey: .violations) ?? []
        // Snapshots cached before per-asset provenance existed carry no value.
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language)
    }
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
    /// Absent on listings cached before the app had a second language. Those
    /// were English, so the fallback is a fact rather than a guess — and the
    /// server needs it to know whether its content checks could read the copy.
    private let language: AppLanguage?
    var outputLanguage: AppLanguage { language ?? .en }

    init(product: ListingProductDTO, assets: [StoredAssetDTO],
         failures: [GenerationFailureDTO] = [], language: AppLanguage? = nil) {
        self.product = product
        self.assets = assets
        self.failures = failures
        self.language = language
    }

    private enum CodingKeys: String, CodingKey { case product, assets, failures, language }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        product = try values.decode(ListingProductDTO.self, forKey: .product)
        assets = try values.decode([StoredAssetDTO].self, forKey: .assets)
        failures = try values.decodeIfPresent([GenerationFailureDTO].self, forKey: .failures) ?? []
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language)
    }

    static func generated(_ result: GenerateResultDTO, productName: String) -> Self {
        Self(
            product: ListingProductDTO(id: result.productId, name: productName,
                                       category: result.facts.suggestedCategory),
            assets: result.assets.enumerated().map { index, asset in
                // Everything in one result was written in that result's
                // language, so provenance is known here without asking anyone.
                StoredAssetDTO(id: asset.serverID ?? "\(asset.id)-\(index)", type: asset.type,
                               marketplace: asset.marketplace, content: asset.content,
                               status: asset.status.rawValue, violations: asset.violations,
                               language: result.outputLanguage)
            },
            failures: result.failures,
            language: result.outputLanguage
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
