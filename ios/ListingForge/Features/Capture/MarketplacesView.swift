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

    let productID: String
    /// Called once generation finished, carrying the result to Review.
    var onGenerated: (GenerateResultDTO) -> Void

    @State private var selected: Set<String> = []
    @State private var scriptCount = 0
    @State private var showingPlans = false
    @State private var showingAIConsent = false
    @State private var confirmedQuoteKey: String?
    @State private var isSubmitting = false
    @State private var restoredChoices = false
    @State private var progressOwner: ProductProgressStore?

    init(product: ProductDTO, onGenerated: @escaping (GenerateResultDTO) -> Void) {
        self.init(productID: product.id, onGenerated: onGenerated)
    }

    init(productID: String, onGenerated: @escaping (GenerateResultDTO) -> Void) {
        self.productID = productID
        self.onGenerated = onGenerated
    }

    private var quoteKey: String { selected.sorted().joined(separator: ",") + ":\(scriptCount)" }

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
                        .disabled(isSubmitting || generation.pendingRequest(productID: productID) != nil)

                    if let message = generation.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(generation.needsMoreCredits ? .orange : .red)
                    }
                    if let message = appEnvironment.productProgress.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }

            footer
        }
        .background(Color(.systemGroupedBackground))
        .interactiveDismissDisabled(isSubmitting)
        .sheet(isPresented: $showingPlans) { PaywallView() }
        .sheet(isPresented: $showingAIConsent) {
            AIConsentView { generate() }
        }
        .task {
            let owner = appEnvironment.productProgress
            progressOwner = owner
            if !restoredChoices {
                let saved = appEnvironment.productProgress.progress(for: productID)
                if let pending = generation.pendingRequest(productID: productID) {
                    selected = Set(pending.marketplaces)
                    scriptCount = pending.scriptCount
                } else if let saved {
                    selected = Set(saved.marketplaces ?? [])
                    scriptCount = saved.scriptCount
                }
            }
            await appEnvironment.billing.refresh()
            await rules.load()
            if let token = appEnvironment.auth.token {
                await generation.loadBalance(token: token)
            }
            guard !Task.isCancelled, appEnvironment.productProgress === owner else { return }
            // TikTok Shop is the included tier, so it starts selected.
            if selected.isEmpty, appEnvironment.productProgress.progress(for: productID)?.marketplaces == nil,
               let included = rules.marketplaces.first(where: { $0.tier == "included" }) {
                selected.insert(included.id)
            }
            restoredChoices = true
            saveChoices()
            if let token = appEnvironment.auth.token,
               let result = await generation.recoverPending(productID: productID, token: token),
               appEnvironment.auth.token == token, !Task.isCancelled {
                appEnvironment.productProgress.update(productID) { $0.step = .review }
                onGenerated(result)
                dismiss()
            }
        }
        .task(id: quoteKey) { await requote() }
        .onChange(of: selected) { saveChoices() }
        .onChange(of: scriptCount) { saveChoices() }
    }

    private var header: some View {
        HStack {
            Button("Back") { dismiss() }
                .disabled(isSubmitting)
            Spacer()
            Text("Marketplaces").font(.headline)
            Spacer()
            Text("4 of 4").foregroundStyle(.secondary)
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
            guard appEnvironment.billing.status?.allowedMarketplaces.contains(marketplace.id) == true else {
                showingPlans = true
                return
            }
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
        .disabled(isSubmitting || generation.pendingRequest(productID: productID) != nil)
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
            if !selected.isEmpty, !generation.isQuoting, generation.quotedCredits == nil {
                Button("Retry credit estimate") { Task { await requote() } }
            }

            if generation.needsMoreCredits {
                Button("View plans and credits") { showingPlans = true }
            }
            Button(action: generate) {
                Group {
                    if generation.isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Text(generation.pendingRequest(productID: productID) == nil ? "Generate listing" : "Resume listing").font(.headline)
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

    private var canGenerate: Bool {
        !selected.isEmpty && !generation.isGenerating && !isSubmitting
            && !generation.isQuoting && confirmedQuoteKey == quoteKey
            && generation.quotedCredits != nil
    }

    private func requote() async {
        guard let token = appEnvironment.auth.token else { return }
        let issuedKey = quoteKey
        let store = generation
        confirmedQuoteKey = nil
        await store.quote(
            productID: productID,
            marketplaces: Array(selected).sorted(),
            scriptCount: scriptCount,
            token: token
        )
        guard !Task.isCancelled, appEnvironment.auth.token == token, quoteKey == issuedKey else { return }
        if store.quotedCredits != nil { confirmedQuoteKey = issuedKey }
    }

    private func generate() {
        guard canGenerate, let token = appEnvironment.auth.token else { return }
        guard appEnvironment.aiConsent.isGranted else {
            showingAIConsent = true
            return
        }
        isSubmitting = true
        let store = generation
        let marketplaces = selected.sorted()
        let scripts = scriptCount
        Task {
            defer { isSubmitting = false }
            // The result is taken from the call, not read back off the store:
            // shared state inspected after an await can still hold an earlier
            // successful run, which would dismiss on a failed request.
            let result = await store.generate(
                productID: productID,
                marketplaces: marketplaces,
                scriptCount: scripts,
                token: token
            )
            if let result, appEnvironment.auth.token == token {
                appEnvironment.productProgress.update(productID) { $0.step = .review }
                onGenerated(result)
                dismiss()
            }
        }
    }

    private func saveChoices() {
        guard restoredChoices, progressOwner === appEnvironment.productProgress else { return }
        appEnvironment.productProgress.update(productID) {
            $0.step = .listing
            $0.marketplaces = selected.sorted()
            $0.scriptCount = scriptCount
        }
    }
}
