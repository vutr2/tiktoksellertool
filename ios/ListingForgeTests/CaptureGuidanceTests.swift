//
//  CaptureGuidanceTests.swift
//  ListingForgeTests
//
//  The overlay maths decides whether a shot can pass validation at all, so it
//  is pinned here rather than eyeballed on a device.
//

import CoreGraphics
import Foundation
import Testing
@testable import ListingForge

@Suite("Framing guide")
struct FramingGuideTests {

    @Test("A square preview crops to the whole frame")
    func squarePreviewKeepsEverything() {
        let guide = FramingGuide.forPreview(size: CGSize(width: 400, height: 400), minimumFillRatio: 0.85)
        #expect(guide.cropRect == CGRect(x: 0, y: 0, width: 400, height: 400))
    }

    @Test("A tall preview crops to a centred square, since marketplaces want 1:1")
    func tallPreviewCropsToCentredSquare() {
        let guide = FramingGuide.forPreview(size: CGSize(width: 400, height: 800), minimumFillRatio: 0.85)

        #expect(guide.cropRect.width == 400)
        #expect(guide.cropRect.height == 400)
        #expect(guide.cropRect.midX == 200)
        #expect(guide.cropRect.midY == 400)
    }

    @Test("The fill target is the SQUARE ROOT of the ratio, not the ratio itself")
    func fillTargetUsesSquareRoot() {
        // The bug this guards: insetting by 0.85 linearly draws a box whose
        // area is 0.85² = 72% of the frame. A seller who fills it exactly would
        // still fail Amazon's 85% rule, and the overlay would have lied.
        let guide = FramingGuide.forPreview(size: CGSize(width: 1000, height: 1000), minimumFillRatio: 0.85)

        let expectedSide = 1000.0 * sqrt(0.85) // ≈ 922, not 850
        #expect(abs(guide.fillTargetRect.width - expectedSide) < 0.5)
        #expect(guide.fillTargetRect.width > 900, "a linear inset would give 850")
    }

    @Test("Filling the dashed box exactly meets the marketplace's minimum")
    func fillingTheTargetSatisfiesTheRule() {
        for ratio in [0.6, 0.75, 0.85, 0.95] {
            let guide = FramingGuide.forPreview(size: CGSize(width: 800, height: 1200), minimumFillRatio: ratio)
            let achieved = guide.fillRatio(ofProductIn: guide.fillTargetRect)
            #expect(abs(achieved - ratio) < 0.001, "ratio \(ratio) produced \(achieved)")
        }
    }

    @Test("A product smaller than the guide reports a shortfall")
    func smallProductReportsLowerFill() {
        let guide = FramingGuide.forPreview(size: CGSize(width: 1000, height: 1000), minimumFillRatio: 0.85)
        let half = guide.cropRect.insetBy(dx: 250, dy: 250) // 500×500 of 1000×1000

        #expect(abs(guide.fillRatio(ofProductIn: half) - 0.25) < 0.001)
    }

    @Test("A product overflowing the frame is clamped to the crop, never above 1")
    func overflowIsClamped() {
        let guide = FramingGuide.forPreview(size: CGSize(width: 500, height: 500), minimumFillRatio: 0.85)
        let huge = CGRect(x: -500, y: -500, width: 2000, height: 2000)

        #expect(guide.fillRatio(ofProductIn: huge) <= 1.0)
    }

    @Test("Out-of-range ratios are clamped instead of producing a nonsense box")
    func ratiosAreClamped() {
        let tooBig = FramingGuide.forPreview(size: CGSize(width: 100, height: 100), minimumFillRatio: 5)
        #expect(tooBig.fillTargetRect.width <= 100)

        let negative = FramingGuide.forPreview(size: CGSize(width: 100, height: 100), minimumFillRatio: -1)
        #expect(negative.fillTargetRect.width >= 0)
    }
}

@Suite("Lighting assessment")
struct LightingAssessmentTests {

    private func stats(
        mean: Double,
        sd: Double = 0.18,
        shadows: Double = 0.02,
        highlights: Double = 0.02
    ) -> LuminanceStats {
        LuminanceStats(
            mean: mean,
            standardDeviation: sd,
            clippedShadowFraction: shadows,
            clippedHighlightFraction: highlights
        )
    }

    @Test("A well-lit frame passes")
    func goodLightPasses() {
        let verdict = LightingAssessment.verdict(for: stats(mean: 0.55))
        #expect(verdict == .good)
        #expect(verdict.isGood)
        #expect(verdict.message == "Lighting looks good")
    }

    @Test("A dark frame is called out")
    func darkFrameIsUnderexposed() {
        #expect(LightingAssessment.verdict(for: stats(mean: 0.10)) == .underexposed)
    }

    @Test("Crushed shadows read as a hard shadow edge")
    func crushedShadowsAreHarsh() {
        #expect(LightingAssessment.verdict(for: stats(mean: 0.5, shadows: 0.30)) == .harshShadow)
    }

    @Test("Blown highlights are called out, whether clipped or just too bright")
    func blownHighlightsAreCaught() {
        #expect(LightingAssessment.verdict(for: stats(mean: 0.5, highlights: 0.25)) == .blownHighlights)
        #expect(LightingAssessment.verdict(for: stats(mean: 0.95)) == .blownHighlights)
    }

    @Test("Darkness is reported before shadow clipping — it is the fixable one")
    func darknessWinsOverShadowClipping() {
        // A dark frame usually also has crushed shadows. Telling a seller to
        // "soften the light" when the real problem is that the room is dim
        // sends them the wrong way.
        #expect(LightingAssessment.verdict(for: stats(mean: 0.05, shadows: 0.40)) == .underexposed)
    }

    @Test("Every verdict gives the seller something to do")
    func messagesAreActionable() {
        for verdict in [LightingVerdict.good, .underexposed, .harshShadow, .blownHighlights] {
            #expect(!verdict.message.isEmpty)
            #expect(verdict.message.first?.isUppercase == true)
            #expect(!verdict.message.contains("_"))
        }
    }
}
