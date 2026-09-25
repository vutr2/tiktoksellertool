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
    @State private var showingScriptOptions = false

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
    private var hasLockedSelection: Bool {
        guard let status = appEnvironment.billing.status else { return false }
        return selected.contains { !status.allowedMarketplaces.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headline.padding(.bottom, 16)
                    if rules.isLoading { ProgressView("Loading marketplaces…") }
                    if rules.loadFailed {
                        Button("Retry loading marketplaces") { Task { await rules.load() } }
                            .font(.subheadline)
                    }
                    ForEach(rules.marketplaces) { marketplace in
                        row(marketplace)
                    }
                    DisclosureGroup("Ad scripts · optional", isExpanded: $showingScriptOptions) { scriptsRow }
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
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
                .padding(.horizontal, 22).padding(.bottom, 18)
                .background(WorkflowStyle.surface)
            }

            footer
        }
        .background(WorkflowStyle.background)
        .tint(.primary)
        .presentationDragIndicator(.hidden)
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
        WorkflowHeader(title: "Marketplaces", step: "3 of 4", isBusy: isSubmitting) { dismiss() }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One photo, four sets of rules.")
                .font(.title3.weight(.bold))
            Text("We check every asset against the rules for each marketplace you pick.")
                .font(.subheadline).foregroundStyle(.secondary)
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
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkflowStyle.border))
                    .frame(width: 21, height: 21)

                VStack(alignment: .leading, spacing: 4) {
                    Text(marketplace.displayName).font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected.contains(marketplace.id) ? .primary : .secondary)
                    Text(marketplace.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                WorkflowPill(text: marketplace.requiresProPlan ? "Pro" : "Included",
                             tint: marketplace.requiresProPlan ? WorkflowStyle.amber : WorkflowStyle.green)
            }
            .frame(minHeight: 38)
            .workflowCard(padding: 14, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected.contains(marketplace.id) ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected.contains(marketplace.id) ? .isSelected : [])
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
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text(costCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !selected.isEmpty, !generation.isQuoting, generation.quotedCredits == nil {
                Button("Retry credit estimate") { Task { await requote() } }
            }

            if generation.needsMoreCredits {
                Button("View plans and credits") { showingPlans = true }
            }
            Button {
                if hasLockedSelection { showingPlans = true } else { generate() }
            } label: {
                Group {
                    if generation.isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Text(hasLockedSelection ? "Unlock selected marketplaces" :
                            generation.pendingRequest(productID: productID) == nil ? "Generate listing" : "Resume listing")
                    }
                }
            }
            .buttonStyle(WorkflowPrimaryButtonStyle())
            .disabled(hasLockedSelection ? isSubmitting || generation.isGenerating : !canGenerate)
        }
        .padding(20)
    }

    /// The estimate and available balance come from the server.
    private var costCaption: String {
        guard let credits = generation.quotedCredits else { return "Estimated cost · —" }
        guard let balance = generation.balance else { return "Estimated cost · \(credits) credits" }
        return "Estimated cost · \(credits) credits · \(balance) available"
    }

    private var canGenerate: Bool {
        !selected.isEmpty && !generation.isGenerating && !isSubmitting
            && !hasLockedSelection
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
        let language = appEnvironment.language.language
        Task {
            defer { isSubmitting = false }
            // The result is taken from the call, not read back off the store:
            // shared state inspected after an await can still hold an earlier
            // successful run, which would dismiss on a failed request.
            let result = await store.generate(
                productID: productID,
                marketplaces: marketplaces,
                scriptCount: scripts,
                language: language,
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
