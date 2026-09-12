//
//  AppleSignInErrorTests.swift
//  ListingForgeTests
//
//  Pins that no Apple framework error string ever reaches the seller verbatim.
//

import AuthenticationServices
import Foundation
import Testing
@testable import ListingForge

@Suite("Apple sign-in errors")
struct AppleSignInErrorTests {

    private func error(_ code: ASAuthorizationError.Code) -> Error {
        NSError(domain: ASAuthorizationError.errorDomain, code: code.rawValue)
    }

    @Test("A cancelled sheet shows nothing — the seller already knows")
    func cancelIsSilent() {
        #expect(AppleSignInError.message(for: error(.canceled)) == nil)
    }

    @Test("Error 1000 explains the real cause instead of leaking the raw NSError")
    func unknownExplainsAppleAccount() throws {
        // This is what a fresh simulator with no Apple Account produces.
        let message = try #require(AppleSignInError.message(for: error(.unknown)))

        #expect(message.contains("Apple Account"))
        #expect(message.contains("Settings"))
        // The string the framework would otherwise have shown.
        #expect(!message.contains("AuthorizationError"))
        #expect(!message.contains("1000"))
    }

    @Test("Every failure code produces human text, never framework jargon", arguments: [
        ASAuthorizationError.Code.unknown,
        .invalidResponse,
        .notHandled,
        .failed,
        .notInteractive
    ])
    func allCodesAreHumanReadable(code: ASAuthorizationError.Code) throws {
        let message = try #require(AppleSignInError.message(for: error(code)))

        #expect(!message.isEmpty)
        #expect(!message.contains("AuthorizationError"))
        #expect(!message.contains("com.apple"))
        #expect(!message.lowercased().contains("couldn’t be completed"))
    }

    @Test("A non-Apple error still surfaces its own description")
    func passesThroughForeignErrors() {
        let urlError = URLError(.notConnectedToInternet)
        #expect(AppleSignInError.message(for: urlError) == urlError.localizedDescription)
    }
}
