//
//  ProductDetailsView.swift
//  ListingForge
//
//  Step 2 of 4 in the design: name the product that was just photographed.
//
//  Draft photos/details are saved on this device; Continue uploads the product.
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
    @State private var industry: Industry = .beauty
    @State private var showingStudio = false
    @State private var advanceToMarketplaces = false
    @State private var restoredDraft = false

    private var store: ProductStore { appEnvironment.products }
    private var mainCutout: ProductCutout? { cutouts.first }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cutoutCard
                    field("Product name", text: $name, placeholder: "Ceramic pour-over dripper")
                    categoryField
                    featuresField

                    if let message = store.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
                .background(WorkflowStyle.surface)
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
        .background(WorkflowStyle.background)
        .tint(.primary)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isSubmitting)
        .task {
            guard !restoredDraft else { return }
            let draft = appEnvironment.captureDraft.draft
            draftID = draft.id
            name = draft.name
            category = draft.category
            keyFeatures = draft.keyFeatures
            savedProduct = draft.savedProduct
            hasSubmitted = draft.uploadStarted
            industry = draft.industry ?? .beauty
            restoredDraft = true
            if let product = draft.savedProduct {
                let step = appEnvironment.productProgress.progress(for: product.id)?.step ?? .studio
                if step == .listing { showingMarketplaces = true }
                else { showingStudio = true }
            }
        }
        .onChange(of: name) { _, value in appEnvironment.captureDraft.draft.name = value }
        .onChange(of: category) { _, value in appEnvironment.captureDraft.draft.category = value }
        .onChange(of: keyFeatures) { _, value in appEnvironment.captureDraft.draft.keyFeatures = value }
        .onChange(of: industry) { _, value in appEnvironment.captureDraft.draft.industry = value }
        .sheet(isPresented: $showingStudio, onDismiss: {
            if advanceToMarketplaces {
                advanceToMarketplaces = false
                showingMarketplaces = true
            }
        }) {
            if let product = savedProduct {
                StudioView(
                    store: appEnvironment.studio(for: product.id),
                    progress: appEnvironment.productProgress,
                    productName: product.name,
                    thumbnail: mainCutout.flatMap { UIImage(data: $0.pngData) },
                    industry: industry,
                    stepLabel: "3 of 4",
                    onContinue: { advanceToMarketplaces = true }
                )
            }
        }
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
        WorkflowHeader(title: "Product details", step: "2 of 4", isBusy: isSubmitting) { dismiss() }
    }

    // MARK: Cutout

    private var cutoutCard: some View {
        VStack(spacing: 12) {
            if let cutout = mainCutout, let image = UIImage(data: cutout.pngData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 140)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 140)
                    .overlay {
                        Text("No photo yet")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
            }

            if mainCutout != nil {
                HStack(spacing: 8) {
                    Circle().fill(WorkflowStyle.green).frame(width: 5, height: 5)
                    Text("Background removed on device")
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(WorkflowStyle.green.opacity(0.10), in: Capsule())
                .foregroundStyle(WorkflowStyle.green)
            }

            if cutouts.count > 1 {
                Text("\(cutouts.count) angles captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .workflowCard(padding: 16, radius: 14)
    }

    // MARK: Fields

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .font(.subheadline)
                .workflowCard(padding: 13)
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Category").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Industry", selection: $industry) {
                        ForEach(Industry.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(industry.label)
                        Image(systemName: "chevron.down")
                    }.font(.caption2).foregroundStyle(.secondary)
                }.accessibilityLabel("Industry, \(industry.label)")
            }
            TextField("Home & Kitchen › Coffee", text: $category)
                .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                .font(.subheadline).workflowCard(padding: 13)
        }
    }

    private var featuresField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key features (optional)").font(.caption).foregroundStyle(.secondary)
            TextField("What makes it different?", text: $keyFeatures, axis: .vertical)
                .lineLimit(1...4).font(.subheadline)
                .workflowCard(padding: 13)
        }
    }

    // MARK: Continue

    private var continueButton: some View {
        Button(action: save) {
            Group {
                if store.isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text("Continue")
                }
            }
        }
        .buttonStyle(WorkflowPrimaryButtonStyle())
        .disabled(!canContinue)
        .padding(20)
    }

    private func save() {
        guard !isSubmitting else { return }
        // Already saved: reopen the studio step rather than creating it again.
        if savedProduct != nil {
            showingStudio = true
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
                industry: industry,
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
            // Persist the next step before presenting it, so relaunch can resume.
            savedProduct = created
            draftStore.draft.savedProduct = created
            appEnvironment.productProgress.update(created.id) {
                $0.industry = industry
                $0.step = .studio
            }
            showingStudio = true
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
