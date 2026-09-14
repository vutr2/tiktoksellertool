//
//  CutoutRefinerTests.swift
//  ListingForgeTests
//
//  A refined cutout is what gets uploaded, so the round trip is pinned here.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ListingForge

@Suite("Cutout refiner")
struct CutoutRefinerTests {

    /// Builds a real PNG: an opaque square on the left, transparent on the right.
    private func makeCutout(side: Int = 16) throws -> ProductCutout {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let opaque = x < side / 2
                px[i] = 200; px[i + 1] = 60; px[i + 2] = 60
                px[i + 3] = opaque ? 255 : 0
            }
        }
        let ctx = try #require(CGContext(data: &px, width: side, height: side, bitsPerComponent: 8,
                                         bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        return ProductCutout(pngData: data as Data,
                             quality: CutoutQuality(coverage: 0.5, softEdgeFraction: 0),
                             verdict: .usable, widthPx: side, heightPx: side)
    }

    @Test("A cutout decodes into an editable mask of the same size")
    func decodesToMask() throws {
        let mask = try #require(CutoutRefiner.mask(from: try makeCutout()))

        #expect(mask.width == 16)
        #expect(mask.height == 16)
        // Half the frame was opaque.
        #expect(abs(mask.coverage - 0.5) < 0.01)
    }

    @Test("An empty or unreadable cutout yields no mask rather than a blank editor")
    func rejectsUnreadableData() {
        let empty = ProductCutout(pngData: Data(), quality: CutoutQuality(coverage: 0, softEdgeFraction: 0),
                                  verdict: .noSubjectFound, widthPx: 0, heightPx: 0)
        #expect(CutoutRefiner.mask(from: empty) == nil)

        let garbage = ProductCutout(pngData: Data([1, 2, 3, 4]), quality: CutoutQuality(coverage: 0, softEdgeFraction: 0),
                                    verdict: .usable, widthPx: 4, heightPx: 4)
        #expect(CutoutRefiner.mask(from: garbage) == nil)
    }

    @Test("The round trip keeps the kept area intact")
    func roundTripPreservesCoverage() throws {
        let mask = try #require(CutoutRefiner.mask(from: try makeCutout()))
        let rebuilt = try #require(CutoutRefiner.cutout(from: mask))

        #expect(rebuilt.widthPx == 16)
        #expect(rebuilt.heightPx == 16)
        #expect(abs(rebuilt.quality.coverage - 0.5) < 0.01)
        // PNG magic — a real encoded image, not an empty buffer.
        #expect(rebuilt.pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("Erasing shrinks the recorded coverage")
    func erasingReducesCoverage() throws {
        var mask = try #require(CutoutRefiner.mask(from: try makeCutout()))
        let before = mask.coverage

        mask.beginStroke()
        mask.erase(atX: 4, y: 8, radius: 4)
        let after = try #require(CutoutRefiner.cutout(from: mask))

        #expect(after.quality.coverage < before)
    }

    @Test("A refined cutout is graded again, not trusted because a human edited it")
    func refinedCutoutIsReassessed() throws {
        var mask = try #require(CutoutRefiner.mask(from: try makeCutout()))

        // Rub out nearly everything — the result must be reported as unusable
        // rather than accepted just because it came out of the editor.
        mask.beginStroke()
        mask.erase(atX: 8, y: 8, radius: 32)

        let refined = try #require(CutoutRefiner.cutout(from: mask))
        #expect(refined.verdict == .subjectTooSmall)
        #expect(refined.verdict.needsManualRefinement)
    }

    @Test("Hardening removes the soft halo and the grade reflects it")
    func hardeningClearsSoftEdges() throws {
        var mask = try #require(CutoutRefiner.mask(from: try makeCutout()))
        // Introduce a halo across the kept half.
        for y in 0..<16 {
            let i = (y * 16 + 7) * 4 + 3
            mask = {
                var pixels = mask.pixels
                pixels[i] = 120
                return RefinableMask(width: mask.width, height: mask.height, pixels: pixels)
            }()
        }
        #expect(mask.softEdgeFraction > 0)

        mask.hardenEdges(threshold: 0.5)
        let refined = try #require(CutoutRefiner.cutout(from: mask))

        #expect(refined.quality.softEdgeFraction == 0)
        #expect(refined.verdict == .usable)
    }

    @Test("A preview image is produced without encoding a PNG")
    func previewRendersWithoutEncoding() throws {
        let mask = try #require(CutoutRefiner.mask(from: try makeCutout()))
        let preview = try #require(CutoutRefiner.preview(from: mask))

        #expect(preview.width == 16)
        #expect(preview.height == 16)
    }
}
