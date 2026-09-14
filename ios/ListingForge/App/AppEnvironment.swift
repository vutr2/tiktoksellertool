//
//  AppEnvironment.swift
//  ListingForge
//
//  Root object graph. Injected via SwiftUI's Observation-based `.environment`.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let api: APIClient
    let billing: BillingStore
    let auth: AuthStore
    /// Marketplace rules served by the API and cached for the session (SPEC §7).
    let rules: RulesStore
    /// Server-owned products. SwiftData only mirrors these (SPEC §9).
    private(set) var products: ProductStore
    /// Marketplace selection and generation (design steps 3 and 4).
    private(set) var generation: GenerationStore
    let aiConsent = AIConsent()
<<<<<<< HEAD
    private(set) var captureDraft = CaptureDraftStore()
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
    private(set) var accountCache: AccountCache?
    private(set) var cacheError: String?

    init() {
        let api = APIClient(baseURL: AppConfig.apiBaseURL)
        self.api = api
        self.auth = AuthStore(api: api)
        self.billing = BillingStore(api: api)
        self.rules = RulesStore(api: api)
        self.products = ProductStore(api: api)
        self.generation = GenerationStore(api: api)
        auth.onSessionChanged = { [weak self] user in self?.useAccount(user) }
        auth.onAccountDeleted = { [weak self] in
            guard let self else { return }
            self.products.invalidate()
            self.generation.invalidate()
<<<<<<< HEAD
            self.captureDraft.invalidate()
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
            self.aiConsent.revoke()
            try self.accountCache?.erase()
            try AccountCache.removeLegacyUnownedCache()
        }
    }

    func retryAccountCache() {
        if case let .signedIn(user) = auth.state { useAccount(user) }
    }

    private func useAccount(_ user: UserDTO?) {
<<<<<<< HEAD
        billing.useAccount(userID: user?.id, token: auth.token)
        guard user?.id != accountCache?.userID || cacheError != nil else { return }
        products.invalidate()
        generation.invalidate()
        captureDraft.invalidate()
=======
        guard user?.id != accountCache?.userID || cacheError != nil else { return }
        products.invalidate()
        generation.invalidate()
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
        accountCache = nil
        cacheError = nil
        aiConsent.useAccount(user?.id)
        products = ProductStore(api: api)
        generation = GenerationStore(api: api)
<<<<<<< HEAD
        captureDraft = CaptureDraftStore()
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
        guard let user else { return }
        do {
            try AccountCache.removeLegacyUnownedCache()
            let cache = try AccountCache(userID: user.id)
            let directory = cache.directory.appendingPathComponent("listings", isDirectory: true)
            products = ProductStore(api: api, cacheDirectory: directory)
            generation = GenerationStore(api: api, cacheDirectory: directory)
<<<<<<< HEAD
            captureDraft = CaptureDraftStore(directory: directory)
=======
>>>>>>> 3ff38ea39f05dc82917017d27205ffbd96e51196
            accountCache = cache
        } catch {
            cacheError = "Your local product cache could not be opened. Try again or sign out."
        }
    }
}
