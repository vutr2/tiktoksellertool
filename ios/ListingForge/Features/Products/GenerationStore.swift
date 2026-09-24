//
//  GenerationStore.swift
//  ListingForge
//
//  Drives marketplace selection and generation (design steps 3 and 4).
//
//  Credit arithmetic is the server's job — this only displays what the server
//  quotes and what it reports as charged. Computing cost on the device would be
//  the client-side entitlement SPEC §12 rules out.
//

import Foundation
import Observation

@MainActor
@Observable
final class GenerationStore {

    private(set) var balance: Int?
    private(set) var quotedCredits: Int?
    private(set) var isGenerating = false
    private(set) var isQuoting = false
    private(set) var listingLoadWarning: String?
    private(set) var result: GenerateResultDTO?
    var errorMessage: String?
    /// Set when the seller cannot afford the work — the app shows the paywall
    /// sheet here, not an error (SPEC §6).
    private(set) var needsMoreCredits = false

    private let api: APIClient
    private let snapshots: ListingSnapshotCache
    private let cacheDirectory: URL?
    private var pendingRequests: [String: PendingGeneration] = [:]
    private var isInvalidated = false
    /// Incremented per request so a slow response cannot overwrite a newer one.
    private var quoteToken = 0
    private var generateToken = 0

    init(api: APIClient, cacheDirectory: URL? = nil) {
        self.api = api
        self.snapshots = ListingSnapshotCache(directory: cacheDirectory)
        self.cacheDirectory = cacheDirectory
    }

    struct PendingGeneration: Codable {
        let requestId: UUID
        let productID: String
        let marketplaces: [String]
        let scriptCount: Int
    }

    func pendingRequest(productID: String) -> PendingGeneration? {
        guard !isInvalidated else { return nil }
        if let pending = pendingRequests[productID] { return pending }
        guard let url = requestURL(productID), let data = try? Data(contentsOf: url),
              let pending = try? JSONDecoder().decode(PendingGeneration.self, from: data),
              pending.productID == productID else { return nil }
        return pending
    }

    private func requestURL(_ productID: String) -> URL? {
        cacheDirectory?.appendingPathComponent("generation-\(StableAssetIdentity.make([productID])).json")
    }

    private func remember(_ request: PendingGeneration) throws {
        pendingRequests[request.productID] = request
        guard let url = requestURL(request.productID) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func forget(_ productID: String) {
        pendingRequests[productID] = nil
        if let url = requestURL(productID) { try? FileManager.default.removeItem(at: url) }
    }

    func removeProduct(_ productID: String) throws {
        forget(productID)
        try snapshots.remove(productID: productID)
        if result?.productId == productID { result = nil }
    }

    func invalidate() {
        isInvalidated = true
        quoteToken += 1
        generateToken += 1
        result = nil
        balance = nil
        quotedCredits = nil
        errorMessage = nil
        listingLoadWarning = nil
        pendingRequests = [:]
    }

    func loadBalance(token: String) async {
        guard !isInvalidated else { return }
        do {
            let report: CreditBalanceDTO = try await api.get("api/credits", token: token)
            guard !isInvalidated else { return }
            balance = report.balance
        } catch {
            guard !isInvalidated else { return }
            // A missing balance must not block the screen; the server refuses
            // an unaffordable request anyway.
            balance = nil
        }
    }

    func quote(productID: String, marketplaces: [String], scriptCount: Int, token: String) async {
        guard !isInvalidated else { return }
        quoteToken += 1
        let issued = quoteToken
        quotedCredits = nil
        isQuoting = true
        defer { if issued == quoteToken { isQuoting = false } }

        guard !marketplaces.isEmpty else {
            quotedCredits = 0
            return
        }
        let query = "marketplaces=\(marketplaces.joined(separator: ","))&scriptCount=\(scriptCount)"
        do {
            let quote: CreditQuoteDTO = try await api.get(
                "api/products/\(productID)/generate?\(query)", token: token)
            // Changing the selection quickly can land responses out of order;
            // an older quote must not overwrite the current selection's price.
            guard issued == quoteToken, !Task.isCancelled else { return }
            quotedCredits = quote.credits
        } catch {
            guard issued == quoteToken else { return }
            quotedCredits = nil
        }
    }

    /// Returns this request's result, or nil when it failed.
    ///
    /// The value is returned rather than read back from `result` afterwards: a
    /// caller that inspects shared state after `await` would see the *previous*
    /// successful run and treat a failed request as a success.
    @discardableResult
    func generate(productID: String, marketplaces: [String], scriptCount: Int, token: String) async -> GenerateResultDTO? {
        guard !isGenerating, !isInvalidated else { return nil }
        let pending = pendingRequest(productID: productID) ?? PendingGeneration(
            requestId: UUID(), productID: productID, marketplaces: marketplaces.sorted(), scriptCount: scriptCount)
        guard pending.marketplaces == marketplaces.sorted(), pending.scriptCount == scriptCount else {
            errorMessage = "Check your earlier generation before changing this selection."
            return nil
        }
        do { try remember(pending) }
        catch {
            errorMessage = "Your request could not be saved on this device. Free some space and try again."
            return nil
        }
        isGenerating = true
        errorMessage = nil
        needsMoreCredits = false
        // Clearing first means a failure can never leave an earlier success on
        // screen.
        result = nil
        generateToken += 1
        let issued = generateToken
        defer { isGenerating = false }

        do {
            let generated: GenerateResultDTO = try await api.post(
                "api/products/\(productID)/generate",
                body: GenerateRequest(marketplaces: pending.marketplaces, scriptCount: pending.scriptCount, requestId: pending.requestId),
                token: token
            )
            guard issued == generateToken else { return nil }
            forget(productID)
            result = generated
            balance = generated.balanceAfter
            do {
                try snapshots.save(.generated(generated, productName: generated.facts.suggestedName))
            } catch {
                listingLoadWarning = "Your listing is saved online, but its offline copy could not be saved."
            }
            return generated
        } catch let APIError.http(status, message) {
            guard issued == generateToken else { return nil }
            if [400, 401, 402, 403, 404].contains(status) { forget(productID) }
            if status == 409 || status >= 500 {
                if let recovered = await recover(pending, token: token, issued: issued) { return recovered }
            }
            // 402 is "buy more credits", not a failure to explain away.
            needsMoreCredits = status == 402
            errorMessage = message ?? "Generation failed."
            return nil
        } catch {
            guard issued == generateToken else { return nil }
            if let recovered = await recover(pending, token: token, issued: issued) { return recovered }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private func recover(_ pending: PendingGeneration, token: String, issued: Int) async -> GenerateResultDTO? {
        guard !isInvalidated, !Task.isCancelled else { return nil }
        do {
            let recovered: GenerateResultDTO = try await api.get(
                "api/products/\(pending.productID)/generate?requestId=\(pending.requestId.uuidString)", token: token)
            guard issued == generateToken, !isInvalidated else { return nil }
            result = recovered
            balance = recovered.balanceAfter
            forget(pending.productID)
            do { try snapshots.save(.generated(recovered, productName: recovered.facts.suggestedName)) }
            catch { listingLoadWarning = "Your listing is saved online, but its offline copy could not be saved." }
            return recovered
        } catch { return nil }
    }

    /// Reopening a saved draft first checks its existing request. Never start a
    /// new paid generation merely because the user opened the screen again.
    func recoverPending(productID: String, token: String) async -> GenerateResultDTO? {
        guard !isInvalidated, !isGenerating, let pending = pendingRequest(productID: productID) else { return nil }
        return await recover(pending, token: token, issued: generateToken)
    }

    /// Loads a listing that was generated earlier, so it can be reopened after
    /// the app was closed. Credits were charged for this work; it has to still
    /// be reachable (Guideline 2.1).
    func loadAssets(productID: String, token: String, savedProduct: ListingProductDTO? = nil) async -> ListingAssetsDTO? {
        guard !isInvalidated else { return nil }
        errorMessage = nil
        listingLoadWarning = nil
        do {
            let listing: ListingAssetsDTO = try await api.get(
                "api/products/\(productID)/assets", token: token)
            guard !isInvalidated, !Task.isCancelled else { return nil }
            do { try snapshots.save(listing) }
            catch { listingLoadWarning = "This listing is available online, but its offline copy could not be saved." }
            return listing
        } catch {
            guard !isInvalidated, !Task.isCancelled else { return nil }
            if case APIError.http(let status, _) = error, (400..<500).contains(status) {
                if status == 403 || status == 404 { try? snapshots.remove(productID: productID) }
                errorMessage = error.localizedDescription
                return nil
            }
            if let cached = cachedListing(productID: productID) {
                listingLoadWarning = "Showing your saved offline copy. Connect to refresh this listing."
                return cached
            }
            if let savedProduct, savedProduct.id == productID {
                // A product can have paid Studio photos before its first text
                // listing exists. Keep the gallery reachable while offline.
                listingLoadWarning = "Connect to load listing content. You can still open Studio photos saved on this device."
                return ListingAssetsDTO(product: savedProduct, assets: [])
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func cachedListing(productID: String) -> ListingAssetsDTO? {
        guard !isInvalidated else { return nil }
        return try? snapshots.load(productID: productID)
    }

    /// Assets for one marketplace, for the Review screen's chips.
    func assets(for marketplace: String) -> [GeneratedAssetDTO] {
        result?.assets.filter { $0.marketplace == marketplace } ?? []
    }

    /// Worst status across a marketplace, which is what its chip shows.
    ///
    /// A marketplace that produced nothing is a failure, not a pass — reporting
    /// green for a marketplace that errored is the worst possible answer.
    func status(for marketplace: String) -> ComplianceStatus {
        if result?.failures.contains(where: { $0.marketplace == marketplace }) == true { return .fail }

        let statuses = assets(for: marketplace).map(\.status)
        if statuses.isEmpty { return .fail }
        if statuses.contains(.fail) { return .fail }
        if statuses.contains(.warn) { return .warn }
        return .pass
    }
}
