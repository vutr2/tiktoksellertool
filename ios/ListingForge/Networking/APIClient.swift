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
        token: String? = nil,
        timeout: TimeInterval = 60
    ) async throws -> Response {
        try await send(path, method: "POST", body: body, token: token, timeout: timeout)
    }

    @discardableResult
    func post<Response: Decodable>(_ path: String, token: String? = nil) async throws -> Response {
        try await send(path, method: "POST", body: Optional<Int>.none, token: token)
    }

    /// Sends image bytes without the size overhead of base64 JSON.
    func putData(_ path: String, data: Data, contentType: String, token: String) async throws {
        var request = URLRequest(url: Self.url(base: baseURL, path: path))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
            throw APIError.http(status: http.statusCode, message: message)
        }
    }

    /// Joins a path onto the base URL, keeping any query string intact.
    ///
    /// `appendingPathComponent` percent-encodes "?" into the path, so
    /// "api/x?a=1" would request a literal path segment named "x%3Fa=1" — a
    /// wrong URL that the server answers with a 404 rather than an obvious
    /// error.
    static func url(base: URL, path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathOnly = String(parts[0])

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base.appendingPathComponent(pathOnly)
        }
        // A URLComponents with a host but a path that does not start with "/"
        // is invalid, and `.url` silently returns nil — which used to drop the
        // query on the fallback path.
        var joined = (components.path as NSString).appendingPathComponent(pathOnly)
        if !joined.hasPrefix("/") { joined = "/" + joined }
        components.path = joined

        if parts.count > 1, !parts[1].isEmpty {
            components.percentEncodedQuery = String(parts[1])
        }
        return components.url ?? base.appendingPathComponent(pathOnly)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body?,
        token: String?,
        timeout: TimeInterval = 60
    ) async throws -> Response {
        var request = URLRequest(url: Self.url(base: baseURL, path: path))
        request.timeoutInterval = timeout
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
