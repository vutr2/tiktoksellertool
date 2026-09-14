import SwiftData
import SwiftUI

struct ProductsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedProduct.updatedAt, order: .reverse) private var cached: [CachedProduct]

    @State private var openedListing: OpenedListing?
    @State private var isOpening = false
    @State private var openError: String?
    @State private var cacheWarning: String?
    @State private var loadedEmptyList = false

    private var store: ProductStore { appEnvironment.products }
    private var hasProducts: Bool {
        !store.products.isEmpty || (!loadedEmptyList && !cached.isEmpty)
    }

    private struct OpenedListing: Identifiable {
        let listing: ListingAssetsDTO
        let notice: String?
        var id: String { listing.product.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasProducts {
                    list
                } else if store.isLoading {
                    ProgressView("Loading products…")
                } else if let message = store.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t load products", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ContentUnavailableView("No products yet", systemImage: "shippingbox",
                                           description: Text("Capture a product to get started."))
                }
            }
            .navigationTitle("Products")
            .overlay {
                if isOpening {
                    ProgressView("Opening listing…").padding().background(.regularMaterial, in: Capsule())
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $openedListing) { opened in
                ReviewView(productName: opened.listing.product.name,
                           assets: opened.listing.assets.map(ReviewAsset.init),
                           productID: opened.listing.product.id,
                           failures: opened.listing.failures,
                           notice: opened.notice)
            }
            .alert("Couldn’t open listing", isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )) {
                Button("OK") { openError = nil }
            } message: {
                Text(openError ?? "")
            }
        }
    }

    private var list: some View {
        List {
            if let message = store.errorMessage {
                Label("Showing saved products. \(message)", systemImage: "wifi.exclamationmark")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let cacheWarning {
                Text(cacheWarning).font(.footnote).foregroundStyle(.orange)
            }

            if !store.products.isEmpty {
                ForEach(store.products) { product in
                    Button { open(product.id) } label: {
                        row(name: product.name, category: product.category ?? "")
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening)
                }
            } else if !loadedEmptyList {
                ForEach(cached) { product in
                    Button { open(product.serverID) } label: {
                        row(name: product.name, category: product.category)
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpening)
                }
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
        let requestedStore = store
        await requestedStore.load(token: token)
        guard !Task.isCancelled, appEnvironment.auth.token == token,
              appEnvironment.products === requestedStore else { return }
        guard requestedStore.errorMessage == nil else { return }
        loadedEmptyList = requestedStore.products.isEmpty
        do {
            try mirrorProducts(requestedStore.products)
            cacheWarning = nil
        } catch {
            cacheWarning = "Products are saved on the server, but this device could not save an offline copy."
        }
    }

    private func open(_ productID: String) {
        guard !isOpening, let token = appEnvironment.auth.token else { return }
        let requestedGeneration = appEnvironment.generation
        isOpening = true
        openError = nil
        Task {
            defer { isOpening = false }
            let listing = await requestedGeneration.loadAssets(productID: productID, token: token)
            guard !Task.isCancelled, appEnvironment.auth.token == token,
                  appEnvironment.generation === requestedGeneration else { return }
            guard let listing else {
                openError = requestedGeneration.errorMessage ?? "This listing is not available offline yet. Connect to the internet and try again."
                return
            }
            var notice = requestedGeneration.listingLoadWarning
            do {
                try mirrorAssets(listing)
            } catch {
                notice = [notice, "This device could not update its offline product cache."].compactMap { $0 }.joined(separator: " ")
            }
            openedListing = OpenedListing(listing: listing, notice: notice)
        }
    }

    /// Called only after the response's account has been checked. A successful
    /// empty server list also removes stale rows, rather than reviving them as
    /// an apparent offline fallback.
    private func mirrorProducts(_ products: [ProductDTO]) throws {
        let existing = try modelContext.fetch(FetchDescriptor<CachedProduct>())
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.serverID, $0) })
        let serverIDs = Set(products.map(\.id))
        for cachedProduct in existing where !serverIDs.contains(cachedProduct.serverID) {
            modelContext.delete(cachedProduct)
        }
        for product in products {
            if let cachedProduct = byID[product.id] {
                cachedProduct.name = product.name
                cachedProduct.category = product.category ?? ""
                cachedProduct.cutoutURL = product.cutoutPath
            } else {
                modelContext.insert(ProductCacheMapper.cached(from: product))
            }
        }
        try modelContext.save()
    }

    private func mirrorAssets(_ listing: ListingAssetsDTO) throws {
        let productID = listing.product.id
        let descriptor = FetchDescriptor<CachedProduct>(predicate: #Predicate { $0.serverID == productID })
        let product: CachedProduct
        if let existing = try modelContext.fetch(descriptor).first {
            product = existing
        } else {
            product = CachedProduct(serverID: productID, name: listing.product.name,
                                    category: listing.product.category ?? "")
            modelContext.insert(product)
        }
        product.name = listing.product.name
        product.category = listing.product.category ?? ""
        let existingAssets = Dictionary(uniqueKeysWithValues: product.assets.map { ($0.serverID, $0) })
        let serverIDs = Set(listing.assets.map(\.id))
        for asset in product.assets where !serverIDs.contains(asset.serverID) {
            modelContext.delete(asset)
        }
        for asset in listing.assets {
            let cachedAsset = existingAssets[asset.id] ?? CachedAsset(serverID: asset.id, type: asset.type,
                                                                     marketplace: asset.marketplace)
            if existingAssets[asset.id] == nil {
                modelContext.insert(cachedAsset)
                cachedAsset.product = product
            }
            cachedAsset.type = asset.type
            cachedAsset.marketplace = asset.marketplace
            cachedAsset.content = asset.content
            cachedAsset.validationStatus = asset.status
        }
        try modelContext.save()
    }
}
