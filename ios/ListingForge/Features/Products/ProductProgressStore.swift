import Foundation
import Observation

/// Device-local choices, scoped to an account. Images and completed listings
/// remain server-owned; restoring these choices never starts a paid request.
struct ProductProgress: Codable {
    enum Step: String, Codable { case studio, listing, review }
    var step: Step = .studio
    var industry: Industry = .beauty
    var styleID: String?
    var angles = 3
    var marketplaces: [String]?
    var scriptCount = 0
}

@MainActor
@Observable
final class ProductProgressStore {
    private var products: [String: ProductProgress] = [:]
    private let file: URL?
    private var isInvalidated = false
    private(set) var errorMessage: String?

    init(directory: URL? = nil) {
        file = directory?.appendingPathComponent("product-progress.json")
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do { products = try JSONDecoder().decode([String: ProductProgress].self, from: Data(contentsOf: file)) }
        catch { errorMessage = "Your saved choices could not be opened. Your online products and photos are still available." }
    }

    func progress(for productID: String) -> ProductProgress? {
        guard !isInvalidated else { return nil }
        return products[productID.lowercased()]
    }

    func update(_ productID: String, _ change: (inout ProductProgress) -> Void) {
        guard !isInvalidated else { return }
        let key = productID.lowercased()
        var progress = products[key] ?? ProductProgress()
        change(&progress)
        products[key] = progress
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(products).write(to: file,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            errorMessage = nil
        } catch {
            errorMessage = "Your latest choices could not be saved on this device. Free some storage before closing the app."
        }
    }

    func invalidate() { isInvalidated = true; products = [:] }
}
