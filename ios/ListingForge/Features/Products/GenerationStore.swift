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
    private(set) var result: GenerateResultDTO?
    var errorMessage: String?
    /// Set when the seller cannot afford the work — the app shows the paywall
    /// sheet here, not an error (SPEC §6).
    private(set) var needsMoreCredits = false

    private let api: APIClient
    /// Incremented per request so a slow response cannot overwrite a newer one.
    private var quoteToken = 0
    private var generateToken = 0

    init(api: APIClient) {
        self.api = api
    }

    func loadBalance(token: String) async {
        do {
            let report: CreditBalanceDTO = try await api.get("api/credits", token: token)
            balance = report.balance
        } catch {
            // A missing balance must not block the screen; the server refuses
            // an unaffordable request anyway.
            balance = nil
        }
    }

    func quote(productID: String, marketplaces: [String], scriptCount: Int, token: String) async {
        quoteToken += 1
        let issued = quoteToken

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
            guard issued == quoteToken else { return }
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
        guard !isGenerating else { return nil }
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
                body: GenerateRequest(marketplaces: marketplaces, scriptCount: scriptCount),
                token: token
            )
            guard issued == generateToken else { return nil }
            result = generated
            balance = generated.balanceAfter
            return generated
        } catch let APIError.http(status, message) {
            guard issued == generateToken else { return nil }
            // 402 is "buy more credits", not a failure to explain away.
            needsMoreCredits = status == 402
            errorMessage = message ?? "Generation failed."
            return nil
        } catch {
            guard issued == generateToken else { return nil }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Loads a listing that was generated earlier, so it can be reopened after
    /// the app was closed. Credits were charged for this work; it has to still
    /// be reachable (Guideline 2.1).
    func loadAssets(productID: String, token: String) async -> ListingAssetsDTO? {
        do {
            let listing: ListingAssetsDTO = try await api.get(
                "api/products/\(productID)/assets", token: token)
            return listing
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
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
