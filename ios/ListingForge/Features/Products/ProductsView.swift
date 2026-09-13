//
//  ProductsView.swift
//  ListingForge
//
//  The seller's products, and the way back into a listing they already paid for.
//
//  The server is the source of truth (SPEC §9); SwiftData mirrors it so recent
//  products stay visible offline. The list prefers the server and falls back to
//  the mirror, rather than showing a cache that may belong to a previous state.
//

import SwiftData
import SwiftUI

struct ProductsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Query(sort: \CachedProduct.updatedAt, order: .reverse) private var cached: [CachedProduct]

    @State private var openedListing: OpenedListing?
    @State private var isOpening = false

    private var store: ProductStore { appEnvironment.products }

    /// A listing loaded from the server, ready for Review.
    private struct OpenedListing: Identifiable {
        let id: String
        let name: String
        let assets: [ReviewAsset]
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.products.isEmpty && cached.isEmpty {
                    ContentUnavailableView(
                        "No products yet",
                        systemImage: "shippingbox",
                        description: Text("Capture a product to get started.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Products")
            .overlay { if isOpening { ProgressView() } }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $openedListing) { listing in
                ReviewView(productName: listing.name, assets: listing.assets)
            }
        }
    }

    private var list: some View {
        List {
            if let message = store.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            // Server rows when they are available; the offline mirror otherwise.
            if !store.products.isEmpty {
                ForEach(store.products) { product in
                    Button { open(product.id, name: product.name) } label: {
                        row(name: product.name, category: product.category ?? "")
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(cached) { product in
                    row(name: product.name, category: product.category)
                        .foregroundStyle(.secondary)
                }
                Text("Showing your offline copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(name: String, category: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                if !category.isEmpty {
                    Text(category).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        guard let token = appEnvironment.auth.token else { return }
        await store.load(token: token)
    }

    private func open(_ productID: String, name: String) {
        guard let token = appEnvironment.auth.token else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            guard let listing = await appEnvironment.generation.loadAssets(
                productID: productID, token: token
            ) else { return }

            openedListing = OpenedListing(
                id: listing.product.id,
                name: listing.product.name,
                assets: listing.assets.map(ReviewAsset.init)
            )
        }
    }
}
