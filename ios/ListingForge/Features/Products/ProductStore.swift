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
import CryptoKit

@MainActor
@Observable
final class ProductStore {

    private(set) var products: [ProductDTO] = []
    private(set) var isSaving = false
    private(set) var isLoading = false
    private(set) var isOffline = false
    private(set) var cacheWarning: String?
    var errorMessage: String?

    private let api: APIClient
    private let cacheDirectory: URL?
    private var isInvalidated = false
    private var loadID = UUID()
    #if DEBUG
    private var demoActive = false
    #endif

    init(api: APIClient, cacheDirectory: URL? = nil) {
        self.api = api
        self.cacheDirectory = cacheDirectory
        if let url = cacheDirectory?.appendingPathComponent("products.json"),
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([ProductDTO].self, from: data) {
            products = saved
            isOffline = true
        }
    }

    func invalidate() {
        isInvalidated = true
        loadID = UUID()
        products = []
        errorMessage = nil
    }

    private func cacheProducts() {
        guard !isInvalidated, let cacheDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(products).write(to: cacheDirectory.appendingPathComponent("products.json"),
                                                     options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            cacheWarning = nil
        } catch { cacheWarning = "Your products are saved online, but their offline copy could not be saved." }
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
        guard !isInvalidated, !isSaving else { return nil }
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
            guard !isInvalidated else { return nil }
            // Newest first, matching what the list endpoint returns.
            products.insert(product, at: 0)
            cacheProducts()
            return product
        } catch {
            guard !isInvalidated else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    #if DEBUG
    /// Seeds sample products for screenshots and stops `load()` from hitting the network.
    func seedDemo(_ products: [ProductDTO]) {
        demoActive = true
        self.products = products
    }
    #endif

    func load(token: String) async {
        #if DEBUG
        if demoActive { return }
        #endif
        guard !isInvalidated else { return }
        let issued = UUID()
        loadID = issued
        isLoading = true
        errorMessage = nil
        defer { if issued == loadID { isLoading = false } }

        do {
            let response: ProductListResponse = try await api.get("api/products", token: token)
            guard !isInvalidated, issued == loadID, !Task.isCancelled else { return }
            products = response.products
            isOffline = false
            cacheProducts()
        } catch {
            guard !isInvalidated, issued == loadID, !Task.isCancelled else { return }
            isOffline = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The draft UUID and image hashes keep retries tied to the same product.
    /// Each raw PNG fits the API body limit without base64 expansion.
    func create(draftID: UUID, name: String, category: String?, keyFeatures: [String],
                cutouts: [Data], industry: Industry? = nil, token: String) async -> ProductDTO? {
        guard !isInvalidated, !isSaving else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        struct DraftRequest: Encodable {
            let productId: UUID
            let name: String
            let category: String?
            let keyFeatures: [String]
            let cutoutCount: Int
            let cutoutSHA256: [String]
            let industry: String?
        }
        do {
            let request = DraftRequest(productId: draftID, name: name, category: category,
                keyFeatures: keyFeatures, cutoutCount: cutouts.count,
                cutoutSHA256: cutouts.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
                industry: industry?.rawValue)
            let draft: ProductDTO = try await api.post("api/products", body: request, token: token)
            for (index, bytes) in cutouts.enumerated() {
                guard !isInvalidated else { return nil }
                try await api.putData("api/products/\(draft.id)/cutouts/\(index)",
                                      data: bytes, contentType: "image/png", token: token)
            }
            guard !isInvalidated else { return nil }
            let product: ProductDTO = try await api.post("api/products/\(draft.id)/complete", token: token)
            guard !isInvalidated else { return nil }
            products.removeAll { $0.id == product.id }
            products.insert(product, at: 0)
            cacheProducts()
            return product
        } catch {
            guard !isInvalidated else { return nil }
            errorMessage = error.localizedDescription
            return nil
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
