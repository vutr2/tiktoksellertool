//
//  ProductDetailsView.swift
//  ListingForge
//
//  Step 2 of 4 in the design: name the product that was just photographed.
//
//  This is where a session-only cutout becomes a real record. Until Continue
//  succeeds the photo exists nowhere but memory, so the screen never implies
//  the product is saved before the server says so.
//

import SwiftData
import SwiftUI

struct ProductDetailsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Cutouts from the capture series. The first is the main image.
    let cutouts: [ProductCutout]
    /// Called once the server has created the product.
    var onCreated: (ProductDTO) -> Void
    /// Called when generation finished, carrying the result to Review.
    var onGenerated: (GenerateResultDTO) -> Void

    @State private var name = ""
    @State private var category = ""
    @State private var keyFeatures = ""
    /// The product the server created. Kept separate from presentation state:
    /// `.sheet(item:)` nils its binding on dismiss, so backing out of step 3
    /// used to make Continue create a second product for the same photos.
    @State private var savedProduct: ProductDTO?
    @State private var showingMarketplaces = false
    @State private var isSubmitting = false
    @State private var draftID = UUID()
    @State private var hasSubmitted = false
    @State private var pendingResult: GenerateResultDTO?

    private var store: ProductStore { appEnvironment.products }
    private var mainCutout: ProductCutout? { cutouts.first }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    cutoutCard
                    field("Product name", text: $name, placeholder: "Ceramic pour-over dripper")
                    field("Category", text: $category, placeholder: "Home & Kitchen › Coffee")
                    featuresField

                    if let message = store.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
                .disabled(isSubmitting || hasSubmitted)

                if hasSubmitted && savedProduct == nil && !isSubmitting {
                    Button("Edit as a new draft") {
                        let draftStore = appEnvironment.captureDraft
                        draftStore.draft.id = UUID()
                        draftStore.draft.uploadStarted = false
                        draftID = draftStore.draft.id
                        hasSubmitted = false
                    }
                    .padding(.bottom)
                }
                if let warning = appEnvironment.captureDraft.errorMessage {
                    Text(warning).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
            }

            continueButton
        }
        .background(Color(.systemGroupedBackground))
        .interactiveDismissDisabled(isSubmitting)
        .task {
            let draft = appEnvironment.captureDraft.draft
            draftID = draft.id
            name = draft.name
            category = draft.category
            keyFeatures = draft.keyFeatures
            savedProduct = draft.savedProduct
            hasSubmitted = draft.uploadStarted
        }
        .onChange(of: name) { _, value in appEnvironment.captureDraft.draft.name = value }
        .onChange(of: category) { _, value in appEnvironment.captureDraft.draft.category = value }
        .onChange(of: keyFeatures) { _, value in appEnvironment.captureDraft.draft.keyFeatures = value }
        .sheet(isPresented: $showingMarketplaces, onDismiss: {
            if let result = pendingResult {
                pendingResult = nil
                onGenerated(result)
            }
        }) {
            if let product = savedProduct {
                MarketplacesView(product: product) { result in
                    pendingResult = result
                    showingMarketplaces = false
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Back") { dismiss() }
                .disabled(isSubmitting)
            Spacer()
            Text("Product details").font(.headline)
            Spacer()
            Text("2 of 4").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Cutout

    private var cutoutCard: some View {
        VStack(spacing: 12) {
            if let cutout = mainCutout, let image = UIImage(data: cutout.pngData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 220)
                    .overlay {
                        Text("No photo yet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
            }

            if mainCutout != nil {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Background removed on device")
                        .font(.footnote)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.green.opacity(0.15), in: Capsule())
                .foregroundStyle(.green)
            }

            if cutouts.count > 1 {
                Text("\(cutouts.count) angles captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Fields

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var featuresField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key features (optional)").font(.subheadline).foregroundStyle(.secondary)
            TextField("What makes it different?", text: $keyFeatures, axis: .vertical)
                .lineLimit(3...6)
                .padding(14)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Continue

    private var continueButton: some View {
        Button(action: save) {
            Group {
                if store.isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Continue").font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canContinue ? Color.black : Color.gray.opacity(0.4))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canContinue)
        .padding(20)
    }

    private func save() {
        guard !isSubmitting else { return }
        // Already saved: reopen step 3 rather than creating the product again.
        if savedProduct != nil {
            showingMarketplaces = true
            return
        }
        guard let token = appEnvironment.auth.token else {
            store.errorMessage = "Your session expired. Sign in again."
            return
        }
        let features = Self.features(from: keyFeatures)
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).count <= 200,
              category.count <= 300, features.count <= 10, features.allSatisfy({ $0.count <= 300 }) else {
            store.errorMessage = "Use a name up to 200 characters, a category up to 300 characters and up to 10 features of 300 characters each."
            return
        }

        isSubmitting = true
        hasSubmitted = true
        let currentStore = store
        let draftStore = appEnvironment.captureDraft
        draftStore.draft.uploadStarted = true
        let photos = cutouts.map(\.pngData)
        Task {
            defer { isSubmitting = false }
            let created = await currentStore.create(
                draftID: draftID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                category: ProductDetailsView.trimmedOrNil(category),
                keyFeatures: ProductDetailsView.features(from: keyFeatures),
                cutouts: photos,
                token: token
            )
            guard let created, appEnvironment.auth.token == token,
                  draftStore.draft.id == draftID else { return }

            // Mirror for offline viewing only after the server confirmed it
            // (SPEC §9). Failing to cache must not fail the creation.
            modelContext.insert(ProductCacheMapper.cached(from: created))
            do { try modelContext.save() }
            catch { currentStore.errorMessage = "Your product is saved online, but its offline copy could not be saved." }

            onCreated(created)
            // Straight on to marketplace selection — the design is one flow,
            // not a save-and-come-back-later.
            savedProduct = created
            draftStore.draft.savedProduct = created
            showingMarketplaces = true
        }
    }

    /// Splits the free-text box into the list the API expects.
    ///
    /// One feature per line, and only per line. Splitting on commas as well cut
    /// legitimate text in half — "Fits 02, 03 and 04 filters" became two
    /// features, neither of them true.
    static func features(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
