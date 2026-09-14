//
//  OfflineCache.swift
//  ListingForge
//
//  A small per-account JSON cache on disk.
//
//  SPEC §9 is explicit that the cache is never the source of truth: it exists so
//  recent work stays readable when the network does not answer. Every read is
//  best-effort — a corrupt or missing file is simply a miss, never an error the
//  seller has to deal with.
//
//  It lives inside the account's own directory (see AccountCache), so one
//  seller's listings cannot be read by the next person to sign in on the device.
//

import Foundation

struct OfflineCache {
    /// Nil when no account is signed in; every operation then does nothing.
    let directory: URL?

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    func write<T: Encodable>(_ value: T, to name: String) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            // Losing the offline copy must never fail the operation that
            // produced it — the server already has the data.
        }
    }

    func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let directory else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    /// Removes everything. Used when the account is deleted or switched.
    func erase() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A filename that cannot escape the cache directory.
    static func key(_ raw: String) -> String {
        let safe = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return String(safe) + ".json"
    }
}
