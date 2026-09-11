//
//  CachedAsset.swift
//  ListingForge
//
//  SwiftData offline cache of a server asset (§9). Cache only.
//

import Foundation
import SwiftData

@Model
final class CachedAsset {
    @Attribute(.unique) var serverID: String
    var type: String
    var marketplace: String
    var content: String?
    var url: String?
    var validationStatus: String
    var updatedAt: Date

    var product: CachedProduct?

    init(
        serverID: String,
        type: String,
        marketplace: String,
        content: String? = nil,
        url: String? = nil,
        validationStatus: String = "pending",
        updatedAt: Date = .now
    ) {
        self.serverID = serverID
        self.type = type
        self.marketplace = marketplace
        self.content = content
        self.url = url
        self.validationStatus = validationStatus
        self.updatedAt = updatedAt
    }
}
