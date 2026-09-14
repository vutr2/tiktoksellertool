import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import ListingForge

private final class StoreKitTestBundle {}

@Suite("Local StoreKit fulfillment", .serialized) @MainActor
struct StoreKitIntegrationTests {
    @Test("A consumable retains its account token and remains unfinished until server confirmation",
          .enabled(if: ProcessInfo.processInfo.environment["STOREKIT_LOCAL_TESTS"] == "1"))
    func purchaseAndRetry() async throws {
        let url = try #require(Bundle(for: StoreKitTestBundle.self).url(forResource: "ListingForge", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let account = UUID()
        let transaction = try await session.buyProduct(identifier: "topup_300", options: [.appAccountToken(account)])
        let verification = try #require(await Transaction.latest(for: "topup_300"))
        #expect(transaction.appAccountToken == account)
        let server = StubbedServer(.json(#"{"error":"temporarily unavailable"}"#, status: 503),
            .json("""
            {"appAccountToken":"\(account.uuidString)","tier":null,"balance":300,"allowedMarketplaces":["tiktok_shop"],"subscriptionProductIDs":[],"topupProductID":"topup_300"}
            """))
        let confirmation = PurchaseConfirmation(api: server.client)
        do {
            _ = try await confirmation.confirm(signedTransaction: verification.jwsRepresentation, token: "test-jwt") {
                await transaction.finish()
            }
            Issue.record("A failed server acknowledgment unexpectedly succeeded")
        } catch { }
        var pendingIDs: Set<UInt64> = []
        for await result in Transaction.unfinished {
            if case .verified(let pending) = result { pendingIDs.insert(pending.id) }
        }
        #expect(pendingIDs.contains(transaction.id))
        _ = try await confirmation.confirm(signedTransaction: verification.jwsRepresentation, token: "test-jwt") {
            await transaction.finish()
        }
        var stillPending = false
        for await result in Transaction.unfinished {
            if case .verified(let pending) = result, pending.id == transaction.id { stillPending = true }
        }
        #expect(!stillPending)
        #expect(server.requests.count == 2)
        #expect(server.requests[0].jsonObject?["signedTransaction"] as? String == server.requests[1].jsonObject?["signedTransaction"] as? String)
    }
}
