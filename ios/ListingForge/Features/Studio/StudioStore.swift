//
//  StudioStore.swift
//  ListingForge
//
//  Generate variations one at a time. Saved results are reloaded before retry
//  so a partially completed batch does not request its successful images again.
//

import Foundation
import Observation

struct StudioScene: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let useCase: String
    let aspect: String
}

struct StudioImage: Codable, Identifiable, Hashable {
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

private struct StudioSnapshot: Codable {
    let creditsPerImage: Int
    let catalog: [String: [StudioScene]]
    let images: [StudioImage]
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
    private(set) var cacheWarning: String?
    var errorMessage: String?

    private let api: APIClient
    let productID: String
    private let directory: URL?
    private let imageSession: URLSession
    private var isInvalidated = false

    init(api: APIClient, productID: String, cacheDirectory: URL? = nil, imageSession: URLSession = .shared) {
        self.api = api
        self.productID = productID
        self.imageSession = imageSession
        directory = cacheDirectory?.appendingPathComponent(StableAssetIdentity.make([productID.lowercased()]), isDirectory: true)
        if let file = directory?.appendingPathComponent("photos.json"),
           let data = try? Data(contentsOf: file),
           let snapshot = try? JSONDecoder().decode(StudioSnapshot.self, from: data) {
            creditsPerImage = snapshot.creditsPerImage
            catalog = Self.catalog(from: snapshot.catalog)
            results = snapshot.images
        }
    }

    func erase() throws {
        invalidate()
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func invalidate() { isInvalidated = true; results = []; catalog = [:] }

    func scenes(for industry: Industry) -> [StudioScene] { catalog[industry] ?? [] }

    func uncachedCount(sceneID: String?, count: Int) -> Int {
        guard let sceneID else { return count }
        return (0..<count).filter { index in
            !results.contains { $0.sceneId == sceneID && $0.index == index }
        }.count
    }

    func load(token: String) async {
        guard !isInvalidated, !isLoading, !isGenerating else { return }
        isLoading = true
        errorMessage = nil
        balanceAfter = nil
        defer { isLoading = false }
        do {
            try await reloadSavedImages(token: token)
        } catch {
            guard !isInvalidated, !Task.isCancelled else { return }
            if case APIError.http(let status, _) = error, [401, 403, 404].contains(status) {
                results = []
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generate(industry: Industry, sceneID: String, count: Int, token: String) async {
        guard !isInvalidated, !isGenerating, !isLoading, [1, 3, 5].contains(count) else { return }
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
                guard !isInvalidated else { return }
                if results.contains(where: { $0.sceneId == sceneID && $0.index == index }) { continue }
                progressMessage = "Generating image \(index + 1) of \(count)… This may take a few minutes."
                let response: StudioGenerateResponse = try await api.post(
                    "api/products/\(productID)/studio",
                    body: Request(industry: industry.rawValue, sceneId: sceneID, count: 1, index: index),
                    token: token, timeout: 200)
                guard !isInvalidated else { return }
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
                persistSnapshot()
            }
        } catch is CancellationError {
            // Returning to Studio reloads anything the server finished saving.
        } catch let error as URLError where error.code == .cancelled {
            // Closing the screen stops the remaining paid submissions.
        } catch let error as URLError where error.code == .timedOut {
            guard !isInvalidated else { return }
            errorMessage = "Studio did not respond within 200 seconds. Completed images are saved. Try this style again later to check progress."
        } catch {
            guard !isInvalidated else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reloadSavedImages(token: String) async throws {
        let response: StudioCatalogResponse = try await api.get("api/products/\(productID)/studio", token: token)
        guard !isInvalidated else { throw CancellationError() }
        try Task.checkCancellation()
        creditsPerImage = response.creditsPerImage
        catalog = Self.catalog(from: response.catalog)
        // An unavailable signed URL does not mean a paid asset is missing.
        results = response.images
        persistSnapshot()
    }

    private static func catalog(from values: [String: [StudioScene]]) -> [Industry: [StudioScene]] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            Industry(rawValue: key).map { ($0, value) }
        })
    }

    private func persistSnapshot() {
        guard !isInvalidated, let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = StudioSnapshot(creditsPerImage: creditsPerImage,
                catalog: Dictionary(uniqueKeysWithValues: catalog.map { ($0.key.rawValue, $0.value) }), images: results)
            try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("photos.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            cacheWarning = nil
        } catch {
            cacheWarning = "Your photos are saved online, but their offline copy could not be saved."
        }
    }

    /// Saved image bytes outlive expiring signed URLs. Opening or exporting a
    /// photo never submits another image generation request.
    func imageData(for image: StudioImage) async throws -> Data {
        guard !isInvalidated else { throw CancellationError() }
        let file = directory?.appendingPathComponent(StableAssetIdentity.make([image.assetId]) + ".image")
        if let file, let data = try? Data(contentsOf: file) { return data }
        guard let raw = image.url, let url = URL(string: raw), url.scheme == "https" else {
            throw APIError.http(status: 503, message: "Refresh saved photos to load this preview.")
        }
        let (data, response) = try await imageSession.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard !isInvalidated else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true, !data.isEmpty, data.count <= 20 * 1024 * 1024 else {
            throw APIError.invalidResponse
        }
        if let file {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { cacheWarning = "This photo is saved online, but its offline copy could not be saved." }
        }
        return data
    }
}
