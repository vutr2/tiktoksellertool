//
//  ProductsView.swift
//  ListingForge
//
//  Lists products from the SwiftData offline cache (§9). Read-only in M1.
//

import SwiftUI
import SwiftData

struct ProductsView: View {
    @Query(sort: \CachedProduct.updatedAt, order: .reverse) private var products: [CachedProduct]

    var body: some View {
        NavigationStack {
            Group {
                if products.isEmpty {
                    ContentUnavailableView(
                        "No products yet",
                        systemImage: "shippingbox",
                        description: Text("Capture a product to get started.")
                    )
                } else {
                    List(products) { product in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.name).font(.headline)
                            Text(product.category).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Products")
        }
    }
}
