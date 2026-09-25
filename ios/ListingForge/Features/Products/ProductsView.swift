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
    @State private var showingDraft = false
    @State private var completedDraft: GenerateResultDTO?

    private var store: ProductStore { appEnvironment.products }
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showingHidden = false
    @State private var pendingDeletion: Set<String> = []
    @State private var confirmingDeletion = false
    @State private var managementError: String?

    private var allProducts: [ProductDTO] {
        let products = !store.products.isEmpty || loadedEmptyList ? store.products : cached.map {
            ProductDTO(id: $0.serverID, name: $0.name, category: $0.category,
                       cutoutPath: $0.cutoutURL, createdAt: $0.updatedAt.ISO8601Format())
        }
        return products.filter { !store.deletedIDs.contains($0.id) }
    }
    private var visibleProducts: [ProductDTO] {
        allProducts.filter { ($0.isHidden == true) == showingHidden }
    }
    private var visibleIDs: Set<String> { Set(visibleProducts.map(\.id)) }
    private var busy: Bool { store.isUpdating || isOpening }

    private struct OpenedListing: Identifiable {
        let listing: ListingAssetsDTO
        let notice: String?
        var id: String { listing.product.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !showingHidden && appEnvironment.captureDraft.draft.hasContent { draftCard }
                    if let message = store.errorMessage {
                        Label(message, systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }.font(.subheadline)
                    }
                    if let message = cacheWarning ?? store.cacheWarning {
                        Text(message).font(.footnote).foregroundStyle(WorkflowStyle.amber)
                    }
                    if visibleProducts.isEmpty {
                        if store.isLoading { ProgressView("Loading products…").frame(maxWidth: .infinity) }
                        else {
                            ContentUnavailableView(showingHidden ? "No hidden products" : "No products yet",
                                systemImage: showingHidden ? "eye.slash" : "shippingbox",
                                description: Text(showingHidden ? "Products you hide will appear here. You can show them again anytime." : "Capture a product to get started, or check Hidden products in the menu."))
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                                  alignment: .leading, spacing: 24) {
                            ForEach(visibleProducts) { product in productCard(product) }
                        }
                    }
                }.padding(20)
            }
            .background(WorkflowStyle.background)
            .navigationTitle(showingHidden ? "Hidden products" : "Products")
            .tint(.primary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selectedIDs = []
                    }.disabled(busy || (!selecting && visibleProducts.isEmpty))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(showingHidden ? "Show products" : "Hidden products", systemImage: showingHidden ? "square.grid.2x2" : "eye.slash") {
                            showingHidden.toggle()
                            selectedIDs = []
                        }
                        if selecting {
                            Button(selectedIDs == visibleIDs ? "Deselect all" : "Select all") {
                                selectedIDs = selectedIDs == visibleIDs ? [] : visibleIDs
                            }
                        }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Product library options") }
                    .disabled(busy)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectionBar }
            }
            .overlay {
                if busy {
                    ProgressView(store.updateProgress ?? "Opening listing…")
                        .padding().background(.regularMaterial, in: Capsule())
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: visibleIDs) { _, ids in selectedIDs.formIntersection(ids) }
            .sheet(item: $openedListing) { opened in
                ReviewView(productName: opened.listing.product.name,
                           assets: opened.listing.assets.map(ReviewAsset.init),
                           productID: opened.listing.product.id,
                           listingLanguage: opened.listing.outputLanguage,
                           failures: opened.listing.failures, notice: opened.notice)
            }
            .sheet(isPresented: $showingDraft, onDismiss: {
                if let result = completedDraft {
                    completedDraft = nil
                    appEnvironment.captureDraft.reset()
                    openedListing = OpenedListing(listing: .generated(result, productName: result.facts.suggestedName), notice: nil)
                }
            }) {
                ProductDetailsView(cutouts: appEnvironment.captureDraft.draft.cutouts,
                    onCreated: { _ in }, onGenerated: { result in
                        completedDraft = result
                        showingDraft = false
                    })
            }
            .confirmationDialog(pendingDeletion.count == 1 ? "Delete this product?" : "Delete \(pendingDeletion.count) products?",
                                isPresented: $confirmingDeletion, titleVisibility: .visible) {
                Button(pendingDeletion.count == 1 ? "Delete product" : "Delete \(pendingDeletion.count) products", role: .destructive) {
                    perform(.delete, ids: pendingDeletion)
                    pendingDeletion = []
                }
                Button("Cancel", role: .cancel) { pendingDeletion = [] }
            } message: {
                Text("The products, their captured photos and saved listings will be deleted from your account. This cannot be undone. Photos already exported to your photo library will remain there.")
            }
            .alert("Product library", isPresented: Binding(
                get: { openError != nil || managementError != nil },
                set: { if !$0 { openError = nil; managementError = nil } }
            )) {
                Button("OK") { openError = nil; managementError = nil }
            } message: { Text(managementError ?? openError ?? "") }
        }
    }

    private var draftCard: some View {
        Button { showingDraft = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise").font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resume draft").font(.subheadline.weight(.semibold))
                    Text(appEnvironment.captureDraft.draft.name.isEmpty ? "Your captured product" : appEnvironment.captureDraft.draft.name)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.workflowCard()
        }.buttonStyle(.plain).disabled(busy)
    }

    private func activate(_ product: ProductDTO) {
        if selecting {
            if selectedIDs.contains(product.id) { selectedIDs.remove(product.id) }
            else { selectedIDs.insert(product.id) }
        } else if product.deletionPending == true { askToDelete([product.id]) }
        else { open(product.id) }
    }

    private func productCard(_ product: ProductDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { activate(product) } label: {
                Rectangle().fill(WorkflowStyle.surface).aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ProductThumbnail(store: store, product: product, token: appEnvironment.auth.token)
                            .padding(12)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .stroke(selectedIDs.contains(product.id) ? Color.primary : WorkflowStyle.border,
                                lineWidth: selectedIDs.contains(product.id) ? 2 : 0.8))
                    .overlay(alignment: .topLeading) {
                        if selecting {
                            Image(systemName: selectedIDs.contains(product.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).symbolRenderingMode(.palette)
                                .foregroundStyle(selectedIDs.contains(product.id) ? Color.primary : .secondary, WorkflowStyle.surface)
                                .padding(10)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(product.name)
            .accessibilityAddTraits(selectedIDs.contains(product.id) ? .isSelected : [])
            HStack(alignment: .top, spacing: 4) {
                Button { activate(product) } label: {
                    Text(product.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44, alignment: .topLeading)
                }.buttonStyle(.plain)
                if !selecting {
                    Menu {
                        Button(product.isHidden == true ? "Show product" : "Hide product", systemImage: product.isHidden == true ? "eye" : "eye.slash") {
                            perform(product.isHidden == true ? .unhide : .hide, ids: [product.id])
                        }.disabled(product.deletionPending == true)
                        Button("Delete this product", systemImage: "trash", role: .destructive) { askToDelete([product.id]) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44, alignment: .top)
                            .contentShape(Rectangle())
                    }.accessibilityLabel("Options for \(product.name)")
                }
            }
            if product.deletionPending == true {
                Text("Deletion incomplete · tap to retry").font(.caption2).foregroundStyle(WorkflowStyle.red)
            }
        }.disabled(busy)
    }

    private var selectionBar: some View {
        VStack(spacing: 12) {
            Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { perform(showingHidden ? .unhide : .hide, ids: selectedIDs) } label: {
                    Label(showingHidden ? "Show selected" : "Hide selected", systemImage: showingHidden ? "eye" : "eye.slash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                Button(role: .destructive) { askToDelete(selectedIDs) } label: {
                    Label("Delete selected", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
            }.font(.subheadline).disabled(selectedIDs.isEmpty || busy)
        }.padding(16).background(WorkflowStyle.surface)
    }

    private func askToDelete(_ ids: Set<String>) {
        guard !busy, !ids.isEmpty else { return }
        if appEnvironment.generation.isGenerating || ids.contains(where: { appEnvironment.studio(for: $0).isGenerating }) {
            managementError = "Wait for generation to finish before deleting a product. You can hide it instead."
            return
        }
        pendingDeletion = ids
        confirmingDeletion = true
    }

    private func perform(_ action: ProductStore.LibraryAction, ids: Set<String>) {
        guard !busy, !ids.isEmpty, let token = appEnvironment.auth.token else { return }
        let requestedStore = store
        Task {
            let succeeded = await requestedStore.update(ids, action: action, token: token)
            guard appEnvironment.auth.token == token, appEnvironment.products === requestedStore else { return }
            var cleanupWarning: String?
            for id in succeeded where action == .delete {
                do { try appEnvironment.removeProductCache(id) }
                catch { cleanupWarning = "Deleted online, but some offline files could not be removed from this device." }
                for product in cached where product.serverID == id { modelContext.delete(product) }
            }
            if action == .delete {
                do { try modelContext.save() }
                catch { cleanupWarning = "Deleted online, but the offline list could not be updated." }
            }
            selectedIDs.subtract(succeeded)
            if selectedIDs.isEmpty { selecting = false }
            managementError = requestedStore.updateError
            await load()
            if let cleanupWarning { cacheWarning = cleanupWarning }
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
        let savedProduct: ListingProductDTO?
        if let product = store.products.first(where: { $0.id == productID }) {
            savedProduct = ListingProductDTO(id: product.id, name: product.name, category: product.category)
        } else if let product = cached.first(where: { $0.serverID == productID }) {
            savedProduct = ListingProductDTO(id: product.serverID, name: product.name, category: product.category)
        } else { savedProduct = nil }
        Task {
            defer { isOpening = false }
            let listing = await requestedGeneration.loadAssets(productID: productID, token: token, savedProduct: savedProduct)
            guard !Task.isCancelled, appEnvironment.auth.token == token,
                  appEnvironment.generation === requestedGeneration else { return }
            guard let listing else {
                openError = requestedGeneration.errorMessage ?? "This listing is not available offline yet. Connect to the internet and try again."
                return
            }
            var notice = requestedGeneration.listingLoadWarning
            do {
                if notice == nil { try mirrorAssets(listing) }
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


private struct ProductThumbnail: View {
    let store: ProductStore
    let product: ProductDTO
    let token: String?
    @State private var image: UIImage?
    @State private var loading = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if loading { ProgressView() }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox").font(.system(size: 30, weight: .light))
                    Text("No preview").font(.caption2)
                }.foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
        .task(id: product.id + (product.cutoutPath ?? "") + store.thumbnailReloadID.uuidString) {
            guard let token else { return }
            loading = true
            defer { loading = false }
            do {
                let bytes = try await store.thumbnail(for: product.id, token: token)
                guard !Task.isCancelled else { return }
                image = UIImage(data: bytes)
            } catch { image = nil }
        }
    }
}
