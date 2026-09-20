//
//  StudioStore.swift
//  ListingForge
//
//  Studio backdrops: the seller picks one style and how many angles, and the
//  server composites the product cutout onto that many generated variations.
//  The product itself is never redrawn — only the background is generated.
//

import Foundation
import Observation

struct StudioScene: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let useCase: String
    let aspect: String
}

struct StudioImage: Decodable, Identifiable, Hashable {
    let sceneId: String
    let index: Int
    let assetId: String
    let url: String?
    var id: String { assetId }
}

private struct StudioCatalogResponse: Decodable {
    let creditsPerImage: Int
    let catalog: [String: [StudioScene]]
    let images: [StudioImage]
}

private struct StudioGenerateResponse: Decodable {
    let images: [StudioImage]
    let creditsCharged: Int
    let balanceAfter: Int
}

@MainActor
@Observable
final class StudioStore {
    private(set) var creditsPerImage = 5
    private(set) var catalog: [Industry: [StudioScene]] = [:]
    /// The most recent set of generated variations, in order.
    private(set) var results: [StudioImage] = []
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var errorMessage: String?

    private let api: APIClient
    private let productID: String

    init(api: APIClient, productID: String) {
        self.api = api
        self.productID = productID
    }

    func scenes(for industry: Industry) -> [StudioScene] { catalog[industry] ?? [] }

    func load(token: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response: StudioCatalogResponse = try await api.get("api/products/\(productID)/studio", token: token)
            creditsPerImage = response.creditsPerImage
            catalog = Dictionary(uniqueKeysWithValues: response.catalog.compactMap { key, value in
                Industry(rawValue: key).map { ($0, value) }
            })
            results = response.images.filter { $0.url != nil }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generate(industry: Industry, sceneID: String, count: Int, token: String) async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        struct Request: Encodable { let industry: String; let sceneId: String; let count: Int }
        do {
            let response: StudioGenerateResponse = try await api.post(
                "api/products/\(productID)/studio",
                body: Request(industry: industry.rawValue, sceneId: sceneID, count: count),
                token: token)
            results = response.images.filter { $0.url != nil }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
