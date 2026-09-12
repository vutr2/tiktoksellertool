//
//  APIModelsTests.swift
//  ListingForgeTests
//
//  The DTOs are the contract with api/src/app/api/**. These pin the exact JSON
//  those routes emit and accept, so a server-side rename fails here first.
//

import Foundation
import Testing
@testable import ListingForge

@Suite("API models")
struct APIModelsTests {

    @Test("Session decodes the body /api/auth/email/verify returns")
    func sessionDecodes() throws {
        let json = #"{"token":"jwt","user":{"id":"u_1","email":"seller@example.com"}}"#

        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))

        #expect(session.token == "jwt")
        #expect(session.user.id == "u_1")
        #expect(session.user.email == "seller@example.com")
    }

    @Test("A null email decodes to nil, not an empty string")
    func nullEmailDecodesToNil() throws {
        // The server nulls `email` for Apple private relay users and on
        // account deletion.
        let json = #"{"token":"jwt","user":{"id":"u_1","email":null}}"#

        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))

        #expect(session.user.email == nil)
    }

    @Test("Session survives the encode/decode round trip it makes through the Keychain")
    func sessionRoundTrips() throws {
        let original = Session(token: "jwt", user: UserDTO(id: "u_1", email: nil))

        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(original))

        #expect(restored == original)
    }

    @Test("AppleSignInRequest encodes the keys the route reads")
    func appleRequestEncodesKeys() throws {
        let request = AppleSignInRequest(
            identityToken: "identity-token",
            authorizationCode: "auth-code",
            email: "seller@example.com",
            fullName: "Trung Vu"
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        #expect(object["identityToken"] as? String == "identity-token")
        #expect(object["authorizationCode"] as? String == "auth-code")
        #expect(object["email"] as? String == "seller@example.com")
        #expect(object["fullName"] as? String == "Trung Vu")
    }

    @Test("Nil fields are omitted rather than sent as null")
    func nilFieldsAreOmitted() throws {
        let request = AppleSignInRequest(identityToken: "identity-token", authorizationCode: nil, email: nil, fullName: nil)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        // Synthesized Encodable uses encodeIfPresent. The route reads these as
        // optional, so omission is fine — but only identityToken is required.
        #expect(object.keys.sorted() == ["identityToken"])
    }

    @Test("Email requests encode the fields the routes validate")
    func emailRequestsEncode() throws {
        let codeRequest = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(EmailCodeRequest(email: "seller@example.com"))) as? [String: Any]
        )
        #expect(codeRequest["email"] as? String == "seller@example.com")

        let verifyRequest = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(EmailVerifyRequest(email: "seller@example.com", code: "123456"))) as? [String: Any]
        )
        #expect(verifyRequest["email"] as? String == "seller@example.com")
        // Sent as a string: a leading-zero code must not become an Int.
        #expect(verifyRequest["code"] as? String == "123456")
    }

    @Test("A six-digit code keeps its leading zeros end to end")
    func leadingZeroCodeSurvives() throws {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(EmailVerifyRequest(email: "a@b.co", code: "004321"))) as? [String: Any]
        )
        #expect(object["code"] as? String == "004321")
    }
}
