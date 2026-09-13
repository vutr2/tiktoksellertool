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
    /// Marketplaces that produced nothing, so a silent gap is never mistaken
    /// for a clean result.
    var failures: [GenerationFailureDTO] = []

    @State private var selectedMarketplace: String?

    private var marketplaces: [String] {
        var seen: [String] = []
        for asset in assets where !seen.contains(asset.marketplace) { seen.append(asset.marketplace) }
        for failure in failures where !seen.contains(failure.marketplace) { seen.append(failure.marketplace) }
        return seen
    }

    private var current: String? { selectedMarketplace ?? marketplaces.first }

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
                        if let failure = currentFailure {
                            failureBanner(failure)
                        }
                        ForEach(shown) { asset in
                            assetCard(asset)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
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
            .map { "\($0.type.capitalized)\n\($0.content)" }
            .joined(separator: "\n\n")
        return body.isEmpty ? nil : "\(productName) — \(name)\n\n\(body)"
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
                badge(asset.status)
            }

            Text(asset.content)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(asset.violations) { violation in
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

            Button {
                UIPasteboard.general.string = asset.content
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.footnote)
            }
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
        let statuses = assets.filter { $0.marketplace == marketplace }.map(\.status)
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
