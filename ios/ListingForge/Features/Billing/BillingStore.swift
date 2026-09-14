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
    var message: String?
    private let api: APIClient
    private var token: String?
    private var userID: UUID?
    @ObservationIgnored private var listener: Task<Void, Never>?
    private var inFlight: Set<UInt64> = []

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
        message = nil
        Task { [weak self] in await self?.refreshPurchases() }
    }

    func refresh() async {
        guard let token else { return }
        do {
            let result: BillingStatus = try await api.get("api/billing", token: token)
            guard self.token == token else { return }
            status = result
            let catalog = try await StoreKit.Product.products(for: result.subscriptionProductIDs + [result.topupProductID])
            guard self.token == token else { return }
            products = catalog.sorted { $0.price < $1.price }
            if catalog.isEmpty { message = "Plans are unavailable from the App Store. Try again later." }
        } catch {
            guard self.token == token else { return }
            message = error.localizedDescription
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
            if message == nil { message = "Purchases refreshed. Your balance is confirmed by the server." }
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
            message = "A purchase belongs to another ListingForge account. Sign into that account to restore it."
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
