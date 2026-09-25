//
//  ScriptsView.swift
//  ListingForge
//
//  Lists the product's 30-second video scripts; tap one to open the 9:16
//  preview player.
//

import SwiftUI

struct ScriptsView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var store: ScriptsStore

    init(productID: String, api: APIClient) {
        _store = State(initialValue: ScriptsStore(api: api, productID: productID))
    }

    private var token: String? { appEnvironment.auth.token }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.scripts.isEmpty {
                    ProgressView("Loading scripts…")
                } else if store.scripts.isEmpty {
                    ContentUnavailableView {
                        Label("No scripts yet", systemImage: "film")
                    } description: {
                        Text("Generate five 30-second video scripts, each with a 3-second hook.")
                    } actions: {
                        generateButton
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Video scripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.scripts.isEmpty, let token { await store.load(token: token) } }
        }
    }

    private var list: some View {
        List {
            ForEach(Array(store.scripts.enumerated()), id: \.element.id) { index, script in
                NavigationLink {
                    ScrollView { ScriptPlayerView(script: script).padding() }
                        .navigationTitle("Script \(index + 1)")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    row(index: index, script: script)
                }
            }
            Section {
                generateButton
                if let message = store.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    private func row(index: Int, script: ScriptShape) -> some View {
        let total = VideoScriptTimeline.totalSeconds(VideoScriptTimeline.build(script))
        return VStack(alignment: .leading, spacing: 4) {
            Text("Script \(index + 1)").font(.headline)
            Text(script.hook.onScreenText.isEmpty ? script.hook.voiceover : script.hook.onScreenText)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Text("\(script.scenes.count + 1) beats · \(VideoScriptTimeline.mmss(total))")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var generateButton: some View {
        Button {
            Task {
                if let token { await store.generate(language: appEnvironment.language.language, token: token) }
            }
        } label: {
            if store.isGenerating {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(store.scripts.isEmpty ? "Generate scripts" : "Regenerate scripts")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isGenerating)
    }
}
