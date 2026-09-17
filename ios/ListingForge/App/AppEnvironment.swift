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
    private(set) var captureDraft = CaptureDraftStore()
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
            self.captureDraft.invalidate()
            self.aiConsent.revoke()
            try self.accountCache?.erase()
            try AccountCache.removeLegacyUnownedCache()
        }
        #if DEBUG
        startDemoIfNeeded()
        #endif
    }

    #if DEBUG
    /// Seeds a signed-in session and sample content for screenshots. See DemoMode.
    private func startDemoIfNeeded() {
        guard DemoMode.isActive else { return }
        rules.seedDemo(DemoData.marketplaces)
        // Setting the session synchronously rebuilds `products` and creates the
        // account cache, so seed the freshly built store afterwards.
        auth.startDemoSession(DemoData.user)
        products.seedDemo(DemoData.products)
        billing.enableDemo()
        Task { await billing.seedDemo(status: DemoData.billingStatus) }
    }
    #endif

    func retryAccountCache() {
        if case let .signedIn(user) = auth.state { useAccount(user) }
    }

    private func useAccount(_ user: UserDTO?) {
        billing.useAccount(userID: user?.id, token: auth.token)
        guard user?.id != accountCache?.userID || cacheError != nil else { return }
        products.invalidate()
        generation.invalidate()
        captureDraft.invalidate()
        accountCache = nil
        cacheError = nil
        aiConsent.useAccount(user?.id)
        products = ProductStore(api: api)
        generation = GenerationStore(api: api)
        captureDraft = CaptureDraftStore()
        guard let user else { return }
        do {
            try AccountCache.removeLegacyUnownedCache()
            let cache = try AccountCache(userID: user.id)
            let directory = cache.directory.appendingPathComponent("listings", isDirectory: true)
            products = ProductStore(api: api, cacheDirectory: directory)
            generation = GenerationStore(api: api, cacheDirectory: directory)
            captureDraft = CaptureDraftStore(directory: directory)
            accountCache = cache
        } catch {
            cacheError = "Your local product cache could not be opened. Try again or sign out."
        }
    }
}
