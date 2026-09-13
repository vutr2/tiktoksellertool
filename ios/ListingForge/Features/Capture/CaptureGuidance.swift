//
//  CaptureGuidance.swift
//  ListingForge
//
//  The framing and lighting maths behind the capture overlay (SPEC §4.2).
//
//  Kept free of AVFoundation deliberately: none of this can run in the
//  simulator if it touches a camera, and the numbers here decide whether a shot
//  is usable. They are worth testing on their own.
//

import CoreGraphics
import Foundation

// MARK: - Framing

/// Where to draw the capture overlay for a given preview size.
struct FramingGuide: Equatable {
    /// The 1:1 region that will actually be kept — marketplaces want a square
    /// main image, so anything outside this is cropped away.
    let cropRect: CGRect

    /// The dashed box the product should reach. Filling it satisfies the
    /// marketplace's minimum product fill ratio.
    let fillTargetRect: CGRect

    /// Fill ratio this guide was built for, e.g. 0.85 for Amazon.
    let minimumFillRatio: Double

    /// Builds the overlay for a preview of `size`.
    ///
    /// Fill ratio is an *area* share, so a product that must occupy 85% of the
    /// frame's area reaches √0.85 ≈ 92% of its width — not 85%. Using the ratio
    /// directly as an inset would draw a box the product could fill while still
    /// failing validation.
    static func forPreview(size: CGSize, minimumFillRatio: Double) -> FramingGuide {
        let side = min(size.width, size.height)
        let crop = CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )

        let linear = CGFloat(sqrt(max(0, min(1, minimumFillRatio))))
        let targetSide = side * linear
        let inset = (side - targetSide) / 2
        let target = crop.insetBy(dx: inset, dy: inset)

        return FramingGuide(cropRect: crop, fillTargetRect: target, minimumFillRatio: minimumFillRatio)
    }

    /// The area share a product occupying `rect` would have in the final image.
    /// Lets the overlay tell the seller they are short before they shoot.
    func fillRatio(ofProductIn rect: CGRect) -> Double {
        guard cropRect.width > 0, cropRect.height > 0 else { return 0 }
        let productArea = Double(rect.intersection(cropRect).width * rect.intersection(cropRect).height)
        let frameArea = Double(cropRect.width * cropRect.height)
        return frameArea > 0 ? productArea / frameArea : 0
    }
}

// MARK: - Lighting

/// Luminance summary of one preview frame, in 0...1.
///
/// Measured by the capture pipeline; this type carries no camera code so the
/// thresholds below stay testable.
struct LuminanceStats: Equatable {
    let mean: Double
    let standardDeviation: Double
    /// Share of pixels crushed to black — a hard shadow edge shows up here.
    let clippedShadowFraction: Double
    /// Share of pixels blown to white.
    let clippedHighlightFraction: Double
}

/// What to tell the seller about the light, in the words the overlay shows.
enum LightingVerdict: Equatable {
    case good
    case underexposed
    case harshShadow
    case blownHighlights

    /// Shown verbatim in the capture overlay pill.
    var message: String {
        switch self {
        case .good: return "Lighting looks good"
        case .underexposed: return "Too dark — move to brighter light"
        case .harshShadow: return "Hard shadow — soften or diffuse the light"
        case .blownHighlights: return "Too bright — the product is losing detail"
        }
    }

    var isGood: Bool { self == .good }
}

enum LightingAssessment {
    /// Thresholds tuned by eye, not measured in the field.
    ///
    /// TODO: re-tune against real seller photos before launch — a false
    /// "looks good" is worse than no advice at all.
    static let minimumMean = 0.22
    static let maximumMean = 0.88
    static let maximumShadowClipping = 0.12
    static let maximumHighlightClipping = 0.10

    /// Worst problem first: darkness is the one a seller can always act on.
    static func verdict(for stats: LuminanceStats) -> LightingVerdict {
        if stats.mean < minimumMean { return .underexposed }
        if stats.clippedShadowFraction > maximumShadowClipping { return .harshShadow }
        if stats.clippedHighlightFraction > maximumHighlightClipping { return .blownHighlights }
        if stats.mean > maximumMean { return .blownHighlights }
        return .good
    }
}
