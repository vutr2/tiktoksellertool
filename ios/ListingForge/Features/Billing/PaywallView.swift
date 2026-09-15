import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    private var billing: BillingStore { environment.billing }
    private var subscriptions: [StoreKit.Product] {
        billing.products.filter { $0.type == .autoRenewable }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create listings with ListingForge")
                            .font(.title2.bold())
                        Text("Starter includes TikTok Shop. Pro and Scale include Amazon, eBay and Etsy. Review generated content before publishing.")
                            .foregroundStyle(.secondary)
                    }
                    if let status = billing.status {
                        LabeledContent("Credits", value: "\(status.balance)")
                        LabeledContent("Current plan", value: status.tier?.capitalized ?? "No active plan")
                    }
                }
                Section("Subscriptions") {
                    if subscriptions.isEmpty {
                        if billing.isLoadingProducts {
                            ProgressView("Loading plans and prices…")
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Plans are currently unavailable", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                                Text(billing.catalogError ?? "The App Store hasn’t returned any subscription plans. Please try again later.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Try again") { Task { await billing.refresh() } }
                                    .buttonStyle(.bordered)
                                    .disabled(billing.isBusy)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    ForEach(subscriptions) { product in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(product.displayName).font(.headline)
                            Text(product.description).font(.subheadline)
                            Button("Subscribe · \(product.displayPrice) / \(period(product))") {
                                Task { await billing.purchase(product) }
                            }
                            .disabled(billing.isBusy || billing.isLoadingProducts)
                        }.padding(.vertical, 4)
                    }
                    if !subscriptions.isEmpty {
                        Text("Subscriptions renew automatically unless canceled in your Apple account settings. The Apple purchase sheet shows the total price and any eligible introductory offer before confirmation.")
                            .font(.footnote)
                    }
                }
                if let topup = billing.products.first(where: { $0.id == billing.status?.topupProductID }) {
                    Section("Additional credits") {
                        Button("300 credits · \(topup.displayPrice)") { Task { await billing.purchase(topup) } }
                            .disabled(billing.isBusy || billing.isLoadingProducts)
                        Text("Top-up credits do not expire.").font(.footnote)
                    }
                }
                Section {
                    Button("Restore Purchases") { Task { await billing.restore() } }
                        .disabled(billing.isBusy || billing.isLoadingProducts)
                    if !subscriptions.isEmpty {
                        Button("Refresh plans") { Task { await billing.refresh() } }
                            .disabled(billing.isBusy || billing.isLoadingProducts)
                    }
                    Link("Manage subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    if let url = AppConfig.privacyPolicyURL { Link("Privacy Policy", destination: url) }
                    if let url = AppConfig.termsURL { Link("Terms of Use", destination: url) }
                    if let message = billing.message, message != billing.catalogError {
                        Text(message).font(.footnote).accessibilityLabel(message)
                    }
                    if billing.isBusy { ProgressView("Confirming with Apple and ListingForge…") }
                }
            }
            .navigationTitle("Plans and credits")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await billing.refresh() }
        }
    }

    private func period(_ product: StoreKit.Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "period" }
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }
}
