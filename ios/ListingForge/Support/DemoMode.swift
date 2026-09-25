//
//  DemoMode.swift
//  ListingForge
//
//  Screenshot/demo scaffolding. Compiled ONLY in DEBUG, so it can never reach a
//  Release (App Store) archive. Activated by launch arguments:
//
//      --demo                 seed a signed-in session + sample content
//      --screen <name>        products | review | paywall | settings | capture | details | marketplaces | studio | convert
//
//  It lets us capture App Store screenshots on the simulator without a live
//  backend, camera, or real sign-in. The seeded stores short-circuit their
//  network calls so nothing hits the server.
//

#if DEBUG
import Foundation
import SwiftUI

enum DemoScreen: String {
    case products, review, paywall, settings, capture, details, marketplaces, studio, convert
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
        case .capture, .details, .marketplaces, .studio: return .capture
        case .products, .review, .convert: return .products
        case .paywall, .settings: return .settings
        case .none: return nil
        }
    }

    /// Workflow screens are presented over their owning tab.
    static var wantsSheet: Bool {
        guard let screen else { return false }
        return [.review, .paywall, .details, .marketplaces, .studio, .convert].contains(screen)
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
        case .details, .marketplaces, .studio, .convert:
            DemoWorkflowScreen(screen: screen!)
        default:
            EmptyView()
        }
    }
}

private struct DemoWorkflowScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let screen: DemoScreen

    var body: some View {
        switch screen {
        case .details:
            ProductDetailsView(cutouts: [DemoData.cutout], onCreated: { _ in }, onGenerated: { _ in })
        case .marketplaces:
            MarketplacesView(product: DemoData.products[0], onGenerated: { _ in })
        case .studio:
            StudioView(store: environment.studio(for: "demo-1"), progress: environment.productProgress,
                       productName: DemoData.products[0].name, thumbnail: DemoData.productImage,
                       industry: .home, stepLabel: "3 of 4", onContinue: {})
        case .convert:
            ConvertView(source: "tiktok_shop", assets: DemoData.listing.assets.map(ReviewAsset.init),
                        onContinue: { _ in })
        default:
            EmptyView()
        }
    }
}

/// A DEBUG-only paywall preview. simctl does not load the scheme's StoreKit
/// configuration, so this uses representative prices without purchase actions.
struct DemoPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "Pro"
    @State private var annual = false

    private struct Plan: Identifiable {
        var id: String { name }
        let name: String
        let blurb: String
        let price: String
        let annualPrice: String
        let credits: String
    }

    private let plans = [
        Plan(name: "Starter", blurb: "TikTok Shop only", price: "$29.99", annualPrice: "$299.99", credits: "400 credits / month"),
        Plan(name: "Pro", blurb: "All four marketplaces", price: "$79.99", annualPrice: "$799.99", credits: "1,100 credits / month"),
        Plan(name: "Scale", blurb: "All four marketplaces", price: "$199.99", annualPrice: "$1,999.99", credits: "2,800 credits / month"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            WorkflowHeader(title: "", backTitle: "Close", onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("List on all four\nmarketplaces").font(.title.bold())
                    Text("Create product photos and listing copy tailored to every marketplace.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 10)
                    ForEach(plans) { plan in
                        Button { selected = plan.name } label: {
                            HStack(spacing: 12) {
                                Circle().fill(selected == plan.name ? Color.primary : Color.clear)
                                    .overlay(Circle().stroke(WorkflowStyle.border, lineWidth: 1))
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.name).font(.subheadline.weight(.semibold))
                                    Text(plan.blurb).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(annual ? plan.annualPrice : plan.price).font(.subheadline.weight(.semibold))
                                    Text(plan.credits).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .workflowCard()
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == plan.name ? Color.primary : Color.clear, lineWidth: 1.8))
                        }.buttonStyle(.plain)
                    }
                    Picker("Billing period", selection: $annual) {
                        Text("Monthly").tag(false)
                        Text("Annual · save 17%").tag(true)
                    }.pickerStyle(.segmented).padding(.top, 2)
                    Text("Preview prices · no purchase will be made.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 22).padding(.bottom, 20).background(WorkflowStyle.surface)
            }
            VStack(spacing: 10) {
                Button("Start 7-day free trial") {}.buttonStyle(WorkflowPrimaryButtonStyle())
                Text("100 trial credits. Renews at the selected plan price unless canceled.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 22) {
                    Button("Restore Purchases") {}
                    Text("·")
                    Button("Terms") {}
                    Text("·")
                    Button("Privacy") {}
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(22)
        }.background(WorkflowStyle.background).tint(.primary).presentationDragIndicator(.hidden)
    }
}

/// Fixed, representative sample content used for screenshots.
enum DemoData {
    static var productImage: UIImage { DemoTransport.productImage }
    static var cutout: ProductCutout {
        ProductCutout(pngData: productImage.pngData()!,
                      quality: CutoutQuality(coverage: 0.6, softEdgeFraction: 0.02),
                      verdict: .usable, widthPx: 400, heightPx: 400)
    }

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
                            tier: "included", summary: "1:1 · video cover · overlay text OK", images: [:]),
        MarketplaceRulesDTO(id: "amazon", version: "1", displayName: "Amazon",
                            tier: "pro", summary: "Pure white main · no text · 1600px", images: [:]),
        MarketplaceRulesDTO(id: "ebay", version: "1", displayName: "eBay",
                            tier: "pro", summary: "No borders · no watermark", images: [:]),
        MarketplaceRulesDTO(id: "etsy", version: "1", displayName: "Etsy",
                            tier: "pro", summary: "Lifestyle-first · 13 tags · SEO title", images: [:]),
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
