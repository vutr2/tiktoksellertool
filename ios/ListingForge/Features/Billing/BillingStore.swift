import Foundation
import Observation
import StoreKit

struct BillingStatus: Decodable {
    let appAccountToken: String
    let tier: String?
    let balance: Int
    let allowedMarketplaces: [String]
    let subscriptionProductIDs: [String]
    let topupProductID: String
}

/// Apple retains unfinished purchases across launches until the server confirms them.
@MainActor @Observable
final class BillingStore {
    private(set) var status: BillingStatus?
    private(set) var products: [StoreKit.Product] = []
    private(set) var isBusy = false
    private(set) var isLoadingProducts = false
    /// Whether this account can still claim the plans' introductory (free-trial)
    /// offer. Eligibility is per subscription group, so one product answers for
    /// all. The paywall only advertises the trial when this is true.
    private(set) var introOfferEligible = false
    private(set) var catalogError: String?
    var message: String?
    private let api: APIClient
    private var token: String?
    private var userID: UUID?
    @ObservationIgnored private var listener: Task<Void, Never>?
    private var inFlight: Set<UInt64> = []
    private var refreshID = UUID()
    #if DEBUG
    private var demoActive = false
    #endif

    init(api: APIClient) {
        self.api = api
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.confirm(result)
            }
        }
    }

    deinit { listener?.cancel() }

    func useAccount(userID: String?, token: String?) {
        self.userID = userID.flatMap(UUID.init(uuidString:))
        self.token = token
        status = nil
        products = []
        introOfferEligible = false
        refreshID = UUID()
        isLoadingProducts = false
        catalogError = nil
        message = nil
        Task { [weak self] in await self?.refreshPurchases() }
    }

    #if DEBUG
    /// Marks the store as demo so refresh/restore never touch the network.
    /// Set synchronously before any async work to win the race with the refresh
    /// task spawned by `useAccount`.
    func enableDemo() { demoActive = true }

    /// Seeds a plan status and loads the local StoreKit catalog for screenshots.
    func seedDemo(status: BillingStatus) async {
        demoActive = true
        self.status = status
        let catalog = (try? await StoreKit.Product.products(
            for: status.subscriptionProductIDs + [status.topupProductID])) ?? []
        products = catalog.sorted { $0.price < $1.price }
        if let subscription = products.first(where: { $0.type == .autoRenewable })?.subscription {
            introOfferEligible = await subscription.isEligibleForIntroOffer
        }
    }
    #endif

    func refresh() async {
        #if DEBUG
        if demoActive { return }
        #endif
        guard let token else { return }
        let requestID = UUID()
        refreshID = requestID
        isLoadingProducts = true
        if message == catalogError { message = nil }
        catalogError = nil
        defer {
            if refreshID == requestID { isLoadingProducts = false }
        }
        do {
            let result: BillingStatus = try await api.get("api/billing", token: token)
            guard self.token == token, refreshID == requestID else { return }
            status = result
            let catalog = try await StoreKit.Product.products(for: result.subscriptionProductIDs + [result.topupProductID])
            guard self.token == token, refreshID == requestID else { return }
            products = catalog.sorted { $0.price < $1.price }
            if catalog.isEmpty {
                catalogError = "We couldn’t load plans and prices from the App Store. Please try again later."
            }
            // Eligibility is shared across the subscription group, so any plan answers.
            if let subscription = catalog.first(where: { $0.type == .autoRenewable })?.subscription {
                let eligible = await subscription.isEligibleForIntroOffer
                guard self.token == token, refreshID == requestID else { return }
                introOfferEligible = eligible
            } else {
                introOfferEligible = false
            }
        } catch {
            guard self.token == token, refreshID == requestID else { return }
            products = []
            introOfferEligible = false
            catalogError = error.localizedDescription
        }
    }

    func purchase(_ product: StoreKit.Product) async {
        guard !isBusy, let userID, token != nil else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(userID)])
            guard self.userID == userID else { return }
            switch result {
            case .success(let result): await confirm(result)
            case .pending: message = "Your purchase is awaiting Apple approval. Credits appear after confirmation."
            case .userCancelled: break
            @unknown default: message = "Check your purchase status with Restore Purchases."
            }
        } catch {
            guard self.userID == userID else { return }
            message = error.localizedDescription
        }
    }

    func restore() async {
        guard !isBusy, let issuedToken = token else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            guard token == issuedToken else { return }
            await refreshPurchases()
            guard token == issuedToken else { return }
            if message == nil {
                message = catalogError ?? "Purchases refreshed. Your balance is confirmed by the server."
            }
        } catch {
            guard token == issuedToken else { return }
            message = error.localizedDescription
        }
    }

    private func refreshPurchases() async {
        guard let issuedToken = token else { return }
        for await result in Transaction.unfinished {
            guard token == issuedToken else { return }
            await confirm(result)
        }
        for await result in Transaction.currentEntitlements {
            guard token == issuedToken else { return }
            await confirm(result)
        }
        guard token == issuedToken else { return }
        await refresh()
    }

    private func confirm(_ result: VerificationResult<Transaction>) async {
        guard let token, let userID else { return }
        guard case .verified(let transaction) = result else {
            message = "Apple could not verify this purchase. Try Restore Purchases."
            return
        }
        guard transaction.appAccountToken == userID else {
            message = "A purchase belongs to another Listing Force account. Sign into that account to restore it."
            return
        }
        guard inFlight.insert(transaction.id).inserted else { return }
        defer { inFlight.remove(transaction.id) }
        do {
            let confirmed = try await PurchaseConfirmation(api: api).confirm(
                signedTransaction: result.jwsRepresentation, token: token
            ) { await transaction.finish() }
            guard self.token == token else { return }
            status = confirmed
        } catch {
            guard self.token == token else { return }
            message = "Purchase confirmation is pending. Retry Restore Purchases. " + error.localizedDescription
        }
    }
}

/// Keeps fulfillment ordering explicit: a failed acknowledgment leaves Apple’s transaction unfinished.
struct PurchaseConfirmation {
    let api: APIClient

    func confirm(signedTransaction: String, token: String,
                 finish: () async -> Void) async throws -> BillingStatus {
        struct Request: Encodable { let signedTransaction: String }
        let status: BillingStatus = try await api.post("api/billing",
            body: Request(signedTransaction: signedTransaction), token: token)
        await finish()
        return status
    }
}
