//
//  CachedProduct.swift
//  ListingForge
//
//  SwiftData offline cache of a server product. Cache only — never the source
//  of truth (§9). Keyed by the server-issued identifier.
//

import Foundation
import SwiftData

@Model
final class CachedProduct {
    @Attribute(.unique) var serverID: String
    var name: String
    var category: String
    var sourcePhotoURL: String?
    var cutoutURL: String?
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CachedAsset.product)
    var assets: [CachedAsset] = []

    init(
        serverID: String,
        name: String,
        category: String,
        sourcePhotoURL: String? = nil,
        cutoutURL: String? = nil,
        updatedAt: Date = .now
    ) {
        self.serverID = serverID
        self.name = name
        self.category = category
        self.sourcePhotoURL = sourcePhotoURL
        self.cutoutURL = cutoutURL
        self.updatedAt = updatedAt
    }
}
