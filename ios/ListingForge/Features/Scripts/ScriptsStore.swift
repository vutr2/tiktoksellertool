//
//  ScriptsStore.swift
//  ListingForge
//
//  Loads and generates the product's 30-second video scripts. Each script is a
//  `ScriptShape` (hook + timed beats) rendered by ScriptPlayerView.
//

import Foundation
import Observation

@MainActor
@Observable
final class ScriptsStore {
    private(set) var scripts: [ScriptShape] = []
    private(set) var isLoading = false
    private(set) var isGenerating = false
    var errorMessage: String?

    private let api: APIClient
    private let productID: String

    init(api: APIClient, productID: String) {
        self.api = api
        self.productID = productID
    }

    private struct ListResponse: Decodable { let scripts: [ScriptShape] }
    private struct GenerateResponse: Decodable {
        let scripts: [ScriptShape]
        let creditsCharged: Int
        let balanceAfter: Int
    }

    func load(token: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response: ListResponse = try await api.get("api/products/\(productID)/scripts", token: token)
            scripts = response.scripts
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generate(count: Int = 5, language: AppLanguage, token: String) async {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        struct Request: Encodable { let count: Int; let language: AppLanguage }
        do {
            let response: GenerateResponse = try await api.post(
                "api/products/\(productID)/scripts", body: Request(count: count, language: language), token: token)
            scripts = response.scripts
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
