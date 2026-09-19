//
//  StudioStore.swift
//  ListingForge
//
//  Studio backdrops: send the product cutout to the server, which composites it
//  onto a generated studio scene (per-industry) and returns a signed image URL.
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
    private(set) var creditsPerImage = 0
    private(set) var catalog: [Industry: [StudioScene]] = [:]
    /// Signed image URL for each scene already generated, keyed by scene id.
    private(set) var images: [String: URL] = [:]
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
            merge(response.images)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generate(industry: Industry, sceneIDs: [String], token: String) async {
        guard !isGenerating, !sceneIDs.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        struct Request: Encodable { let industry: String; let sceneIds: [String] }
        do {
            let response: StudioGenerateResponse = try await api.post(
                "api/products/\(productID)/studio",
                body: Request(industry: industry.rawValue, sceneIds: sceneIDs),
                token: token)
            merge(response.images)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func merge(_ incoming: [StudioImage]) {
        for image in incoming {
            if let raw = image.url, let url = URL(string: raw) {
                images[image.sceneId] = url
            }
        }
    }
}
