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
                WorkflowHeader(title: "Studio shots", step: stepLabel, onBack: { dismiss() })
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        productCard
                        stylePicker
                        anglePicker
                        results
                        if let message = store.errorMessage {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                        if let message = store.cacheWarning ?? progress.errorMessage {
                            Text(message).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 22)
                    .background(WorkflowStyle.surface)
                }
                footer
            }
            .background(WorkflowStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .tint(.primary)
            .presentationDragIndicator(.hidden)
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
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                        .overlay { Image(systemName: "shippingbox").foregroundStyle(.secondary) }
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(productName).font(.footnote.weight(.semibold))
                Text("Source photo captured · BG removed").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            WorkflowPill(text: "Ready", tint: WorkflowStyle.green)
        }
        .workflowCard(padding: 11, radius: 14)
    }

    private var industryMenu: some View {
        Menu {
            Picker("Industry", selection: $industry) {
                ForEach(Industry.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(industry.label)
                Image(systemName: "chevron.down")
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Industry, \(industry.label)")
        .disabled(store.isGenerating)
    }

    // MARK: Style picker

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHOOSE A STYLE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                industryMenu
            }
            if store.isLoading && styles.isEmpty { ProgressView("Loading styles…") }
            if styles.isEmpty && !store.isLoading {
                Button("Retry loading styles") {
                    Task { if let token { await store.load(token: token) } }
                }.font(.subheadline).frame(minHeight: 44)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(styles) { style in styleCard(style) }
                }
            }
        }
    }

    private func styleCard(_ style: StudioScene) -> some View {
        let isSelected = selectedStyle == style.id
        return Button { selectedStyle = style.id } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image = store.results.first(where: { $0.sceneId == style.id }) {
                            StudioPhotoPreview(store: store, photo: image)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        } else {
                            StudioStyleIllustration(styleID: style.id, product: thumbnail)
                        }
                    }
                    .frame(width: 80, height: 88).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.subheadline).padding(4)
                    }
                }
                Text(style.name).font(.caption2.weight(isSelected ? .medium : .regular))
                    .lineLimit(2).multilineTextAlignment(.center).frame(width: 80).frame(minHeight: 24)
                    .foregroundStyle(isSelected ? WorkflowStyle.green : .primary)
            }
            .padding(6)
            .background(WorkflowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.green : WorkflowStyle.border, lineWidth: isSelected ? 1.5 : 0.8))
        }
        .buttonStyle(.plain)
        .disabled(store.isGenerating)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(style.name)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    // MARK: Angle picker

    private var anglePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ANGLES TO GENERATE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(angleOptions, id: \.self) { option in
                    let isSelected = angles == option
                    Button { angles = option } label: {
                        VStack(spacing: 2) {
                            Text("\(option) Angle\(option == 1 ? "" : "s")").font(.subheadline.weight(.semibold))
                            if option == 3 {
                                Text("Recommended").font(.caption2)
                                    .foregroundStyle(isSelected ? .green : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isSelected ? Color(white: 0.065) : WorkflowStyle.surface,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkflowStyle.border, lineWidth: isSelected ? 0 : 0.8))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isGenerating)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if !store.results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SAVED PHOTOS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { if let token { await store.load(token: token) } }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh saved photos")
                    .disabled(store.isGenerating || store.isLoading)
                }
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
                .font(.caption).foregroundStyle(.secondary)
            if let message = store.progressMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                generationTask = Task { await generate() }
            } label: {
                Group {
                    if store.isGenerating { ProgressView().tint(.white) }
                    else { Text(cost == 0 ? "Refresh saved photos" : "Generate studio shots") }
                }
            }
            .buttonStyle(WorkflowPrimaryButtonStyle())
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
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(WorkflowStyle.background)
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

struct StudioPhotoPreview: View {
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

/// A scene illustration using the actual cutout when available. Completed
/// renders replace these illustrations with the customer's saved photographs.
private struct StudioStyleIllustration: View {
    let styleID: String
    let product: UIImage?

    private var warm: Bool { styleID.contains("wood") || styleID.contains("lifestyle") || styleID.contains("sun") || styleID.contains("living") }
    private var dark: Bool { styleID.contains("black") || styleID.contains("dark") }

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [.gray, .black] : warm
                ? [Color(red: 0.86, green: 0.79, blue: 0.66), Color(red: 0.96, green: 0.93, blue: 0.85)]
                : [Color(white: 0.90), Color(white: 0.99)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack { Spacer(); Rectangle().fill(.white.opacity(dark ? 0.06 : 0.38)).frame(height: 25) }
            if styleID.contains("marble") {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 12))
                    path.addCurve(to: CGPoint(x: 88, y: 72), control1: CGPoint(x: 46, y: 4), control2: CGPoint(x: 12, y: 84))
                }.stroke(.gray.opacity(0.15), lineWidth: 2)
            }
            if let product {
                Image(uiImage: product).resizable().scaledToFit().padding(15)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 5)
            } else {
                Image(systemName: "shippingbox").font(.system(size: 25, weight: .ultraLight))
                    .foregroundStyle(dark ? .white.opacity(0.75) : .black.opacity(0.35))
            }
        }
        .accessibilityLabel("Style illustration")
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
