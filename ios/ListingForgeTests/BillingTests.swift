import Foundation
import Testing
@testable import ListingForge

@Suite("Purchase fulfillment") @MainActor
struct BillingTests {
    private let response = #"{"appAccountToken":"00000000-0000-4000-8000-000000000001","tier":"starter","balance":400,"allowedMarketplaces":["tiktok_shop"],"subscriptionProductIDs":["starter_monthly"],"topupProductID":"topup_300"}"#

    @Test("Only a decoded server acknowledgment permits finishing the Apple transaction")
    func acknowledgedPurchaseFinishes() async throws {
        let server = StubbedServer(.json(response))
        var finished = false
        let status = try await PurchaseConfirmation(api: server.client).confirm(signedTransaction: "signed-jws", token: "jwt") {
            #expect(server.requests.count == 1)
            finished = true
        }
        #expect(finished)
        #expect(status.balance == 400)
        #expect(server.lastRequest?.jsonObject?["signedTransaction"] as? String == "signed-jws")
        #expect(server.lastRequest?.header("Authorization") == "Bearer jwt")
    }

    @Test("Offline, rejected, or malformed acknowledgments preserve unfinished purchases for restore")
    func failedAcknowledgmentDoesNotFinish() async {
        for failure in [StubResponse.transportFailure(URLError(.timedOut)),
                        .json(#"{"error":"not verified"}"#, status: 400),
                        .json(#"{"error":"retry"}"#, status: 503), .json("{}") ] {
            let server = StubbedServer(failure)
            var finished = false
            do {
                _ = try await PurchaseConfirmation(api: server.client).confirm(signedTransaction: "signed-jws", token: "jwt") { finished = true }
                Issue.record("Invalid acknowledgment unexpectedly succeeded")
            } catch { }
            #expect(!finished)
        }
    }
}
