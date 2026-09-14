import Foundation

/// An account-scoped, disposable mirror of the full server response. Keeping
/// the DTO intact preserves rule explanations and partial failures offline
/// without changing the existing SwiftData schema.
struct ListingSnapshotCache {
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory?.appendingPathComponent("snapshots", isDirectory: true)
    }

    func save(_ listing: ListingAssetsDTO) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        let data = try JSONEncoder().encode(listing)
        try data.write(to: file(for: listing.product.id, in: directory),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(productID: String) throws -> ListingAssetsDTO? {
        guard let directory else { return nil }
        let url = file(for: productID, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let listing = try JSONDecoder().decode(ListingAssetsDTO.self, from: Data(contentsOf: url))
        guard listing.product.id == productID else { return nil }
        return listing
    }

    func remove(productID: String) throws {
        guard let directory else { return }
        let url = file(for: productID, in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func file(for productID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(StableAssetIdentity.make([productID])).appendingPathExtension("json")
    }
}
