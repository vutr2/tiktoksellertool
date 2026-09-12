//
//  AuthStoreTests.swift
//  ListingForgeTests
//
//  The session state machine: who is signed in, what survives a relaunch, and
//  what happens when the server says no.
//
//  Serialized because AuthStore writes to the real Keychain under a fixed
//  service/account pair, so these tests share one storage slot.
//

import Foundation
import Testing
@testable import ListingForge

@Suite("AuthStore", .serialized)
final class AuthStoreTests {

    /// Mirrors AuthStore's private `sessionKey`.
    private static let sessionKey = "session"

    // A class suite gets a fresh instance per test, so init/deinit bracket each
    // one. The session slot is shared with the UI test target's app process,
    // so leaving a token behind would change which screen it launches into.
    init() { KeychainStore().delete(Self.sessionKey) }
    deinit { KeychainStore().delete(Self.sessionKey) }

    @MainActor
    private func makeStore(
        persisting session: Session? = nil,
        replies: [StubResponse] = []
    ) -> (auth: AuthStore, server: StubbedServer) {
        let keychain = KeychainStore()
        keychain.delete(Self.sessionKey)
        if let session, let data = try? JSONEncoder().encode(session) {
            keychain.set(data, for: Self.sessionKey)
        }
        let server = StubbedServer(responses: replies)
        return (AuthStore(api: server.client), server)
    }

    private func session(token: String = "jwt", id: String = "u_1", email: String? = "seller@example.com") -> Session {
        Session(token: token, user: UserDTO(id: id, email: email))
    }

    // MARK: Launch

    @MainActor
    @Test("Starts in .loading so the UI can show a spinner before restore runs")
    func startsLoading() {
        let (auth, _) = makeStore()
        #expect(auth.state == .loading)
        #expect(auth.token == nil)
    }

    @MainActor
    @Test("Restoring with nothing stored signs the seller out")
    func restoreWithoutStoredSession() {
        let (auth, _) = makeStore()

        auth.restore()

        #expect(auth.state == .signedOut)
        #expect(auth.token == nil)
    }

    @MainActor
    @Test("Restoring reads a session persisted by a previous launch")
    func restoreReadsPersistedSession() {
        let stored = session(token: "persisted-jwt")
        let (auth, _) = makeStore(persisting: stored)

        auth.restore()

        #expect(auth.state == .signedIn(stored.user))
        #expect(auth.token == "persisted-jwt")
    }

    @MainActor
    @Test("A corrupt Keychain payload is treated as signed out rather than crashing")
    func restoreIgnoresCorruptPayload() {
        let (auth, _) = makeStore()
        KeychainStore().set(Data("not json".utf8), for: Self.sessionKey)

        auth.restore()

        #expect(auth.state == .signedOut)
    }

    // MARK: Email sign-in

    @MainActor
    @Test("Verifying a code signs in and persists the session for the next launch")
    func verifyEmailCodeSignsInAndPersists() async throws {
        let (auth, server) = makeStore(
            replies: [.json(#"{"token":"jwt-abc","user":{"id":"u_1","email":"seller@example.com"}}"#)]
        )
        auth.restore()

        await auth.verifyEmailCode(email: "seller@example.com", code: "123456")

        #expect(auth.state == .signedIn(UserDTO(id: "u_1", email: "seller@example.com")))
        #expect(auth.token == "jwt-abc")
        #expect(auth.errorMessage == nil)
        #expect(auth.isBusy == false)

        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/auth/email/verify")
        #expect(request.jsonObject?["email"] as? String == "seller@example.com")
        #expect(request.jsonObject?["code"] as? String == "123456")

        // A fresh store standing in for the next cold launch.
        let relaunched = AuthStore(api: server.client)
        relaunched.restore()
        #expect(relaunched.token == "jwt-abc")
    }

    @MainActor
    @Test("A rejected code leaves the seller signed out and shows the server's reason")
    func verifyEmailCodeFailureKeepsSignedOut() async {
        let (auth, _) = makeStore(replies: [.json(#"{"error":"That code is incorrect."}"#, status: 400)])
        auth.restore()

        await auth.verifyEmailCode(email: "seller@example.com", code: "000000")

        #expect(auth.state == .signedOut)
        #expect(auth.token == nil)
        #expect(auth.errorMessage == "That code is incorrect.")
        #expect(auth.isBusy == false)
    }

    @MainActor
    @Test("Requesting a code reports success, then surfaces a rejection")
    func requestEmailCodeReportsOutcome() async throws {
        let (auth, server) = makeStore(
            replies: [.empty(), .json(#"{"error":"Enter a valid email address."}"#, status: 400)]
        )

        let sent = await auth.requestEmailCode("seller@example.com")
        #expect(sent)
        #expect(auth.errorMessage == nil)
        let first = try #require(server.requests.first)
        #expect(first.url?.path == "/api/auth/email/request-code")
        #expect(first.jsonObject?["email"] as? String == "seller@example.com")

        let rejected = await auth.requestEmailCode("not-an-email")
        #expect(rejected == false)
        #expect(auth.errorMessage == "Enter a valid email address.")
    }

    @MainActor
    @Test("Going offline surfaces a message instead of failing silently")
    func offlineSurfacesMessage() async {
        let (auth, _) = makeStore(replies: [.transportFailure(URLError(.notConnectedToInternet))])
        auth.restore()

        await auth.verifyEmailCode(email: "seller@example.com", code: "123456")

        #expect(auth.state == .signedOut)
        // Asserted exactly, not just "non-empty": a stub that failed to
        // intercept would produce a DNS error that any looser check accepts.
        #expect(auth.errorMessage == URLError(.notConnectedToInternet).localizedDescription)
        #expect(auth.isBusy == false)
    }

    // MARK: Apple sign-in

    @MainActor
    @Test("Sign in with Apple forwards the credential and stores the returned session")
    func appleSignInForwardsCredential() async throws {
        let (auth, server) = makeStore(
            replies: [.json(#"{"token":"apple-jwt","user":{"id":"u_9","email":"x@privaterelay.appleid.com"}}"#)]
        )

        await auth.signInWithApple(
            identityToken: "identity-token",
            authorizationCode: "auth-code",
            email: "x@privaterelay.appleid.com",
            fullName: "Trung Vu"
        )

        #expect(auth.token == "apple-jwt")
        #expect(auth.state == .signedIn(UserDTO(id: "u_9", email: "x@privaterelay.appleid.com")))

        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/auth/apple")
        let body = try #require(request.jsonObject)
        #expect(body["identityToken"] as? String == "identity-token")
        #expect(body["authorizationCode"] as? String == "auth-code")
        #expect(body["fullName"] as? String == "Trung Vu")
    }

    @MainActor
    @Test("Apple returns no email on repeat sign-ins; the account still signs in")
    func appleSignInWithoutEmail() async throws {
        let (auth, server) = makeStore(replies: [.json(#"{"token":"apple-jwt","user":{"id":"u_9","email":null}}"#)])

        await auth.signInWithApple(identityToken: "identity-token", authorizationCode: nil, email: nil, fullName: nil)

        #expect(auth.state == .signedIn(UserDTO(id: "u_9", email: nil)))
        let body = try #require(server.lastRequest?.jsonObject)
        // Nil optionals are omitted rather than sent as null; the route treats
        // a missing key and null the same way.
        #expect(body["email"] == nil)
        #expect(body["identityToken"] as? String == "identity-token")
    }

    // MARK: Sign out and deletion

    @MainActor
    @Test("Signing out clears the session and the Keychain copy")
    func signOutClearsEverything() {
        let (auth, server) = makeStore(persisting: session())
        auth.restore()
        #expect(auth.token == "jwt")

        auth.signOut()

        #expect(auth.state == .signedOut)
        #expect(auth.token == nil)

        let relaunched = AuthStore(api: server.client)
        relaunched.restore()
        #expect(relaunched.state == .signedOut)
    }

    @MainActor
    @Test("Deleting the account calls the API with the token, then signs out")
    func deleteAccountSignsOut() async throws {
        let (auth, server) = makeStore(persisting: session(token: "jwt-del"), replies: [.empty()])
        auth.restore()

        await auth.deleteAccount()

        #expect(auth.state == .signedOut)
        #expect(auth.token == nil)
        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/account/delete")
        #expect(request.method == "POST")
        #expect(request.header("Authorization") == "Bearer jwt-del")
    }

    @MainActor
    @Test("A failed deletion keeps the seller signed in rather than faking success")
    func failedDeleteKeepsSession() async {
        let stored = session(token: "jwt-del")
        let (auth, _) = makeStore(
            persisting: stored,
            replies: [.json(#"{"error":"Could not delete the account."}"#, status: 500)]
        )
        auth.restore()

        await auth.deleteAccount()

        #expect(auth.state == .signedIn(stored.user))
        #expect(auth.token == "jwt-del")
        #expect(auth.errorMessage == "Could not delete the account.")
    }

    @MainActor
    @Test("Deleting with no session makes no request at all")
    func deleteWithoutSessionIsNoop() async {
        let (auth, server) = makeStore()
        auth.restore()

        await auth.deleteAccount()

        #expect(server.requests.isEmpty)
        #expect(auth.state == .signedOut)
    }
}
