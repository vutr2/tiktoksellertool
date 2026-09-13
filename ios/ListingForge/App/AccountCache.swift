import CryptoKit
import Foundation
import SwiftData

/// A separate persistent store for each server account. Legacy unowned caches
/// are never opened: their rows cannot safely be attributed to the next login.
@MainActor
final class AccountCache {
    let userID: String
    let directory: URL
    let container: ModelContainer

    init(userID: String) throws {
        self.userID = userID
        let digest = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                             in: .userDomainMask, appropriateFor: nil, create: true)
        directory = root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let schema = Schema([CachedProduct.self, CachedAsset.self])
        let configuration = ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("cache.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    func erase() throws {
        // Invalidate the account's requests before calling this, so responses
        // cannot repopulate the old cache after deletion.
        try container.mainContext.delete(model: CachedAsset.self)
        try container.mainContext.delete(model: CachedProduct.self)
        try container.mainContext.save()
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil)
        // Leave the empty, open SQLite store alone. Remove photos and snapshots.
        for file in files where !file.lastPathComponent.hasPrefix("cache.store") {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func removeLegacyUnownedCache() throws {
        let schema = Schema([CachedProduct.self, CachedAsset.self])
        let url = ModelConfiguration(schema: schema).url
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
