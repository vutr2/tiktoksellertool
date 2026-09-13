import Foundation
import Testing
@testable import ListingForge

@Suite("APIClient URL building")
struct APIClientURLTests {
    private let base = URL(string: "https://api.example.com")!

    @Test("A plain path joins onto the base")
    func plainPath() {
        let url = APIClient.url(base: base, path: "api/health")
        #expect(url.absoluteString == "https://api.example.com/api/health")
    }

    @Test("A query string survives instead of being encoded into the path")
    func queryIsPreserved() {
        let url = APIClient.url(base: base, path: "api/products/p1/generate?marketplaces=amazon,tiktok_shop&scriptCount=1")
        #expect(url.path == "/api/products/p1/generate", "got path \(url.path)")
        #expect(url.query == "marketplaces=amazon,tiktok_shop&scriptCount=1", "got query \(url.query ?? "nil") from \(url.absoluteString)")
    }

    @Test("A base URL with a trailing slash does not double up")
    func trailingSlashBase() {
        let url = APIClient.url(base: URL(string: "https://api.example.com/")!, path: "api/health")
        #expect(!url.absoluteString.contains("//api/health"), "got \(url.absoluteString)")
    }
}
