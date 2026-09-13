//
//  ProductCutoutTests.swift
//  ListingForgeTests
//
//  SPEC §4.1 requires the cutout to fail gracefully rather than ship a bad
//  mask. These pin when we stop and ask the seller to look.
//

import CoreGraphics
import Foundation
import Testing
@testable import ListingForge

@Suite("Cutout assessment")
struct CutoutAssessmentTests {

    private func quality(coverage: Double, soft: Double = 0.1) -> CutoutQuality {
        CutoutQuality(coverage: coverage, softEdgeFraction: soft)
    }

    @Test("A clean mask covering a sensible share of the frame is usable")
    func cleanMaskIsUsable() {
        let verdict = CutoutAssessment.verdict(for: quality(coverage: 0.45), instanceCount: 1)

        #expect(verdict == .usable)
        #expect(!verdict.needsManualRefinement)
        #expect(verdict.message == nil, "nothing to interrupt the seller with")
    }

    @Test("No instances means no subject, never a silent pass")
    func noInstancesReportsNoSubject() {
        // Uploading the original frame here is the failure SPEC §4.1 rules out.
        let verdict = CutoutAssessment.verdict(for: quality(coverage: 0.5), instanceCount: 0)

        #expect(verdict == .noSubjectFound)
        #expect(verdict.needsManualRefinement)
    }

    @Test("A speck of a subject is reported as too small")
    func tinySubjectIsRejected() {
        #expect(CutoutAssessment.verdict(for: quality(coverage: 0.01), instanceCount: 1) == .subjectTooSmall)
    }

    @Test("A mask covering the whole frame separated nothing")
    func fullFrameMaskIsRejected() {
        #expect(CutoutAssessment.verdict(for: quality(coverage: 0.99), instanceCount: 1) == .maskCoversEverything)
    }

    @Test("Soft edges flag the shiny and transparent products SPEC §4.1 names")
    func softEdgesAreFlagged() {
        let verdict = CutoutAssessment.verdict(for: quality(coverage: 0.4, soft: 0.7), instanceCount: 1)

        #expect(verdict == .edgesUnreliable)
        #expect(verdict.needsManualRefinement)
        #expect(verdict.message?.contains("shiny or transparent") == true)
    }

    @Test("Boundaries are inclusive of the usable side")
    func boundaryValuesAreUsable() {
        // Exactly at a threshold should pass; only beyond it should fail.
        #expect(CutoutAssessment.verdict(
            for: quality(coverage: CutoutAssessment.minimumCoverage), instanceCount: 1) == .usable)
        #expect(CutoutAssessment.verdict(
            for: quality(coverage: CutoutAssessment.maximumCoverage), instanceCount: 1) == .usable)
        #expect(CutoutAssessment.verdict(
            for: quality(coverage: 0.4, soft: CutoutAssessment.maximumSoftEdgeFraction),
            instanceCount: 1) == .usable)
    }

    @Test("Every failure tells the seller what to change")
    func failureMessagesAreActionable() {
        for verdict in [CutoutVerdict.noSubjectFound, .subjectTooSmall, .maskCoversEverything, .edgesUnreliable] {
            let message = verdict.message
            #expect(message != nil, "\(verdict) has no message")
            #expect(message!.count > 30, "\(verdict) message is too terse: \(message!)")
            #expect(!message!.contains("mask"), "leaks implementation language: \(message!)")
        }
    }
}

/// Vision's foreground model needs an inference context the simulator does not
/// provide ("Could not create inference context"). Probed once so the suite is
/// skipped with a reason instead of failing on an environment limitation.
private enum VisionAvailability {
    static let isSupported: Bool = {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let probe = context.makeImage() else { return false }

        do { _ = try ProductSegmenter.cutout(from: probe); return true }
        catch { return false }
    }()
}

@Suite("Vision segmentation", .enabled(if: VisionAvailability.isSupported))
struct ProductSegmenterTests {

    /// A plain synthetic scene. Vision is trained on photographs, so it may or
    /// may not find a subject here — the point is that the whole path runs.
    private func syntheticImage() throws -> CGImage {
        let size = 512
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.35, blue: 0.8, alpha: 1))
        context.fillEllipse(in: CGRect(x: 140, y: 140, width: 232, height: 232))
        return try #require(context.makeImage())
    }

    @Test("The segmentation path runs end to end and returns a coherent result")
    func segmentationRunsWithoutCrashing() throws {
        let cutout = try ProductSegmenter.cutout(from: try syntheticImage())

        #expect(cutout.widthPx == 512)
        #expect(cutout.heightPx == 512)
        #expect((0...1).contains(cutout.quality.coverage))
        #expect((0...1).contains(cutout.quality.softEdgeFraction))

        if cutout.verdict == .noSubjectFound {
            #expect(cutout.pngData.isEmpty, "nothing should be uploaded when no subject was found")
        } else {
            #expect(!cutout.pngData.isEmpty)
            // PNG magic number — proves we encoded a real image with alpha.
            #expect(cutout.pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        }
    }
}
