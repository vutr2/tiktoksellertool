import SwiftUI

/// A free rules check of the saved copy before opening the generation quote.
/// The conversion endpoint describes image projections, not edited pixels, so
/// this screen only sends the text it can display accurately.
struct ConvertView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let source: String
    let assets: [ReviewAsset]
    /// The language the saved copy is written in. Sent so the server knows
    /// whether its English content checks could read this text — reading the
    /// app in English must not make Vietnamese copy report as fully checked.
    let language: AppLanguage
    let onContinue: (String) -> Void

    @State private var target = ""
    @State private var checkedTarget: String?
    @State private var checks: [CheckedCopy] = []
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var retry = 0

    private var destinations: [MarketplaceRulesDTO] {
        environment.rules.marketplaces.filter { $0.id != source }
    }

    private var copy: [ReviewAsset] {
        assets.filter { $0.marketplace == source && ($0.type == "title" || $0.type == "description") }
    }

    private var visibleChecks: [CheckedCopy] { checkedTarget == target ? checks : [] }
    private var previewText: String { copy.first(where: { $0.type == "title" })?.content ?? copy.first?.content ?? "No listing text available." }
    private var requestIdentity: String { "\(target)-\(retry)" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        destinationPicker
                        previews
                        reviewSection
                    }
                    .padding(.horizontal, 22).padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorkflowStyle.surface)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(WorkflowStyle.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .toolbar(.hidden, for: .navigationBar)
            .tint(.primary)
        }
        .presentationDragIndicator(.hidden)
        .task {
            await environment.rules.load()
            if target.isEmpty { target = destinations.first?.id ?? "" }
        }
        .task(id: requestIdentity) { await checkCopy() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("Close").foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            HStack(spacing: 7) {
                Text(name(source))
                Image(systemName: "arrow.right")
                Text(target.isEmpty ? "Marketplace" : name(target))
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 20, height: 1)
        }
        .font(.subheadline).padding(.horizontal, 22).frame(minHeight: 64)
    }

    @ViewBuilder private var destinationPicker: some View {
        if destinations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if environment.rules.isLoading {
                    ProgressView("Loading marketplaces…")
                } else {
                    Text("Marketplace rules are unavailable.").font(.subheadline)
                    Button("Try again") {
                        Task {
                            await environment.rules.load()
                            target = destinations.first?.id ?? ""
                        }
                    }.font(.subheadline.weight(.medium))
                }
            }.padding(.top, 12)
        } else {
            HStack {
                Text("CONVERT TO").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("Destination marketplace", selection: $target) {
                    ForEach(destinations) { destination in
                        Text(destination.displayName).tag(destination.id)
                    }
                }.pickerStyle(.menu).font(.subheadline)
            }
        }
    }

    private var previews: some View {
        HStack(alignment: .top, spacing: 12) {
            previewCard(caption: "Original · \(name(source))", tinted: true)
            previewCard(caption: target.isEmpty ? "Choose a marketplace" : "Check · \(name(target))", tinted: false)
        }
    }

    private func previewCard(caption: String, tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.caption).foregroundStyle(.secondary)
                Text(previewText).font(.subheadline).lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(13).frame(maxWidth: .infinity).frame(height: 156)
            .background(tinted ? Color.brown.opacity(0.12) : WorkflowStyle.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkflowStyle.border, lineWidth: 0.8))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What to review").font(.subheadline.weight(.semibold))
            if isChecking || (!target.isEmpty && checkedTarget != target) {
                ProgressView("Checking saved text…")
                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    .workflowCard()
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorMessage).font(.subheadline).foregroundStyle(WorkflowStyle.red)
                    Button("Retry free check") { retry += 1 }
                        .font(.subheadline.weight(.medium))
                }.frame(maxWidth: .infinity, alignment: .leading).workflowCard()
            } else if copy.isEmpty {
                Text("Generate a title and description to check them for another marketplace.")
                    .font(.subheadline).foregroundStyle(.secondary).workflowCard()
            } else if !visibleChecks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(visibleChecks.enumerated()), id: \.offset) { index, check in
                        if index > 0 { Divider() }
                        checkRow(check)
                    }
                }.workflowCard(padding: 0)
            }
            Text("This checks your saved title and description. Photos, scripts and tags need a separate review.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkRow(_ check: CheckedCopy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(check.tint).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.type.capitalized).font(.subheadline.weight(.medium))
                    Text(check.violations.isEmpty ? "No issues found in the configured text rules." : "Review the checks below.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                WorkflowPill(text: check.violations.isEmpty ? "Checked" : "Review", tint: check.tint)
            }
            ForEach(Array(check.violations.enumerated()), id: \.offset) { _, violation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(violation.message).font(.caption.weight(.medium))
                    if let detail = violation.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }.foregroundStyle(violation.isFailure ? WorkflowStyle.red : WorkflowStyle.amber)
                    .padding(.leading, 17)
            }
        }.padding(14)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your saved copy stays unchanged. Review the cost on the next screen before generating a listing for \(target.isEmpty ? "another marketplace" : name(target)).")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                onContinue(target)
                dismiss()
            } label: {
                Text(target.isEmpty ? "Continue to listing" : "Continue to \(name(target)) listing")
            }
            .buttonStyle(WorkflowPrimaryButtonStyle())
            .disabled(target.isEmpty || !destinations.contains(where: { $0.id == target }) || isChecking)
            Text("Text rule checks are free · no credits used")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(22).background(WorkflowStyle.background)
    }

    private func name(_ id: String) -> String {
        environment.rules.marketplaces.first(where: { $0.id == id })?.displayName
            ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @MainActor private func checkCopy() async {
        let requestedTarget = target
        checkedTarget = requestedTarget
        checks = []
        errorMessage = nil
        isChecking = false
        guard !requestedTarget.isEmpty else { return }
        guard let token = environment.auth.token else {
            errorMessage = "Sign in again to check marketplace rules."
            return
        }
        isChecking = true
        defer {
            if !Task.isCancelled && target == requestedTarget { isChecking = false }
        }
        do {
            var completed: [CheckedCopy] = []
            for asset in copy {
                try Task.checkCancellation()
                let body = ConversionCheckRequest(asset: TextToCheck(asset), from: source,
                                                  to: requestedTarget, language: language)
                let result: ConversionCheckResult = try await environment.api.post(
                    "api/rules/convert", body: body, token: token)
                guard !Task.isCancelled, target == requestedTarget, environment.auth.token == token else { return }
                guard result.from == source, result.to == requestedTarget else { throw APIError.invalidResponse }
                completed.append(CheckedCopy(id: asset.id, type: asset.type, violations: result.unresolved))
            }
            guard !Task.isCancelled, target == requestedTarget, environment.auth.token == token else { return }
            checks = completed
        } catch {
            guard !Task.isCancelled, target == requestedTarget, environment.auth.token == token else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct CheckedCopy: Identifiable {
    let id: String
    let type: String
    let violations: [ViolationDTO]

    var tint: Color {
        if violations.contains(where: \.isFailure) { return WorkflowStyle.red }
        return violations.isEmpty ? WorkflowStyle.green : WorkflowStyle.amber
    }
}

private struct ConversionCheckRequest: Encodable {
    let asset: TextToCheck
    let from: String
    let to: String
    let language: AppLanguage
}

private struct TextToCheck: Encodable {
    let type: String
    let text: String
    let bullets: [String]?

    init(_ asset: ReviewAsset) {
        type = asset.type
        text = asset.content
        // Stored descriptions flatten the generated bullet array with newlines.
        // Retain those lines for the server's bullet checks without changing copy.
        let lines = asset.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        bullets = asset.type == "description" && lines.count > 1 ? lines : nil
    }
}

private struct ConversionCheckResult: Decodable {
    let from: String
    let to: String
    let unresolved: [ViolationDTO]
}
