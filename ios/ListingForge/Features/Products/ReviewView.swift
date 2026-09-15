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

    private var marketplaces: [String] {
        var seen: [String] = []
        for asset in assets where !seen.contains(asset.marketplace) { seen.append(asset.marketplace) }
        for failure in failures where !seen.contains(failure.marketplace) { seen.append(failure.marketplace) }
        return seen
    }

    private var current: String? {
        if let selectedMarketplace, marketplaces.contains(selectedMarketplace) { return selectedMarketplace }
        return marketplaces.first
    }

    private var shown: [ReviewAsset] {
        guard let current else { return [] }
        return assets.filter { $0.marketplace == current }
    }

    private var currentFailure: GenerationFailureDTO? {
        guard let current else { return nil }
        return failures.first { $0.marketplace == current }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if marketplaces.isEmpty {
                ContentUnavailableView(
                    "Nothing generated yet",
                    systemImage: "doc.text",
                    description: Text("Generate a listing to see it here.")
                )
            } else {
                chips
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let notice {
                            Label(notice, systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("AI-generated content. Check product facts and marketplace requirements before publishing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let failure = currentFailure {
                            failureBanner(failure)
                        }
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, asset in
                            assetCard(asset)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $reportingAsset) { asset in
            if let productID {
                ContentReportView(productID: productID, asset: asset)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Back") { dismiss() }
            Spacer()
            Text("Review").font(.headline)
            Spacer()
            if let text = exportText, !text.isEmpty {
                ShareLink(item: text) { Text("Export") }
            } else {
                Text("Export").foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
            HStack(spacing: 10) {
                ForEach(marketplaces, id: \.self) { marketplace in
                    let isSelected = marketplace == current
                    Button {
                        selectedMarketplace = marketplace
                    } label: {
                        HStack(spacing: 6) {
                            statusDot(worstStatus(for: marketplace))
                            Text(displayName(marketplace))
                        }
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(isSelected ? Color.primary : Color(.systemBackground), in: Capsule())
                        .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(displayName(marketplace)), \(worstStatus(for: marketplace).rawValue)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: Assets

    private func assetCard(_ asset: ReviewAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(asset.type.capitalized).font(.headline)
                Spacer()
                badge(asset.displayedStatus)
            }

            Text(asset.content)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(asset.violations.enumerated()), id: \.offset) { _, violation in
                // The rule in plain English, exactly as the engine worded it
                // (SPEC §10). No codes reach the screen.
                VStack(alignment: .leading, spacing: 3) {
                    Text(violation.message)
                        .font(.footnote.weight(.medium))
                    if let detail = violation.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(violation.isFailure ? .red.opacity(0.1) : .orange.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(violation.isFailure ? .red : .orange)
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
                    Button {
                        reportingAsset = asset
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                }
            }
            .font(.footnote)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
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
        if failures.contains(where: { $0.marketplace == marketplace }) { return .fail }
        let statuses = assets.filter { $0.marketplace == marketplace }.map(\.displayedStatus)
        if statuses.isEmpty { return .fail }
        if statuses.contains(.fail) { return .fail }
        if statuses.contains(.warn) { return .warn }
        return .pass
    }

    private func statusDot(_ status: ComplianceStatus) -> some View {
        Circle()
            .fill(colour(status))
            .frame(width: 7, height: 7)
    }

    private func badge(_ status: ComplianceStatus) -> some View {
        Text(status.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(colour(status).opacity(0.16), in: Capsule())
            .foregroundStyle(colour(status))
    }

    private func colour(_ status: ComplianceStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
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
