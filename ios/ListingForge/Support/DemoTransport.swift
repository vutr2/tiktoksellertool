#if DEBUG
import Foundation
import UIKit

/// Isolated fixture transport: demo screens never contact the production API.
enum DemoTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static var productImage: UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor(white: 0.75, alpha: 0.2).cgColor)
            cg.fillEllipse(in: CGRect(x: 83, y: 299, width: 239, height: 25))
            cg.setFillColor(UIColor(red: 0.85, green: 0.85, blue: 0.80, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 80, y: 275, width: 240, height: 39))
            let cone = UIBezierPath()
            cone.move(to: CGPoint(x: 82, y: 112))
            cone.addLine(to: CGPoint(x: 150, y: 280))
            cone.addQuadCurve(to: CGPoint(x: 248, y: 280), controlPoint: CGPoint(x: 200, y: 308))
            cone.addLine(to: CGPoint(x: 316, y: 112))
            cone.close()
            UIColor(red: 0.9, green: 0.90, blue: 0.86, alpha: 1).setFill()
            cone.fill()
            cg.saveGState()
            cone.addClip()
            cg.setStrokeColor(UIColor(white: 0.67, alpha: 0.35).cgColor)
            cg.setLineWidth(3)
            for index in 0..<10 {
                cg.move(to: CGPoint(x: 68 + index * 28, y: 120))
                cg.addLine(to: CGPoint(x: 177 + index * 5, y: 296))
                cg.strokePath()
            }
            cg.restoreGState()
            cg.setFillColor(UIColor(red: 0.78, green: 0.78, blue: 0.73, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 82, y: 81, width: 234, height: 63))
            cg.setStrokeColor(UIColor(white: 0.96, alpha: 1).cgColor)
            cg.setLineWidth(10)
            cg.strokeEllipse(in: CGRect(x: 82, y: 81, width: 234, height: 63))
        }
    }

    static var studioImage: Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 500, height: 500), format: format).image { context in
            UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
            productImage.draw(in: CGRect(x: 50, y: 70, width: 400, height: 400))
        }.pngData()!
    }

    static func response(for request: URLRequest) -> (Int, String, Data) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if path.hasPrefix("/demo-image/") { return (200, "image/png", studioImage) }
        var status = 200
        let body: Any
        if method == "GET", path.hasSuffix("/studio") {
            let scenes = [
                ["id": "seamless", "name": "Seamless", "emoji": "", "useCase": "Clean studio", "aspect": "1:1"],
                ["id": "marble", "name": "Marble", "emoji": "", "useCase": "Natural marble", "aspect": "1:1"],
                ["id": "lifestyle", "name": "Lifestyle", "emoji": "", "useCase": "At home", "aspect": "1:1"],
                ["id": "gradient", "name": "Gradient", "emoji": "", "useCase": "Soft colour", "aspect": "1:1"],
            ]
            let images: [[String: Any]] = DemoMode.screen == .review ? (0..<2).map {
                ["sceneId": "marble", "index": $0, "assetId": "demo-photo-\($0)", "url": "https://demo.listingforce.invalid/demo-image/\($0).png"]
            } : []
            body = ["creditsPerImage": 5, "catalog": ["HOME": scenes], "images": images]
        } else if method == "GET", path.hasSuffix("/generate") {
            body = ["credits": 2]
        } else if method == "GET", path.hasSuffix("/credits") {
            body = ["balance": 1100, "drifted": false]
        } else if method == "GET", path.hasSuffix("/assets") {
            return (200, "application/json", (try? JSONEncoder().encode(DemoData.listing)) ?? Data())
        } else if method == "POST", path.hasSuffix("/rules/convert") {
            let input = requestBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            body = ["from": input?["from"] as? String ?? "tiktok_shop", "to": input?["to"] as? String ?? "amazon",
                    "changes": [], "unresolved": [], "requiresRerender": false, "creditCost": 0]
        } else {
            status = 409
            body = ["error": "This screenshot preview does not make live requests."]
        }
        return (status, "application/json", (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            body.append(buffer, count: count)
            if body.count > 65_536 { return nil }
        }
        return body
    }
}

private final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, mime, body) = DemoTransport.response(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": mime]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
