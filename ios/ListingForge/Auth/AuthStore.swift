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
    var onSessionChanged: ((UserDTO?) -> Void)?
    var onAccountDeleted: (() throws -> Void)?
    private(set) var needsAppleDeletionAuthorization = false
    var deletionNotice: String?

    private let api: APIClient
    private let keychain = KeychainStore()
    private let sessionKey = "session"
    #if DEBUG
    private var isDemoSession = false
    #endif

    private var persistsSession: Bool {
        #if DEBUG
        return !isDemoSession
        #else
        return true
        #endif
    }

    private var session: Session? {
        didSet {
            onSessionChanged?(session?.user)
            if let session {
                if persistsSession, let data = try? JSONEncoder().encode(session) {
                    keychain.set(data, for: sessionKey)
                }
                state = .signedIn(session.user)
            } else {
                if persistsSession { keychain.delete(sessionKey) }
                state = .signedOut
            }
        }
    }

    var token: String? { session?.token }

    init(api: APIClient) {
        self.api = api
    }

    func restore() {
        #if DEBUG
        // A preview must not import the saved real account after signing out.
        guard !isDemoSession else { return }
        #endif
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

    #if DEBUG
    /// Keeps preview sign-in and sign-out entirely in memory, preserving the
    /// real account's saved session for the next normal app launch.
    func startDemoSession(_ user: UserDTO) {
        isDemoSession = true
        session = Session(token: "demo-token", user: user)
    }
    #endif

    func deleteAccount(identityToken: String? = nil, authorizationCode: String? = nil,
                       skipAppleRevocation: Bool = false) async {
        guard let token, !isBusy else { return }
        struct Request: Encodable {
            let identityToken: String?
            let authorizationCode: String?
            let skipAppleRevocation: Bool
        }
        isBusy = true
        errorMessage = nil
        needsAppleDeletionAuthorization = false
        defer { isBusy = false }
        do {
            let _: EmptyResponse = try await api.post("api/account/delete", body: Request(
                identityToken: identityToken, authorizationCode: authorizationCode,
                skipAppleRevocation: skipAppleRevocation), token: token)
            guard self.token == token else { return }
            try onAccountDeleted?()
            deletionNotice = skipAppleRevocation
                ? "Your account was deleted. To disconnect Apple, open Settings → your Apple Account → Sign in with Apple → Listing Force → Stop Using Apple ID."
                : "Your account was deleted."
            session = nil
        } catch let APIError.http(status, message) where status == 428 {
            needsAppleDeletionAuthorization = true
            errorMessage = message
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Runs a throwing async task with shared busy/error handling.
    @discardableResult
    private func perform(_ work: @escaping () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
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
