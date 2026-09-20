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

    @State private var store: StudioStore
    @State private var industry: Industry
    @State private var selectedStyle: String?
    @State private var angles = 3
    @State private var saveNotice: String?

    let productName: String
    let thumbnail: UIImage?
    /// Shown in the header, e.g. "3 of 4" when part of the capture flow.
    let stepLabel: String?
    /// When set, shows a "Continue to listing" button to advance the wizard.
    let onContinue: (() -> Void)?

    private let angleOptions = [1, 3, 5]

    init(productID: String, api: APIClient, productName: String = "Your product",
         thumbnail: UIImage? = nil, industry: Industry = .beauty, stepLabel: String? = nil,
         onContinue: (() -> Void)? = nil) {
        _store = State(initialValue: StudioStore(api: api, productID: productID))
        _industry = State(initialValue: industry)
        self.productName = productName
        self.thumbnail = thumbnail
        self.stepLabel = stepLabel
        self.onContinue = onContinue
    }

    private var token: String? { appEnvironment.auth.token }
    private var styles: [StudioScene] { store.scenes(for: industry) }
    private var cost: Int { angles * store.creditsPerImage }
    private var balance: Int? { appEnvironment.billing.status?.balance }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        productCard
                        industryMenu
                        stylePicker
                        anglePicker
                        results
                        if let message = store.errorMessage {
                            Text(message).font(.footnote).foregroundStyle(.red)
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let stepLabel { ToolbarItem(placement: .principal) { Text(stepLabel).foregroundStyle(.secondary) } }
            }
            .task {
                if store.catalog.isEmpty, let token { await store.load(token: token) }
                if selectedStyle == nil { selectedStyle = styles.first?.id }
            }
            .onChange(of: industry) { selectedStyle = styles.first?.id }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(store.results) { image in
                        if let raw = image.url, let url = URL(string: raw) {
                            VStack(spacing: 6) {
                                AsyncImage(url: url) { $0.resizable().scaledToFit() }
                                    placeholder: { ProgressView().frame(height: 140) }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Button { Task { await save(url) } } label: {
                                    Label("Save", systemImage: "square.and.arrow.down").font(.caption)
                                }
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
            Text("Estimated cost · \(cost) credits" + (balance.map { " of your \($0) this month" } ?? ""))
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                Task { await generate() }
            } label: {
                Group {
                    if store.isGenerating { ProgressView().tint(.white) }
                    else { Text("Generate studio shots").font(.headline) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(selectedStyle == nil ? Color.gray.opacity(0.4) : Color.black)
                .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(selectedStyle == nil || store.isGenerating)

            if let onContinue {
                Button {
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
        saveNotice = nil
        await store.generate(industry: industry, sceneID: style, count: angles, token: token)
    }

    private func save(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            try await PhotoLibrarySaver.save(image)
            saveNotice = "Saved to Photos."
        } catch {
            store.errorMessage = "Could not save the image. Check Photos permission in Settings."
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
