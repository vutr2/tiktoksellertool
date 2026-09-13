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

    private var store: ProductStore { appEnvironment.products }
    private var mainCutout: ProductCutout? { cutouts.first }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSaving
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
            }

            continueButton
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showingMarketplaces) {
            if let product = savedProduct {
                MarketplacesView(product: product) { result in
                    onGenerated(result)
                    dismiss()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Back") { dismiss() }
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
        // Already saved: reopen step 3 rather than creating the product again.
        if savedProduct != nil {
            showingMarketplaces = true
            return
        }
        guard let token = appEnvironment.auth.token else {
            store.errorMessage = "Your session expired. Sign in again."
            return
        }

        Task {
            let created = await store.create(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                category: ProductDetailsView.trimmedOrNil(category),
                keyFeatures: ProductDetailsView.features(from: keyFeatures),
                cutoutPNG: mainCutout?.pngData,
                token: token
            )
            guard let created else { return }

            // Mirror for offline viewing only after the server confirmed it
            // (SPEC §9). Failing to cache must not fail the creation.
            modelContext.insert(ProductCacheMapper.cached(from: created))
            try? modelContext.save()

            onCreated(created)
            // Straight on to marketplace selection — the design is one flow,
            // not a save-and-come-back-later.
            savedProduct = created
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
