//
//  StudioView.swift
//  ListingForge
//
//  Pick an industry and studio scenes, generate backdrops for the product
//  cutout, then preview and save the results to Photos.
//

import SwiftUI

struct StudioView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var store: StudioStore
    @State private var industry: Industry = .beauty
    @State private var selected: Set<String> = []
    @State private var saveNotice: String?

    init(productID: String, api: APIClient) {
        _store = State(initialValue: StudioStore(api: api, productID: productID))
    }

    private var scenes: [StudioScene] { store.scenes(for: industry) }
    private var cost: Int { selected.count * store.creditsPerImage }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.catalog.isEmpty {
                    ProgressView("Loading studio scenes…")
                } else if store.catalog.isEmpty {
                    ContentUnavailableView {
                        Label("Studio is unavailable", systemImage: "wand.and.stars")
                    } description: {
                        Text(store.errorMessage ?? "Please try again later.")
                    } actions: {
                        Button("Try again") { Task { await store.load(token: token ?? "") } }
                    }
                } else {
                    form
                }
            }
            .navigationTitle("Studio shots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.catalog.isEmpty, let token { await store.load(token: token) } }
        }
    }

    private var token: String? { appEnvironment.auth.token }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Industry", selection: $industry) {
                    ForEach(Industry.allCases) { industry in
                        Text("\(industry.emoji) \(industry.label)").tag(industry)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: industry) { selected.removeAll() }

                Text("Choose up to 4 scenes. Each costs \(store.creditsPerImage) credits.")
                    .font(.footnote).foregroundStyle(.secondary)

                ForEach(scenes) { scene in sceneCard(scene) }

                Button {
                    Task { await generate() }
                } label: {
                    if store.isGenerating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(selected.isEmpty ? "Select scenes to generate"
                             : "Generate \(selected.count) shot\(selected.count == 1 ? "" : "s") · \(cost) credits")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || store.isGenerating)

                if let message = store.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                if let saveNotice {
                    Label(saveNotice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
                }
            }
            .padding(20)
        }
    }

    private func sceneCard(_ scene: StudioScene) -> some View {
        let isSelected = selected.contains(scene.id)
        let generated = store.images[scene.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(scene.emoji) \(scene.name)").font(.headline)
                Spacer()
                if generated != nil {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
            }
            Text(scene.useCase).font(.subheadline).foregroundStyle(.secondary)

            if let url = generated {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().frame(height: 120)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Button {
                    Task { await save(url) }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                .font(.footnote)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture {
            guard generated == nil else { return }
            if isSelected { selected.remove(scene.id) }
            else if selected.count < 4 { selected.insert(scene.id) }
        }
    }

    private func generate() async {
        guard let token else { return }
        let ids = Array(selected)
        await store.generate(industry: industry, sceneIDs: ids, token: token)
        if store.errorMessage == nil { selected.removeAll() }
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
