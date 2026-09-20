//
//  StudioStore.swift
//  ListingForge
//
//  Generate variations one at a time. Saved results are reloaded before retry
//  so a partially completed batch does not request its successful images again.
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
    private(set) var progressMessage: String?
    private(set) var balanceAfter: Int?
    var errorMessage: String?

    private let api: APIClient
    private let productID: String

    init(api: APIClient, productID: String) {
        self.api = api
        self.productID = productID
    }

    func scenes(for industry: Industry) -> [StudioScene] { catalog[industry] ?? [] }

    func uncachedCount(sceneID: String?, count: Int) -> Int {
        guard let sceneID else { return count }
        return (0..<count).filter { index in
            !results.contains { $0.sceneId == sceneID && $0.index == index }
        }.count
    }

    func load(token: String) async {
        guard !isLoading, !isGenerating else { return }
        isLoading = true
        errorMessage = nil
        balanceAfter = nil
        defer { isLoading = false }
        do {
            try await reloadSavedImages(token: token)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generate(industry: Industry, sceneID: String, count: Int, token: String) async {
        guard !isGenerating, !isLoading, [1, 3, 5].contains(count) else { return }
        isGenerating = true
        errorMessage = nil
        balanceAfter = nil
        progressMessage = "Checking saved studio shots…"
        defer { isGenerating = false; progressMessage = nil }
        struct Request: Encodable { let industry: String; let sceneId: String; let count: Int; let index: Int }
        do {
            // Also recovers output saved after a previous response was lost.
            // The server is the durable cache and issues fresh preview URLs.
            try await reloadSavedImages(token: token)
            for index in 0..<count {
                try Task.checkCancellation()
                if results.contains(where: { $0.sceneId == sceneID && $0.index == index }) { continue }
                progressMessage = "Generating image \(index + 1) of \(count)… This may take a few minutes."
                let response: StudioGenerateResponse = try await api.post(
                    "api/products/\(productID)/studio",
                    body: Request(industry: industry.rawValue, sceneId: sceneID, count: 1, index: index),
                    token: token, timeout: 200)
                // An older backend ignores `index` and returns angle zero.
                // Stop here instead of presenting a repeated image as a batch.
                guard response.images.contains(where: { $0.sceneId == sceneID && $0.index == index && $0.url != nil }) else {
                    throw APIError.http(status: 409, message: "Studio returned a different variation. The server needs to be updated before continuing this batch.")
                }
                for image in response.images where image.url != nil {
                    results.removeAll { $0.id == image.id }
                    results.append(image)
                }
                balanceAfter = response.balanceAfter
            }
        } catch is CancellationError {
            // Returning to Studio reloads anything the server finished saving.
        } catch let error as URLError where error.code == .cancelled {
            // Closing the screen stops the remaining paid submissions.
        } catch let error as URLError where error.code == .timedOut {
            errorMessage = "Studio did not respond within 200 seconds. Completed images are saved. Try this style again later to check progress."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reloadSavedImages(token: String) async throws {
        let response: StudioCatalogResponse = try await api.get("api/products/\(productID)/studio", token: token)
        creditsPerImage = response.creditsPerImage
        catalog = Dictionary(uniqueKeysWithValues: response.catalog.compactMap { key, value in
            Industry(rawValue: key).map { ($0, value) }
        })
        results = response.images.filter { $0.url != nil }
    }
}
