//
//  ProductStore.swift
//  ListingForge
//
//  Creating and listing products. The server owns the record; SwiftData only
//  mirrors it for offline viewing. Account-scoped snapshots keep visibility
//  and confirmed deletions consistent when the device is offline.
//

import Foundation
import Observation
import CryptoKit

@MainActor
@Observable
final class ProductStore {

    private(set) var products: [ProductDTO] = []
    private(set) var isUpdating = false
    private(set) var updateProgress: String?
    private(set) var updateError: String?
    private(set) var deletedIDs: Set<String> = []
    private(set) var thumbnailReloadID = UUID()
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
        if let file = cacheDirectory?.appendingPathComponent("deleted-products.json"),
           let bytes = try? Data(contentsOf: file),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: bytes) { deletedIDs = ids }
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
        deletedIDs = []
        self.products = products
    }
    #endif

    func load(token: String) async {
        #if DEBUG
        if demoActive { return }
        #endif
        guard !isInvalidated, !isUpdating else { return }
        thumbnailReloadID = UUID()
        let issued = UUID()
        loadID = issued
        isLoading = true
        errorMessage = nil
        defer { if issued == loadID { isLoading = false } }

        do {
            var fetched: [ProductDTO] = []
            var seen: Set<String> = []
            var page = 0
            while true {
                let path = page == 0 ? "api/products" : "api/products?page=\(page)"
                let response: ProductListResponse = try await api.get(path, token: token)
                guard !isInvalidated, issued == loadID, !Task.isCancelled else { return }
                fetched.append(contentsOf: response.products.filter { seen.insert($0.id).inserted })
                guard response.hasMore == true, !response.products.isEmpty else { break }
                page += 1
            }
            products = fetched
            isOffline = false
            cacheProducts()
        } catch {
            guard !isInvalidated, issued == loadID, !Task.isCancelled else { return }
            isOffline = true
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    enum LibraryAction: Equatable { case delete, hide, unhide }

    /// Only confirmed successes leave the grid; failed items remain selected.
    func update(_ ids: Set<String>, action: LibraryAction, token: String) async -> Set<String> {
        guard !isInvalidated, !isUpdating else { return [] }
        isUpdating = true
        loadID = UUID() // Discard a list response issued before the mutation.
        isLoading = false
        updateError = nil
        defer { isUpdating = false; updateProgress = nil }
        var succeeded: Set<String> = []
        var failures: [String] = []
        for (index, id) in ids.sorted().enumerated() {
            guard !isInvalidated, !Task.isCancelled else { break }
            updateProgress = "Updating \(index + 1) of \(ids.count)…"
            do {
                try await performUpdate(id, action: action, token: token)
                guard !isInvalidated else { break }
                if action == .delete {
                    deletedIDs.insert(id)
                    products.removeAll { $0.id == id }
                    if let file = thumbnailFile(id) { try? FileManager.default.removeItem(at: file) }
                } else if let item = products.firstIndex(where: { $0.id == id }) {
                    products[item].isHidden = action == .hide
                }
                succeeded.insert(id)
                cacheProducts()
                if let file = cacheDirectory?.appendingPathComponent("deleted-products.json") {
                    do { try JSONEncoder().encode(deletedIDs).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    catch { cacheWarning = "This device could not update its offline product cache." }
                }
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { updateError = "\(failures.count) product(s) could not be updated. " + (failures.first ?? "Try again.") }
        return succeeded
    }

    private func performUpdate(_ id: String, action: LibraryAction, token: String) async throws {
        #if DEBUG
        if demoActive { return }
        #endif
        if action == .delete {
            try await api.delete("api/products/\(id)", token: token)
        } else {
            struct Visibility: Encodable { let hidden: Bool }
            try await api.patch("api/products/\(id)", body: Visibility(hidden: action == .hide), token: token)
        }
    }

    private func thumbnailFile(_ id: String) -> URL? {
        cacheDirectory?.appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent(StableAssetIdentity.make([id]) + ".image")
    }

    func thumbnail(for id: String, token: String) async throws -> Data {
        guard !isInvalidated, !deletedIDs.contains(id) else { throw CancellationError() }
        let file = thumbnailFile(id)
        if let file, let bytes = try? Data(contentsOf: file) { return bytes }
        let bytes = try await api.imageData("api/products/\(id)/thumbnail", token: token)
        guard !isInvalidated, !deletedIDs.contains(id), !Task.isCancelled else { throw CancellationError() }
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return bytes
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
