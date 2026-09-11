//
//  AuthStore.swift
//  ListingForge
//
//  Session management for Sign in with Apple + email. The server is the source
//  of truth; this only holds the issued session token.
//

import Foundation
import Observation

@MainActor
@Observable
final class AuthStore {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(UserDTO)
    }

    private(set) var state: State = .loading
    private(set) var isBusy = false
    var errorMessage: String?

    private let api: APIClient
    private let keychain = KeychainStore()
    private let sessionKey = "session"

    private var session: Session? {
        didSet {
            if let session {
                if let data = try? JSONEncoder().encode(session) {
                    keychain.set(data, for: sessionKey)
                }
                state = .signedIn(session.user)
            } else {
                keychain.delete(sessionKey)
                state = .signedOut
            }
        }
    }

    var token: String? { session?.token }

    init(api: APIClient) {
        self.api = api
    }

    func restore() {
        if let data = keychain.data(for: sessionKey),
           let saved = try? JSONDecoder().decode(Session.self, from: data) {
            session = saved
        } else {
            state = .signedOut
        }
    }

    func signInWithApple(identityToken: String, authorizationCode: String?, email: String?, fullName: String?) async {
        await perform {
            let request = AppleSignInRequest(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                email: email,
                fullName: fullName
            )
            let newSession: Session = try await self.api.post("api/auth/apple", body: request)
            self.session = newSession
        }
    }

    @discardableResult
    func requestEmailCode(_ email: String) async -> Bool {
        await perform {
            let _: EmptyResponse = try await self.api.post("api/auth/email/request-code", body: EmailCodeRequest(email: email))
        }
    }

    func verifyEmailCode(email: String, code: String) async {
        await perform {
            let newSession: Session = try await self.api.post("api/auth/email/verify", body: EmailVerifyRequest(email: email, code: code))
            self.session = newSession
        }
    }

    func signOut() {
        session = nil
    }

    func deleteAccount() async {
        guard let token else { return }
        let succeeded = await perform {
            let _: EmptyResponse = try await self.api.post("api/account/delete", token: token)
        }
        if succeeded { session = nil }
    }

    /// Runs a throwing async task with shared busy/error handling.
    @discardableResult
    private func perform(_ work: @escaping () async throws -> Void) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }
}
