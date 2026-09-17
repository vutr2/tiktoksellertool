//
//  DemoMode.swift
//  ListingForge
//
//  Screenshot/demo scaffolding. Compiled ONLY in DEBUG, so it can never reach a
//  Release (App Store) archive. Activated by launch arguments:
//
//      --demo                 seed a signed-in session + sample content
//      --screen <name>        products | review | paywall | settings | capture
//
//  It lets us capture App Store screenshots on the simulator without a live
//  backend, camera, or real sign-in. The seeded stores short-circuit their
//  network calls so nothing hits the server.
//

#if DEBUG
import Foundation
import SwiftUI

enum DemoScreen: String {
    case products, review, paywall, settings, capture
}

enum DemoMode {
    /// The requested screen, or nil when the app is running normally.
    static var screen: DemoScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo") else { return nil }
        if let index = args.firstIndex(of: "--screen"), index + 1 < args.count,
           let screen = DemoScreen(rawValue: args[index + 1]) {
            return screen
        }
        return .products
    }

    static var isActive: Bool { screen != nil }

    /// Which tab MainTabView should open on for the requested screen.
    static var initialTab: MainTab? {
        switch screen {
        case .capture: return .capture
        case .products, .review: return .products
        case .paywall, .settings: return .settings
        case .none: return nil
        }
    }

    /// Review and Paywall are shown as sheets over their owning tab, exactly as
    /// the real app presents them.
    static var wantsSheet: Bool {
        screen == .review || screen == .paywall
    }

    @ViewBuilder
    static func sheetView() -> some View {
        switch screen {
        case .review:
            ReviewView(
                productName: DemoData.listing.product.name,
                assets: DemoData.listing.assets.map(ReviewAsset.init),
                productID: DemoData.listing.product.id,
                failures: DemoData.listing.failures
            )
        case .paywall:
            DemoPaywallView()
        default:
            EmptyView()
        }
    }
}

/// A static stand-in for PaywallView used only for screenshots. `simctl launch`
/// does not apply the scheme's StoreKit configuration, so real StoreKit.Product
/// objects can't load outside Xcode — and they can't be constructed by hand.
/// This mirrors the real paywall's layout with representative plan data.
struct DemoPaywallView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Plan: Identifiable {
        let id = UUID()
        let name: String
        let blurb: String
        let price: String
    }

    private let plans = [
        Plan(name: "Starter", blurb: "400 credits per month. TikTok Shop.", price: "$29.99"),
        Plan(name: "Pro", blurb: "1,100 credits per month. TikTok Shop, Amazon, eBay, and Etsy.", price: "$79.99"),
        Plan(name: "Scale", blurb: "2,800 credits per month. All four marketplaces.", price: "$199.99"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Create listings with Listing Force").font(.title2.bold())
                        Text("Starter includes TikTok Shop. Pro and Scale include Amazon, eBay and Etsy. Review generated content before publishing.")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Credits", value: "1100")
                    LabeledContent("Current plan", value: "Pro")
                }
                Section("Subscriptions") {
                    ForEach(plans) { plan in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(plan.name).font(.headline)
                            Text(plan.blurb).font(.subheadline)
                            Button("Start 7-day free trial · then \(plan.price) / month") {}
                            Text("7-day free, then \(plan.price) per month. Renews automatically until canceled.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    Text("Subscriptions renew automatically unless canceled at least 24 hours before the period ends. A free trial that is not canceled converts to a paid subscription.")
                        .font(.footnote)
                }
                Section("Additional credits") {
                    Button("300 credits · $14.99") {}
                    Text("Top-up credits do not expire.").font(.footnote)
                }
                Section {
                    Button("Restore Purchases") {}
                    Link("Manage subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    if let url = AppConfig.privacyPolicyURL { Link("Privacy Policy", destination: url) }
                    if let url = AppConfig.termsURL { Link("Terms of Use", destination: url) }
                }
            }
            .navigationTitle("Plans and credits")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Fixed, representative sample content used for screenshots.
enum DemoData {
    static let user = UserDTO(id: "3B9F2C1A-4D5E-4A6B-8C7D-9E0F1A2B3C4D", email: "demo@listingforce.app")

    static let products: [ProductDTO] = [
        ProductDTO(id: "demo-1", name: "Ceramic Pour-Over Dripper",
                   category: "Home & Kitchen › Coffee", cutoutPath: nil,
                   createdAt: "2026-09-16T09:12:00.000Z"),
        ProductDTO(id: "demo-2", name: "Merino Wool Beanie",
                   category: "Apparel › Accessories", cutoutPath: nil,
                   createdAt: "2026-09-15T14:03:00.000Z"),
        ProductDTO(id: "demo-3", name: "Bamboo Cutlery Travel Set",
                   category: "Home & Kitchen › Dining", cutoutPath: nil,
                   createdAt: "2026-09-14T18:41:00.000Z"),
        ProductDTO(id: "demo-4", name: "Minimalist Leather Card Wallet",
                   category: "Accessories › Wallets", cutoutPath: nil,
                   createdAt: "2026-09-13T11:20:00.000Z"),
    ]

    static let marketplaces: [MarketplaceRulesDTO] = [
        MarketplaceRulesDTO(id: "tiktok_shop", version: "1", displayName: "TikTok Shop",
                            tier: "included", summary: "", images: [:]),
        MarketplaceRulesDTO(id: "amazon", version: "1", displayName: "Amazon",
                            tier: "pro", summary: "", images: [:]),
        MarketplaceRulesDTO(id: "ebay", version: "1", displayName: "eBay",
                            tier: "pro", summary: "", images: [:]),
        MarketplaceRulesDTO(id: "etsy", version: "1", displayName: "Etsy",
                            tier: "pro", summary: "", images: [:]),
    ]

    static let listing = ListingAssetsDTO(
        product: ListingProductDTO(id: "demo-1", name: "Ceramic Pour-Over Dripper",
                                   category: "Home & Kitchen › Coffee"),
        assets: [
            StoredAssetDTO(id: "a1", type: "title", marketplace: "tiktok_shop",
                           content: "Ceramic Pour-Over Coffee Dripper — Slow-Brew V60 Style Cone for Rich, Clean Cups",
                           status: "pass", violations: []),
            StoredAssetDTO(id: "a2", type: "description", marketplace: "tiktok_shop",
                           content: "Brew café-quality coffee at home with this matte-glazed ceramic pour-over dripper. The 60° cone and spiral ribs guide an even, unhurried extraction, while the wide base fits most mugs and carafes. Dishwasher safe and built to keep heat in for a fuller, cleaner cup — every morning.",
                           status: "pass", violations: []),
            StoredAssetDTO(id: "a3", type: "ad_script", marketplace: "tiktok_shop",
                           content: "POV: your kitchen just became a coffee bar ☕️ Pour slow, watch the bloom, and taste the difference a ceramic cone makes. No paper taste, no bitter finish — just clean, rich coffee in under 3 minutes. Tap to make mornings your favorite part of the day.",
                           status: "pass", violations: []),
            StoredAssetDTO(id: "a4", type: "title", marketplace: "amazon",
                           content: "Ceramic Pour Over Coffee Dripper, Slow Brew V60 Style Cone Filter Holder for Single Cup, Matte Glaze",
                           status: "warn",
                           violations: [ViolationDTO(code: "title.length", severity: "warn",
                                                     field: "title",
                                                     message: "Title is near the length limit.",
                                                     detail: "Consider trimming to keep the key words visible in search results.")]),
            StoredAssetDTO(id: "a5", type: "description", marketplace: "amazon",
                           content: "Elevate your daily brew with this matte-glazed ceramic pour-over dripper. A 60° cone and internal spiral ribs promote even saturation and a balanced, sediment-free extraction. Compatible with #2 cone filters, it rests securely on most mugs and carafes, retains heat well, and is dishwasher safe for easy cleanup.",
                           status: "pass", violations: []),
        ]
    )

    static var billingStatus: BillingStatus {
        BillingStatus(appAccountToken: user.id, tier: "pro", balance: 1100,
                      allowedMarketplaces: ["tiktok_shop", "amazon", "ebay", "etsy"],
                      subscriptionProductIDs: ["starter_monthly", "starter_annual",
                                               "pro_monthly", "pro_annual",
                                               "scale_monthly", "scale_annual"],
                      topupProductID: "topup_300")
    }
}
#endif
