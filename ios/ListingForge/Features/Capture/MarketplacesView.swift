//
//  MarketplacesView.swift
//  ListingForge
//
//  Step 3 of 4: pick the marketplaces to generate for.
//
//  The rows are built from the rules the API serves, so adding a marketplace or
//  changing its one-line summary needs no app release (SPEC §7).
//

import SwiftUI

struct MarketplacesView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let product: ProductDTO
    /// Called once generation finished, carrying the result to Review.
    var onGenerated: (GenerateResultDTO) -> Void

    @State private var selected: Set<String> = []
    @State private var scriptCount = 0

    private var rules: RulesStore { appEnvironment.rules }
    private var generation: GenerationStore { appEnvironment.generation }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline
                    ForEach(rules.marketplaces) { marketplace in
                        row(marketplace)
                    }
                    scriptsRow

                    if let message = generation.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(generation.needsMoreCredits ? .orange : .red)
                    }
                }
                .padding(20)
            }

            footer
        }
        .background(Color(.systemGroupedBackground))
        .task {
            await rules.load()
            if let token = appEnvironment.auth.token {
                await generation.loadBalance(token: token)
            }
            // TikTok Shop is the included tier, so it starts selected.
            if selected.isEmpty,
               let included = rules.marketplaces.first(where: { $0.tier == "included" }) {
                selected.insert(included.id)
            }
            await requote()
        }
        .onChange(of: selected) { _, _ in Task { await requote() } }
        .onChange(of: scriptCount) { _, _ in Task { await requote() } }
    }

    private var header: some View {
        HStack {
            Button("Back") { dismiss() }
            Spacer()
            Text("Marketplaces").font(.headline)
            Spacer()
            Text("3 of 4").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One photo, four sets of rules.")
                .font(.largeTitle.bold())
            Text("We check every asset against the rules for each marketplace you pick.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ marketplace: MarketplaceRulesDTO) -> some View {
        Button {
            if selected.contains(marketplace.id) { selected.remove(marketplace.id) }
            else { selected.insert(marketplace.id) }
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected.contains(marketplace.id) ? Color.primary : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.5)))
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(marketplace.displayName).font(.headline)
                    Text(marketplace.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // TODO(M5): a Starter seller tapping a Pro marketplace must get
                // the paywall sheet (SPEC §6). Subscription state does not exist
                // yet, so the badge is informational yet everything is选択able.
                Text(marketplace.requiresProPlan ? "Pro" : "Included")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(marketplace.requiresProPlan ? .yellow.opacity(0.25) : .green.opacity(0.2),
                                in: Capsule())
                    .foregroundStyle(marketplace.requiresProPlan ? .orange : .green)
            }
            .padding(16)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var scriptsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ad scripts").font(.headline)
                Text("Short-form video hooks").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Stepper("\(scriptCount)", value: $scriptCount, in: 0...5)
                .fixedSize()
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text(costCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: generate) {
                Group {
                    if generation.isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Text("Generate listing").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canGenerate ? Color.black : Color.gray.opacity(0.4))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canGenerate)
        }
        .padding(20)
    }

    /// "Estimated cost · 6 credits of your 394 this month", matching the design.
    private var costCaption: String {
        guard let credits = generation.quotedCredits else { return "Estimated cost · —" }
        guard let balance = generation.balance else { return "Estimated cost · \(credits) credits" }
        return "Estimated cost · \(credits) credits of your \(balance) this month"
    }

    private var canGenerate: Bool { !selected.isEmpty && !generation.isGenerating }

    private func requote() async {
        guard let token = appEnvironment.auth.token else { return }
        await generation.quote(
            productID: product.id,
            marketplaces: Array(selected).sorted(),
            scriptCount: scriptCount,
            token: token
        )
    }

    private func generate() {
        guard let token = appEnvironment.auth.token else { return }
        Task {
            // The result is taken from the call, not read back off the store:
            // shared state inspected after an await can still hold an earlier
            // successful run, which would dismiss on a failed request.
            let result = await generation.generate(
                productID: product.id,
                marketplaces: Array(selected).sorted(),
                scriptCount: scriptCount,
                token: token
            )
            if let result {
                onGenerated(result)
                dismiss()
            }
        }
    }
}
