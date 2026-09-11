//
//  APIClient.swift
//  ListingForge
//
//  Thin typed async client over URLSession. No third-party networking.
//

import Foundation

enum APIError: LocalizedError {
    case invalidResponse
    case http(status: Int, message: String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .http(status, message):
            return message ?? "Request failed (HTTP \(status))."
        case .decoding:
            return "Could not read the server response."
        }
    }
}

struct APIClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct ErrorBody: Decodable { let error: String? }

    func get<Response: Decodable>(_ path: String, token: String? = nil) async throws -> Response {
        try await send(path, method: "GET", body: Optional<Int>.none, token: token)
    }

    @discardableResult
    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        try await send(path, method: "POST", body: body, token: token)
    }

    @discardableResult
    func post<Response: Decodable>(_ path: String, token: String? = nil) async throws -> Response {
        try await send(path, method: "POST", body: Optional<Int>.none, token: token)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body?,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.http(status: http.statusCode, message: message)
        }

        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
