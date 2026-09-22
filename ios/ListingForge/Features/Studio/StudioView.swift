//
//  StudioView.swift
//  ListingForge
//
//  Step "Studio shots": pick one style and how many angles, generate studio
//  backdrops for the product cutout, then preview and save to Photos.
//

import SwiftUI

struct StudioView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: StudioStore
    @State private var industry: Industry
    @State private var selectedStyle: String?
    @State private var angles = 3
    @State private var saveNotice: String?
    @State private var generationTask: Task<Void, Never>?
    private let progress: ProductProgressStore

    let productName: String
    let thumbnail: UIImage?
    /// Shown in the header, e.g. "3 of 4" when part of the capture flow.
    let stepLabel: String?
    /// When set, shows a "Continue to listing" button to advance the wizard.
    let onContinue: (() -> Void)?

    private let angleOptions = [1, 3, 5]

    init(store: StudioStore, progress: ProductProgressStore, productName: String = "Your product",
         thumbnail: UIImage? = nil, industry: Industry = .beauty, stepLabel: String? = nil,
         onContinue: (() -> Void)? = nil) {
        let saved = progress.progress(for: store.productID)
        _store = State(initialValue: store)
        _industry = State(initialValue: saved?.industry ?? industry)
        _selectedStyle = State(initialValue: saved?.styleID)
        _angles = State(initialValue: [1, 3, 5].contains(saved?.angles ?? 3) ? saved?.angles ?? 3 : 3)
        self.progress = progress
        self.productName = productName
        self.thumbnail = thumbnail
        self.stepLabel = stepLabel
        self.onContinue = onContinue
    }

    private var token: String? { appEnvironment.auth.token }
    private var styles: [StudioScene] { store.scenes(for: industry) }
    private var cost: Int { store.uncachedCount(sceneID: selectedStyle, count: angles) * store.creditsPerImage }
    private var balance: Int? { store.balanceAfter ?? appEnvironment.billing.status?.balance }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        productCard
                        industryMenu
                            .disabled(store.isGenerating)
                        stylePicker
                            .allowsHitTesting(!store.isGenerating)
                        anglePicker
                            .allowsHitTesting(!store.isGenerating)
                        results
                        if let message = store.errorMessage {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                        if let message = store.cacheWarning ?? progress.errorMessage {
                            Text(message).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding(20)
                }
                footer
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Studio shots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { if let token { await store.load(token: token) } }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh saved photos")
                    .disabled(store.isGenerating || store.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let stepLabel { ToolbarItem(placement: .principal) { Text(stepLabel).foregroundStyle(.secondary) } }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                if !store.isGenerating, let token { await store.load(token: token) }
                if selectedStyle == nil, progress.progress(for: store.productID) == nil,
                   let saved = store.results.last,
                   let entry = store.catalog.first(where: { $0.value.contains(where: { $0.id == saved.sceneId }) }) {
                    industry = entry.key
                    selectedStyle = saved.sceneId
                }
                if !styles.isEmpty, !styles.contains(where: { $0.id == selectedStyle }) {
                    selectedStyle = styles.first?.id
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background { generationTask?.cancel() }
            }
            .onDisappear { generationTask?.cancel() }
            .onChange(of: industry) {
                if !styles.contains(where: { $0.id == selectedStyle }) { selectedStyle = styles.first?.id }
                saveChoices()
            }
            .onChange(of: selectedStyle) { saveChoices() }
            .onChange(of: angles) { saveChoices() }
        }
    }

    // MARK: Product card

    private var productCard: some View {
        HStack(spacing: 14) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                        .overlay { Image(systemName: "shippingbox").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(productName).font(.headline)
                Text("Source photo captured · BG removed").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Ready").font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var industryMenu: some View {
        Picker("Industry", selection: $industry) {
            ForEach(Industry.allCases) { Text("\($0.emoji) \($0.label)").tag($0) }
        }
        .pickerStyle(.menu)
    }

    // MARK: Style picker

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHOOSE A STYLE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(styles) { style in styleCard(style) }
                }
            }
        }
    }

    private func styleCard(_ style: StudioScene) -> some View {
        let isSelected = selectedStyle == style.id
        return VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color(.tertiarySystemFill), Color(.secondarySystemBackground)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 120, height: 120)
                    .overlay { Text(style.emoji).font(.largeTitle) }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            Text(style.name).font(.subheadline)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { selectedStyle = style.id }
    }

    // MARK: Angle picker

    private var anglePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ANGLES TO GENERATE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(angleOptions, id: \.self) { option in
                    let isSelected = angles == option
                    VStack(spacing: 2) {
                        Text("\(option) Angle\(option == 1 ? "" : "s")").font(.subheadline.weight(.semibold))
                        if option == 3 {
                            Text("Recommended").font(.caption2)
                                .foregroundStyle(isSelected ? .green : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isSelected ? Color.black : Color(.systemBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: isSelected ? 0 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture { angles = option }
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if !store.results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("RESULTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Label("Saved automatically to this product", systemImage: "checkmark.icloud")
                    .font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(store.results) { image in
                        VStack(spacing: 6) {
                            StudioPhotoPreview(store: store, photo: image)
                            Button { Task { await save(image) } } label: {
                                Label("Save to Photos", systemImage: "square.and.arrow.down").font(.caption)
                            }
                        }
                    }
                }
                if let saveNotice {
                    Label(saveNotice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if selectedStyle != nil {
                Text("\(angles - store.uncachedCount(sceneID: selectedStyle, count: angles)) of \(angles) photos saved for this style")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Estimated cost · \(cost) credits" + (balance.map { " · \($0) available" } ?? ""))
                .font(.footnote).foregroundStyle(.secondary)
            if let message = store.progressMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                generationTask = Task { await generate() }
            } label: {
                Group {
                    if store.isGenerating { ProgressView().tint(.white) }
                    else { Text(cost == 0 ? "Refresh saved photos" : "Generate remaining photos").font(.headline) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(selectedStyle == nil ? Color.gray.opacity(0.4) : Color.black)
                .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(selectedStyle == nil || store.isGenerating || store.isLoading)

            if let onContinue {
                Button {
                    progress.update(store.productID) { $0.step = .listing }
                    onContinue()
                    dismiss()
                } label: {
                    Text(store.results.isEmpty ? "Skip · continue to listing" : "Continue to listing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.bar)
    }

    private func generate() async {
        guard let token, let style = selectedStyle else { return }
        saveChoices()
        saveNotice = nil
        await store.generate(industry: industry, sceneID: style, count: angles, token: token)
        if !Task.isCancelled { await appEnvironment.billing.refresh() }
    }

    private func saveChoices() {
        progress.update(store.productID) {
            $0.industry = industry
            $0.styleID = selectedStyle
            $0.angles = angles
        }
    }

    private func save(_ photo: StudioImage) async {
        do {
            let data = try await store.imageData(for: photo)
            guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            try await PhotoLibrarySaver.save(image)
            saveNotice = "Saved to Photos."
        } catch {
            store.errorMessage = "Could not save the image. Check Photos permission in Settings."
        }
    }
}

private struct StudioPhotoPreview: View {
    let store: StudioStore
    let photo: StudioImage
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                    Text("Preview unavailable").font(.caption)
                    Button("Retry preview") { attempt += 1 }.font(.caption)
                }.frame(height: 140)
            } else { ProgressView().frame(height: 140) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: "\(photo.hashValue)-\(attempt)") {
            failed = false
            do {
                let data = try await store.imageData(for: photo)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data)
                failed = image == nil
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

/// Wraps the callback-based Photos add API in async/await.
enum PhotoLibrarySaver {
    private final class Delegate: NSObject {
        let continuation: CheckedContinuation<Void, Error>
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        @objc func done(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            Unmanaged<Delegate>.fromOpaque(context!).release()
        }
    }

    @MainActor
    static func save(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = Delegate(continuation)
            let context = Unmanaged.passRetained(delegate).toOpaque()
            UIImageWriteToSavedPhotosAlbum(image, delegate,
                #selector(Delegate.done(_:error:context:)), context)
        }
    }
}
