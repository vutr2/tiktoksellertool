import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var period: BillingPeriod = .monthly
    @State private var selectedTier: Tier?

    private var billing: BillingStore { environment.billing }
    private var subscriptions: [StoreKit.Product] {
        billing.products.filter { $0.type == .autoRenewable }
    }

    enum BillingPeriod: String, CaseIterable { case monthly, annual
        var label: String { self == .monthly ? "Monthly" : "Annual" }
        var idFragment: String { self == .monthly ? "monthly" : "annual" }
        var suffix: String { self == .monthly ? "mo" : "yr" }
    }

    /// Display order and copy for each tier, from the design.
    enum Tier: String, CaseIterable, Identifiable {
        case starter, pro, scale
        var id: String { rawValue }
        var name: String { rawValue.capitalized }
        var blurb: String {
            switch self {
            case .starter: return "TikTok Shop only"
            case .pro: return "All four marketplaces"
            case .scale: return "All four marketplaces · more credits"
            }
        }
        var credits: Int {
            switch self {
            case .starter: return 400
            case .pro: return 1_100
            case .scale: return 2_800
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WorkflowHeader(title: "", backTitle: "Close", isBusy: billing.isBusy) { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if subscriptions.isEmpty {
                            unavailable
                        } else {
                            periodPicker
                            VStack(spacing: 12) {
                                ForEach(Tier.allCases) { tier in planCard(tier) }
                            }
                            if period == .annual {
                                Text(annualSavings.map { "Billed annually · save \($0)% vs monthly" } ?? "Billed annually")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(WorkflowStyle.green)
                            }
                            DisclosureGroup("Need extra credits?") { topup }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 18)
                    .background(WorkflowStyle.surface)
                }
                footer
            }
            .background(WorkflowStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .tint(.primary)
            .presentationDragIndicator(.hidden)
            .task {
                await billing.refresh()
                if selectedTier == nil { selectedTier = .pro }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("List on all four\nmarketplaces").font(.title.weight(.bold))
            Text("Create product photos and listing content from one shoot. Choose the plan that fits your business.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var periodPicker: some View {
        Picker("Billing period", selection: $period) {
            ForEach(BillingPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Plan cards

    private func product(for tier: Tier) -> StoreKit.Product? {
        subscriptions.first { $0.id == "\(tier.rawValue)_\(period.idFragment)" }
    }

    private func planCard(_ tier: Tier) -> some View {
        let product = product(for: tier)
        let isSelected = selectedTier == tier
        return Button {
            selectedTier = tier
        } label: {
            HStack(spacing: 14) {
                Circle().fill(isSelected ? Color.primary : .clear)
                    .overlay(Circle().stroke(WorkflowStyle.border, lineWidth: 1))
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tier.name).font(.subheadline.weight(.semibold))
                    Text(tier.blurb).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(product?.displayPrice ?? "—").font(.subheadline.weight(.semibold))
                    Text("\(tier.credits.formatted()) credits / month").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(WorkflowStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.primary : WorkflowStyle.border, lineWidth: isSelected ? 2 : 0.8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .disabled(product == nil || billing.isBusy)
    }

    // MARK: Top-up

    @ViewBuilder private var topup: some View {
        if let topup = billing.products.first(where: { $0.id == billing.status?.topupProductID }) {
            Button {
                Task { await billing.purchase(topup) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One-time top-up").font(.subheadline.weight(.semibold))
                        Text("300 credits · never expire").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(topup.displayPrice).font(.subheadline.weight(.semibold))
                }
                .padding(14)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(billing.isBusy || billing.isLoadingProducts)
        }
    }

    // MARK: Unavailable / loading

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            if billing.isLoadingProducts {
                ProgressView("Loading plans and prices…")
            } else {
                Label("Plans are currently unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(billing.catalogError ?? "The App Store hasn’t returned any subscription plans. Please try again later.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await billing.refresh() } }
                    .buttonStyle(.bordered).disabled(billing.isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }

    // MARK: Footer (CTA + disclosure + links)

    private var selectedProduct: StoreKit.Product? { selectedTier.flatMap(product(for:)) }

    private var footer: some View {
        VStack(spacing: 10) {
            if let message = billing.message, message != billing.catalogError {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                if let product = selectedProduct { Task { await billing.purchase(product) } }
            } label: {
                Group {
                    if billing.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Text(ctaTitle).font(.headline)
                    }
                }
            }
            .buttonStyle(WorkflowPrimaryButtonStyle())
            .disabled(selectedProduct == nil || billing.isBusy || billing.isLoadingProducts)

            Text(disclosure).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Button("Restore Purchases") { Task { await billing.restore() } }
                if let url = AppConfig.termsURL { Link("Terms", destination: url) }
                if let url = AppConfig.privacyPolicyURL { Link("Privacy", destination: url) }
            }
            .font(.caption)
            .disabled(billing.isBusy || billing.isLoadingProducts)
            if billing.status?.tier != nil && billing.status?.tier != "none" {
                Link("Manage subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(WorkflowStyle.background)
    }

    private var ctaTitle: String {
        guard let product = selectedProduct else { return "Choose a plan" }
        if let trial = freeTrial(product) { return "Start \(trial) free trial" }
        return "Subscribe · \(product.displayPrice) / \(period.suffix)"
    }

    /// Compliance text (§3.1.2): auto-renew + trial-converts, always shown in-app.
    private var disclosure: String {
        var lines = ["Subscriptions renew automatically unless canceled at least 24 hours before the period ends. Manage or cancel in your Apple account settings."]
        if let product = selectedProduct, let trial = freeTrial(product) {
            lines.insert("\(trial) free, then \(product.displayPrice) per \(period.suffix). A free trial that is not canceled converts to a paid subscription.", at: 0)
        }
        else if let product = selectedProduct {
            lines.insert("\(product.displayPrice) per \(period == .monthly ? "month" : "year").", at: 0)
        }
        return lines.joined(separator: " ")
    }

    private var annualSavings: Int? {
        guard let tier = selectedTier,
              let annual = subscriptions.first(where: { $0.id == "\(tier.rawValue)_annual" }),
              let monthly = subscriptions.first(where: { $0.id == "\(tier.rawValue)_monthly" }),
              monthly.price > 0 else { return nil }
        let fraction = NSDecimalNumber(decimal: 1 - annual.price / (monthly.price * 12)).doubleValue
        let percent = Int((fraction * 100).rounded())
        return percent > 0 ? percent : nil
    }

    /// Free-trial length to advertise, only when this account is still eligible.
    private func freeTrial(_ product: StoreKit.Product) -> String? {
        guard billing.introOfferEligible,
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let value = offer.period.value
        let unit: String
        switch offer.period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return value == 1 ? "1-\(unit)" : "\(value)-\(unit)"
    }
}
