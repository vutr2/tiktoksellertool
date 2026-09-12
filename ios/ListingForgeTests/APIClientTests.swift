//
//  APIClientTests.swift
//  ListingForgeTests
//
//  Pins the request APIClient puts on the wire and how it maps each class of
//  reply onto APIError — the error text here is what AuthView shows the seller.
//

import Foundation
import Testing
@testable import ListingForge

@Suite("APIClient")
struct APIClientTests {

    // MARK: Requests

    @Test("POST appends the path, sends JSON, and omits Authorization when there is no token")
    func postSendsJSONWithoutToken() async throws {
        let server = StubbedServer(.json(#"{"ok":true}"#))
        struct Reply: Decodable { let ok: Bool }

        let reply: Reply = try await server.client.post(
            "api/auth/email/request-code",
            body: EmailCodeRequest(email: "seller@example.com")
        )

        #expect(reply.ok)
        let request = try #require(server.lastRequest)
        #expect(request.url?.path == "/api/auth/email/request-code")
        #expect(request.method == "POST")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("Authorization") == nil)
        #expect(request.jsonObject?["email"] as? String == "seller@example.com")
    }

    @Test("A token is sent as a bearer credential")
    func tokenBecomesBearerHeader() async throws {
        let server = StubbedServer(.empty())

        let _: EmptyResponse = try await server.client.post("api/account/delete", token: "session-jwt")

        let request = try #require(server.lastRequest)
        #expect(request.header("Authorization") == "Bearer session-jwt")
    }

    @Test("GET carries no body and no Content-Type")
    func getSendsNoBody() async throws {
        let server = StubbedServer(.json(#"{"ok":true}"#))
        struct Reply: Decodable { let ok: Bool }

        let _: Reply = try await server.client.get("api/health")

        let request = try #require(server.lastRequest)
        #expect(request.method == "GET")
        #expect(request.body == nil)
        #expect(request.header("Content-Type") == nil)
    }

    // MARK: Replies

    @Test("A 200 with an empty body is accepted as EmptyResponse")
    func emptyBodyDecodesAsEmptyResponse() async throws {
        let server = StubbedServer(.empty())

        // The server returns `{}` for delete/request-code; an empty body would
        // otherwise be a decoding error, so this branch has to short-circuit.
        let _: EmptyResponse = try await server.client.post("api/account/delete", token: "t")

        #expect(server.requests.count == 1)
    }

    @Test("A typed success body decodes into the model")
    func successBodyDecodes() async throws {
        let server = StubbedServer(.json(#"{"token":"jwt","user":{"id":"u_1","email":"seller@example.com"}}"#))

        let session: Session = try await server.client.post(
            "api/auth/email/verify",
            body: EmailVerifyRequest(email: "seller@example.com", code: "123456")
        )

        #expect(session.token == "jwt")
        #expect(session.user.id == "u_1")
        #expect(session.user.email == "seller@example.com")
    }

    @Test("A non-2xx reply surfaces the server's own error message")
    func serverErrorMessageSurfaces() async throws {
        let server = StubbedServer(.json(#"{"error":"That code is incorrect."}"#, status: 400))

        do {
            let _: Session = try await server.client.post(
                "api/auth/email/verify",
                body: EmailVerifyRequest(email: "seller@example.com", code: "000000")
            )
            Issue.record("Expected the request to throw.")
        } catch let APIError.http(status, message) {
            #expect(status == 400)
            #expect(message == "That code is incorrect.")
            // This string is what the seller reads in AuthView.
            #expect(APIError.http(status: status, message: message).errorDescription == "That code is incorrect.")
        }
    }

    @Test("A non-2xx reply that is not JSON falls back to a generic message")
    func nonJSONErrorFallsBack() async throws {
        // e.g. an HTML error page from a proxy in front of the API.
        let server = StubbedServer(.text("<html>502 Bad Gateway</html>", status: 502))

        do {
            let _: Session = try await server.client.get("api/health")
            Issue.record("Expected the request to throw.")
        } catch let APIError.http(status, message) {
            #expect(status == 502)
            #expect(message == nil)
            #expect(APIError.http(status: status, message: message).errorDescription == "Request failed (HTTP 502).")
        }
    }

    @Test("A 200 whose body does not match the model throws .decoding")
    func mismatchedBodyThrowsDecoding() async throws {
        let server = StubbedServer(.json(#"{"unexpected":true}"#))

        do {
            let _: Session = try await server.client.get("api/health")
            Issue.record("Expected the request to throw.")
        } catch let APIError.decoding(underlying) {
            #expect(underlying is DecodingError)
            #expect(APIError.decoding(underlying).errorDescription == "Could not read the server response.")
        }
    }

    @Test("A reply that is not an HTTP response throws .invalidResponse")
    func nonHTTPResponseIsRejected() async throws {
        let server = StubbedServer(.notHTTP)

        do {
            let _: EmptyResponse = try await server.client.get("api/health")
            Issue.record("Expected the request to throw.")
        } catch APIError.invalidResponse {
            // expected
        }
    }

    @Test("Transport failures propagate unwrapped so URLError stays inspectable")
    func transportFailurePropagates() async throws {
        let server = StubbedServer(.transportFailure(URLError(.notConnectedToInternet)))

        do {
            let _: EmptyResponse = try await server.client.get("api/health")
            Issue.record("Expected the request to throw.")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        }
    }
}
