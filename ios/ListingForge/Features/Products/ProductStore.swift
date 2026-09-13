//
//  ProductStore.swift
//  ListingForge
//
//  Creating and listing products. The server owns the record; SwiftData only
//  mirrors it for offline viewing (SPEC §9 — "the server wins on every
//  conflict"), so nothing here writes to the cache. The caller does that after
//  a successful create.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProductStore {

    private(set) var products: [ProductDTO] = []
    private(set) var isSaving = false
    private(set) var isLoading = false
    var errorMessage: String?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Sends the product and its cutout. Returns nil when it failed, with
    /// `errorMessage` already set for the UI.
    func create(
        name: String,
        category: String?,
        keyFeatures: [String],
        cutoutPNG: Data?,
        token: String
    ) async -> ProductDTO? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let request = CreateProductRequest(
            name: name,
            category: category,
            keyFeatures: keyFeatures,
            cutoutPngBase64: cutoutPNG?.base64EncodedString()
        )

        do {
            let product: ProductDTO = try await api.post("api/products", body: request, token: token)
            // Newest first, matching what the list endpoint returns.
            products.insert(product, at: 0)
            return product
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func load(token: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response: ProductListResponse = try await api.get("api/products", token: token)
            products = response.products
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Cache mirroring

enum ProductCacheMapper {
    /// Builds the SwiftData mirror of a server product.
    ///
    /// Kept separate from the store so the mapping is testable without a model
    /// container, and so it stays obvious that the cache is derived — never the
    /// origin — of a product.
    static func cached(from dto: ProductDTO) -> CachedProduct {
        CachedProduct(
            serverID: dto.id,
            name: dto.name,
            category: dto.category ?? "",
            cutoutURL: dto.cutoutPath,
            updatedAt: iso8601(dto.createdAt) ?? .now
        )
    }

    /// The server sends fractional seconds; the plain ISO8601 parser rejects
    /// those, which would silently date every cached product to "now".
    static func iso8601(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
