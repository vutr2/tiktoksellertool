//
//  ReviewView.swift
//  ListingForge
//
//  Step 4 of 4: the listing the seller paid for.
//
//  One view serves both paths — straight after generation and reopened later
//  from Products — because a listing that cannot be found again after the app
//  closes is work the seller was charged for and cannot use (Guideline 2.1).
//

import SwiftUI

/// The shape Review needs, so a freshly generated result and a stored listing
/// can be shown by the same code.
struct ReviewAsset: Identifiable, Hashable {
    let id: String
    let type: String
    let marketplace: String
    let content: String
    let status: ComplianceStatus
    let violations: [ViolationDTO]

    var displayedStatus: ComplianceStatus {
        if status == .fail || violations.contains(where: \.isFailure) { return .fail }
        if status == .warn || !violations.isEmpty { return .warn }
        return .pass
    }

    init(_ stored: StoredAssetDTO) {
        id = stored.id
        type = stored.type
        marketplace = stored.marketplace
        content = stored.content
        status = stored.compliance
        violations = stored.violations
    }

    init(_ generated: GeneratedAssetDTO) {
        id = generated.id
        type = generated.type
        marketplace = generated.marketplace
        content = generated.content
        status = generated.status
        violations = generated.violations
    }
}

struct ReviewView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let productName: String
    let assets: [ReviewAsset]
    var productID: String? = nil
    /// Marketplaces that produced nothing, so a silent gap is never mistaken
    /// for a clean result.
    var failures: [GenerationFailureDTO] = []
    var notice: String? = nil

    @State private var selectedMarketplace: String?
    @State private var reportingAsset: ReviewAsset?
    @State private var copiedAssetID: String?
    @State private var showStudio = false
    @State private var showScripts = false
    @State private var showMarketplaces = false
    @State private var advanceToListing = false
    @State private var resumedListing: GenerateResultDTO?

    private var listingAssets: [ReviewAsset] {
        // Studio images have their own gallery. They are not text assets or
        // marketplaces, and must not render as empty "Pass" cards here.
        (resumedListing?.assets.map(ReviewAsset.init) ?? assets).filter { $0.type != "image" }
    }
    private var listingFailures: [GenerationFailureDTO] { resumedListing?.failures ?? failures }

    private var marketplaces: [String] {
        var seen: [String] = []
        for asset in listingAssets where !seen.contains(asset.marketplace) { seen.append(asset.marketplace) }
        for failure in listingFailures where !seen.contains(failure.marketplace) { seen.append(failure.marketplace) }
        return seen
    }

    private var current: String? {
        if let selectedMarketplace, marketplaces.contains(selectedMarketplace) { return selectedMarketplace }
        return marketplaces.first
    }

    private var shown: [ReviewAsset] {
        guard let current else { return [] }
        return listingAssets.filter { $0.marketplace == current }
    }

    private var currentFailure: GenerationFailureDTO? {
        guard let current else { return nil }
        return listingFailures.first { $0.marketplace == current }
    }

    @State private var expandedAssets: Set<String> = []
    @State private var showConversion = false
    @State private var conversionTarget: String?

    private var studio: StudioStore? { productID.map { appEnvironment.studio(for: $0) } }
    private var firstIssue: ViolationDTO? {
        shown.flatMap(\.violations).first(where: \.isFailure) ?? shown.flatMap(\.violations).first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !marketplaces.isEmpty { chips }
                    photoStrip
                    if let notice {
                        Label(notice, systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure = currentFailure { failureBanner(failure) }
                    if marketplaces.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your product is saved").font(.headline)
                            Text("Open Studio photos or continue creating your listing whenever you’re ready.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, asset in
                        assetCard(asset, rowID: "\(asset.id)-\(index)")
                    }
                    if !shown.isEmpty {
                        Text("AI-generated content. Review product facts before publishing.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if productID != nil { savedWorkActions }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkflowStyle.surface)
            }
            footer
        }
        .background(WorkflowStyle.background)
        .tint(.primary)
        .presentationDragIndicator(.hidden)
        .task(id: showStudio) {
            if !showStudio, let studio, let token = appEnvironment.auth.token { await studio.load(token: token) }
        }
        .sheet(item: $reportingAsset) { asset in
            if let productID { ContentReportView(productID: productID, asset: asset) }
        }
        .sheet(isPresented: $showStudio, onDismiss: {
            if advanceToListing { advanceToListing = false; showMarketplaces = true }
        }) {
            if let studio {
                StudioView(store: studio, progress: appEnvironment.productProgress,
                           productName: productName, onContinue: { advanceToListing = true })
            }
        }
        .sheet(isPresented: $showMarketplaces) {
            if let productID {
                MarketplacesView(productID: productID) { result in
                    resumedListing = result
                    showMarketplaces = false
                    if appEnvironment.captureDraft.draft.savedProduct?.id.lowercased() == productID.lowercased() {
                        appEnvironment.captureDraft.reset()
                    }
                }
            }
        }
        .sheet(isPresented: $showScripts) {
            if let productID { ScriptsView(productID: productID, api: appEnvironment.api) }
        }
        .sheet(isPresented: $showConversion, onDismiss: {
            if let target = conversionTarget, let productID {
                conversionTarget = nil
                appEnvironment.productProgress.update(productID) { $0.marketplaces = [target] }
                showMarketplaces = true
            }
        }) {
            if let current {
                ConvertView(source: current, assets: shown) { conversionTarget = $0 }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("Back").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            Text("Review").fontWeight(.semibold).frame(maxWidth: .infinity)
            Group {
                if let text = exportText, !text.isEmpty {
                    ShareLink(item: text) {
                        Text("Export").fontWeight(.semibold).frame(minHeight: 44)
                    }
                } else { Text("Export").foregroundStyle(.tertiary) }
            }.frame(width: 60, alignment: .trailing)
        }
        .font(.subheadline).padding(.horizontal, 22).frame(minHeight: 64)
    }

    @ViewBuilder private var photoStrip: some View {
        if let studio {
            if studio.isLoading && studio.results.isEmpty {
                ProgressView("Loading saved photos…").font(.caption).padding(.vertical, 8)
            }
            if let message = studio.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Reload saved photos") {
                        Task { if let token = appEnvironment.auth.token { await studio.load(token: token) } }
                    }.font(.caption).disabled(studio.isLoading)
                }.padding(.vertical, 6)
            }
            if !studio.results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(studio.results) { photo in
                            VStack(alignment: .leading, spacing: 8) {
                                StudioPhotoPreview(store: studio, photo: photo)
                                    .frame(width: 154, height: 160)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkflowStyle.border, lineWidth: 0.8))
                                HStack {
                                    Text("Angle \(photo.index + 1)").font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    WorkflowPill(text: "Saved", tint: WorkflowStyle.green)
                                }
                            }.frame(width: 154)
                        }
                    }
                }
                Text("Studio photos · review image requirements before publishing.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var savedWorkActions: some View {
        HStack(spacing: 20) {
            Button { showStudio = true } label: {
                Label("Studio photos", systemImage: "photo.on.rectangle")
            }
            Spacer(minLength: 0)
            Menu {
                Button("Generate listing content") { showMarketplaces = true }
                Button("Video scripts") { showScripts = true }
            } label: { Label("More", systemImage: "ellipsis") }
        }
        .font(.caption).padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = firstIssue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.message).font(.subheadline.weight(.medium))
                    if let detail = issue.detail { Text(detail).font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .foregroundStyle(issue.isFailure ? WorkflowStyle.red : WorkflowStyle.amber)
                .background((issue.isFailure ? WorkflowStyle.red : WorkflowStyle.amber).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 13))
            }
            if productID != nil {
                Button {
                    if shown.isEmpty { showMarketplaces = true }
                    else { showConversion = true }
                } label: {
                    Text(shown.isEmpty ? "Continue listing" : "Check another marketplace · free")
                }.buttonStyle(WorkflowPrimaryButtonStyle())
            }
        }.padding(22)
    }

    /// Everything for the selected marketplace, ready to paste into it.
    private var exportText: String? {
        guard let current else { return nil }
        let name = displayName(current)
        let body = shown
            .map { asset in
                let violations = asset.violations.map { violation in
                    [violation.message, violation.detail].compactMap { $0 }.joined(separator: " ")
                }.joined(separator: "\n")
                return "\(asset.type.capitalized) — \(asset.displayedStatus.rawValue.capitalized)\n\(asset.content)"
                    + (violations.isEmpty ? "" : "\nChecks to review:\n\(violations)")
            }
            .joined(separator: "\n\n")
        let failure = currentFailure.map { "\n\nGeneration incomplete: \($0.reason)" } ?? ""
        return body.isEmpty ? nil : "\(productName) — \(name)\n\n\(body)\(failure)"
    }

    // MARK: Marketplace chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(marketplaces, id: \.self) { marketplace in
                    let isSelected = marketplace == current
                    Button { selectedMarketplace = marketplace } label: {
                        Text(displayName(marketplace))
                            .font(.caption.weight(isSelected ? .medium : .regular))
                            .padding(.horizontal, 13).frame(minHeight: 32)
                            .background(isSelected ? Color.primary : WorkflowStyle.surface, in: Capsule())
                            .foregroundStyle(isSelected ? Color(.systemBackground) : .secondary)
                            .overlay(Capsule().stroke(WorkflowStyle.border, lineWidth: isSelected ? 0 : 0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(displayName(marketplace)), \(worstStatus(for: marketplace).rawValue)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Assets

    private func assetCard(_ asset: ReviewAsset, rowID: String) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedAssets.contains(rowID) },
            set: { if $0 { expandedAssets.insert(rowID) } else { expandedAssets.remove(rowID) } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text(asset.content).font(.subheadline).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(asset.violations.enumerated()), id: \.offset) { _, violation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(violation.message).font(.caption.weight(.medium))
                        if let detail = violation.detail { Text(detail).font(.caption2) }
                    }.foregroundStyle(violation.isFailure ? WorkflowStyle.red : WorkflowStyle.amber)
                }
                HStack {
                    Button {
                        UIPasteboard.general.string = asset.content
                        copiedAssetID = asset.id
                    } label: {
                        Label(copiedAssetID == asset.id ? "Copied" : "Copy", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    if productID != nil {
                        Button { reportingAsset = asset } label: { Label("Report", systemImage: "flag") }
                    }
                }.font(.caption)
            }.padding(.top, 12)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.type == "ad_script" ? "Ad script" : asset.type.capitalized)
                        .font(.subheadline.weight(.semibold))
                    Text("\(asset.content.count) characters")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                WorkflowPill(text: asset.displayedStatus.rawValue.capitalized, tint: colour(asset.displayedStatus))
            }
        }.workflowCard()
    }

    private func failureBanner(_ failure: GenerationFailureDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This marketplace didn’t finish").font(.footnote.weight(.semibold))
            Text(failure.reason).font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.red)
    }

    // MARK: Status

    private func worstStatus(for marketplace: String) -> ComplianceStatus {
        if listingFailures.contains(where: { $0.marketplace == marketplace }) { return .fail }
        let statuses = listingAssets.filter { $0.marketplace == marketplace }.map(\.displayedStatus)
        if statuses.isEmpty { return .fail }
        if statuses.contains(.fail) { return .fail }
        if statuses.contains(.warn) { return .warn }
        return .pass
    }

    private func colour(_ status: ComplianceStatus) -> Color {
        switch status {
        case .pass: return WorkflowStyle.green
        case .warn: return WorkflowStyle.amber
        case .fail: return WorkflowStyle.red
        }
    }

    private func displayName(_ id: String) -> String {
        appEnvironment.rules.marketplaces.first { $0.id == id }?.displayName ?? id
    }
}

private struct ContentReportView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    let productID: String
    let asset: ReviewAsset
    @State private var reason = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var didSend = false

    var body: some View {
        NavigationStack {
            Form {
                if didSend {
                    Label("Report received", systemImage: "checkmark.circle")
                    Text("Thank you. Your report helps us review generated content.")
                } else {
                    Section("What is wrong with this content?") {
                        TextField("Describe inaccurate, unsafe, or inappropriate content", text: $reason, axis: .vertical)
                            .lineLimit(4...8)
                            .disabled(isSending)
                        Text("The generated asset and your explanation will be sent to Listing Force for review.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Report content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSend ? "Done" : "Cancel") { dismiss() }.disabled(isSending)
                }
                if !didSend {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: send) {
                            if isSending { ProgressView() } else { Text("Send") }
                        }
                        .disabled(isSending || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 2_000)
                    }
                }
            }
            .interactiveDismissDisabled(isSending)
        }
    }

    private func send() {
        guard !isSending, let token = appEnvironment.auth.token else { return }
        isSending = true
        errorMessage = nil
        let body = ContentReportRequest(assetId: asset.id,
                                        reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                        content: asset.content, marketplace: asset.marketplace, type: asset.type)
        Task {
            defer { isSending = false }
            do {
                let _: EmptyResponse = try await appEnvironment.api.post(
                    "api/products/\(productID)/report", body: body, token: token)
                guard appEnvironment.auth.token == token else { return }
                didSend = true
            } catch {
                guard appEnvironment.auth.token == token else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private struct ContentReportRequest: Encodable {
        let assetId: String
        let reason: String
        let content: String
        let marketplace: String
        let type: String
    }
}
