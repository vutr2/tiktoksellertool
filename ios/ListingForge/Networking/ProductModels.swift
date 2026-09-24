//
//  ProductModels.swift
//  ListingForge
//
//  Mirrors the shapes in api/src/lib/products.ts. A rename on either side
//  should break the tests in ProductStoreTests, not a seller's upload.
//

import Foundation

/// What `POST /api/products` accepts.
struct CreateProductRequest: Encodable {
    let name: String
    let category: String?
    let keyFeatures: [String]
    /// Base64 PNG. The server rejects anything without a PNG signature, because
    /// only PNG carries the alpha the compositing step needs (SPEC §4.1/§8).
    let cutoutPngBase64: String?
}

/// What the server returns for a product.
struct ProductDTO: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String?
    /// Storage path, not a URL — the bucket is private and links are signed.
    let cutoutPath: String?
    let createdAt: String
    var isHidden: Bool? = nil
    var deletionPending: Bool? = nil
}

struct ProductListResponse: Decodable {
    let products: [ProductDTO]
    let hasMore: Bool?
}
