//
//  URLProtocolStub.swift
//  ListingForgeTests
//
//  Lets APIClient and AuthStore be driven against canned HTTP replies instead
//  of a running server.
//
//  Each StubbedServer claims its own throwaway host and registers itself under
//  it, so suites that use one can still run in parallel — the alternative
//  (a single global handler) would force every networking test to serialize.
//

import Foundation
@testable import ListingForge

// MARK: - Recording

/// What the client actually put on the wire.
struct RecordedRequest {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data?
    let timeoutInterval: TimeInterval

    /// Header lookup is case-insensitive: URLSession is free to re-case the
    /// field names it was given.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var jsonObject: [String: Any]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

// MARK: - Canned replies

/// One reply the stub hands back, in the order it was queued.
struct StubResponse {
    var statusCode: Int = 200
    var body: Data = Data()
    var headers: [String: String] = ["Content-Type": "application/json"]
    /// Reply with a plain `URLResponse` rather than an `HTTPURLResponse`, to
    /// reach `APIError.invalidResponse`.
    var isHTTP: Bool = true
    /// Fail at the transport layer (offline, timeout) instead of replying.
    var transportError: Error?

    static func json(_ raw: String, status: Int = 200) -> StubResponse {
        StubResponse(statusCode: status, body: Data(raw.utf8))
    }

    /// A 200 with no body at all — what `/api/account/delete` and
    /// `/api/auth/email/request-code` effectively return to the client.
    static func empty(status: Int = 200) -> StubResponse {
        StubResponse(statusCode: status)
    }

    /// A non-JSON body, e.g. an HTML error page from a proxy.
    static func text(_ raw: String, status: Int) -> StubResponse {
        StubResponse(statusCode: status, body: Data(raw.utf8), headers: ["Content-Type": "text/plain"])
    }

    static var notHTTP: StubResponse {
        StubResponse(isHTTP: false)
    }

    static func transportFailure(_ error: Error) -> StubResponse {
        StubResponse(transportError: error)
    }
}

// MARK: - Registry

/// Maps a host to its queued replies and recorded traffic. `@unchecked
/// Sendable` because the lock, not the compiler, guarantees exclusivity.
private final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()

    private let lock = NSLock()
    private var pending: [String: [StubResponse]] = [:]
    private var recorded: [String: [RecordedRequest]] = [:]

    func register(host: String, responses: [StubResponse]) {
        lock.withLock {
            pending[host] = responses
            recorded[host] = []
        }
    }

    func isRegistered(_ host: String) -> Bool {
        lock.withLock { pending[host] != nil }
    }

    func record(_ request: RecordedRequest, host: String) {
        lock.withLock { recorded[host, default: []].append(request) }
    }

    func requests(for host: String) -> [RecordedRequest] {
        lock.withLock { recorded[host] ?? [] }
    }

    /// Pops the next queued reply. Running dry answers with a recognisable 599
    /// so the test fails on its own assertion rather than hanging or crashing.
    func nextResponse(for host: String) -> StubResponse {
        lock.withLock {
            guard var queue = pending[host], !queue.isEmpty else {
                return .json(#"{"error":"No stubbed response left for this host."}"#, status: 599)
            }
            let next = queue.removeFirst()
            pending[host] = queue
            return next
        }
    }
}

// MARK: - Protocol

final class URLProtocolStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return StubRegistry.shared.isRegistered(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        StubRegistry.shared.record(
            RecordedRequest(
                url: url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.readBody(request),
                timeoutInterval: request.timeoutInterval
            ),
            host: host
        )

        let stub = StubRegistry.shared.nextResponse(for: host)

        if let transportError = stub.transportError {
            client?.urlProtocol(self, didFailWithError: transportError)
            return
        }

        let response: URLResponse
        if stub.isHTTP {
            response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
        } else {
            response = URLResponse(
                url: url,
                mimeType: "application/json",
                expectedContentLength: stub.body.count,
                textEncodingName: nil
            )
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession turns `httpBody` into `httpBodyStream` before a URLProtocol
    /// ever sees the request, so reading `httpBody` here would always be nil.
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - Test facade

/// An APIClient wired to a private stubbed host, plus the traffic it produced.
final class StubbedServer {
    let baseURL: URL
    let client: APIClient

    private let host: String

    convenience init(_ responses: StubResponse...) {
        self.init(responses: responses)
    }

    init(responses: [StubResponse]) {
        host = "stub-\(UUID().uuidString.lowercased()).invalid"
        baseURL = URL(string: "https://\(host)")!
        StubRegistry.shared.register(host: host, responses: responses)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        client = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
    }

    var requests: [RecordedRequest] { StubRegistry.shared.requests(for: host) }
    var lastRequest: RecordedRequest? { requests.last }

    // Deliberately no deinit. Registration must NOT be tied to this object's
    // lifetime: ARC may release it as soon as a test stops referring to it —
    // `let (auth, _) = makeStore(...)` releases it immediately — and the next
    // request would then miss the stub and hit the real network. Hosts are
    // unique per instance, so stale entries never collide; the table dies with
    // the test process.
}
