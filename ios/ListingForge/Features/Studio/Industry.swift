//
//  Industry.swift
//  ListingForge
//
//  Per-industry knowledge, ported (in English) from the tiktok_tools prompt
//  system. The seller picks an industry once; it drives the product-info fields
//  we ask for and, on the server, the voice/banned-claims/scene prompt pack.
//
//  Keep the raw values in sync with the backend `Industry` union — they are the
//  wire contract sent to /api/products.
//

import Foundation

enum Industry: String, CaseIterable, Codable, Identifiable, Hashable {
    case beauty = "BEAUTY"
    case fashion = "FASHION"
    case home = "HOME"
    case babyKids = "BABY_KIDS"
    case accessories = "ACCESSORIES"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beauty: return "Beauty & Cosmetics"
        case .fashion: return "Fashion"
        case .home: return "Home & Living"
        case .babyKids: return "Baby & Kids"
        case .accessories: return "Accessories"
        }
    }

    var emoji: String {
        switch self {
        case .beauty: return "💄"
        case .fashion: return "👗"
        case .home: return "🏠"
        case .babyKids: return "🍼"
        case .accessories: return "⌚"
        }
    }

    /// One line describing the studio scenes for this industry, shown on the
    /// picker card. The seller chooses before seeing any result, so tell them
    /// up front what they will get.
    var blurb: String {
        switch self {
        case .beauty: return "Smooth, glossy shots in a premium spa-style setting"
        case .fashion: return "Street or flat-lay studio backdrops that keep fabric folds natural"
        case .home: return "Minimalist wooden countertop and cozy living-room scenes"
        case .babyKids: return "Soft pastel light, wooden crib or plush-blanket backdrops"
        case .accessories: return "Black mirror, raw stone, and crisp high-end shadows"
        }
    }

    /// Extra product-info fields asked per industry — each industry sells on
    /// something different.
    var fields: [ProductField] {
        switch self {
        case .beauty:
            return [
                ProductField(key: "skinType", label: "Suitable skin type", placeholder: "Oily, combination", required: true),
                ProductField(key: "keyIngredient", label: "Key ingredients", placeholder: "Niacinamide 10%, Zinc PCA 1%", required: true),
                ProductField(key: "volume", label: "Volume", placeholder: "30ml"),
                ProductField(key: "texture", label: "Texture", placeholder: "Light serum, fast-absorbing, non-greasy"),
            ]
        case .fashion:
            return [
                ProductField(key: "material", label: "Material", placeholder: "95% cotton, 5% spandex", required: true),
                ProductField(key: "sizeRange", label: "Size chart", placeholder: "S (45-52kg), M (53-60kg), L (61-68kg)", required: true),
                ProductField(key: "colors", label: "Available colors", placeholder: "Black, cream, olive"),
                ProductField(key: "occasion", label: "Occasion", placeholder: "Work, casual, light party"),
            ]
        case .home:
            return [
                ProductField(key: "capacity", label: "Capacity / size", placeholder: "1.8 L, 24 x 18 x 22 cm", required: true),
                ProductField(key: "material", label: "Material", placeholder: "304 stainless steel, BPA-free PP", required: true),
                ProductField(key: "power", label: "Power / voltage", placeholder: "800W, 220V"),
                ProductField(key: "warranty", label: "Warranty", placeholder: "12-month replacement"),
            ]
        case .babyKids:
            return [
                ProductField(key: "ageRange", label: "Age range", placeholder: "0-6 months", required: true),
                ProductField(key: "material", label: "Material", placeholder: "Organic cotton, certified", required: true),
                ProductField(key: "safetyCert", label: "Safety certification", placeholder: "OEKO-TEX, CPSIA"),
                ProductField(key: "washing", label: "Care instructions", placeholder: "Machine wash 30°C, no bleach"),
            ]
        case .accessories:
            return [
                ProductField(key: "compatibility", label: "Compatible with", placeholder: "iPhone 13/14/15, Samsung S22+", required: true),
                ProductField(key: "material", label: "Material", placeholder: "Liquid silicone, CNC aluminum frame", required: true),
                ProductField(key: "spec", label: "Key specs", placeholder: "20W fast charge, 2m drop protection"),
                ProductField(key: "boxContent", label: "In the box", placeholder: "1 case, 1 tempered glass, 1 cloth"),
            ]
        }
    }

    /// Fields asked for every industry.
    static let commonFields: [ProductField] = [
        ProductField(key: "price", label: "Selling price", placeholder: "19.99", required: true),
        ProductField(key: "target", label: "Who it's for", placeholder: "Women 22-30, office workers", required: true),
        ProductField(key: "usp", label: "Strongest selling point", placeholder: "40% cheaper than imports, similar quality", required: true),
    ]
}

/// A single product-info field the capture form renders.
struct ProductField: Identifiable, Hashable {
    let key: String
    let label: String
    let placeholder: String
    var required: Bool = false

    var id: String { key }
}
