//
//  RefinableMaskTests.swift
//  ListingForgeTests
//
//  Refinement decides what the seller uploads, so it is pinned here rather than
//  judged by eye on a device.
//

import CoreGraphics
import Foundation
import Testing
@testable import ListingForge

@Suite("Cutout refinement")
struct RefinableMaskTests {

    /// A 4x4 image, fully opaque mid-grey.
    private func solid(_ side: Int = 4, alpha: UInt8 = 255) -> RefinableMask {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = 128; px[i + 1] = 128; px[i + 2] = 128; px[i + 3] = alpha
        }
        return RefinableMask(width: side, height: side, pixels: px)
    }

    private func alpha(_ mask: RefinableMask, _ x: Int, _ y: Int) -> UInt8 {
        mask.pixels[(y * mask.width + x) * 4 + 3]
    }

    @Test("Coverage counts the opaque share of the frame")
    func coverageCountsOpaquePixels() {
        #expect(solid().coverage == 1.0)
        #expect(solid(alpha: 0).coverage == 0.0)
        #expect(solid(alpha: 120).coverage == 0.0, "half-transparent is not product")
    }

    @Test("Erasing clears a circle and leaves the rest untouched")
    func eraseClearsACircle() {
        var mask = solid(8)
        mask.erase(atX: 1, y: 1, radius: 1)

        #expect(alpha(mask, 1, 1) == 0)
        #expect(alpha(mask, 0, 1) == 0, "inside the radius")
        #expect(alpha(mask, 7, 7) == 255, "far corner must be untouched")
    }

    @Test("An erased pixel loses its colour as well as its alpha")
    func eraseClearsColourToo() {
        var mask = solid(4)
        mask.erase(atX: 0, y: 0, radius: 0)   // radius 0 is a no-op
        #expect(alpha(mask, 0, 0) == 255)

        mask.erase(atX: 0, y: 0, radius: 1)
        let i = 0
        // A transparent pixel that keeps its colour reappears as a fringe the
        // moment something composites it without honouring alpha.
        #expect(mask.pixels[i] == 0 && mask.pixels[i + 1] == 0 && mask.pixels[i + 2] == 0)
    }

    @Test("Erasing never raises alpha — a stroke cannot resurrect a cut-away pixel")
    func eraseOnlyLowersAlpha() {
        var mask = solid(4, alpha: 0)
        mask.erase(atX: 2, y: 2, radius: 3)

        for y in 0..<4 {
            for x in 0..<4 { #expect(alpha(mask, x, y) == 0) }
        }
    }

    @Test("A stroke outside the image does nothing rather than crashing")
    func eraseOutsideBoundsIsSafe() {
        var mask = solid(4)
        mask.erase(atX: -50, y: -50, radius: 2)
        mask.erase(atX: 900, y: 900, radius: 2)
        #expect(mask.coverage == 1.0)
    }

    @Test("Hardening pushes every pixel fully in or fully out")
    func hardenEdgesRemovesPartialAlpha() {
        var px = [UInt8](repeating: 0, count: 4 * 4)
        px[3] = 250; px[7] = 200; px[11] = 100; px[15] = 10
        var mask = RefinableMask(width: 4, height: 1, pixels: px)

        mask.hardenEdges(threshold: 0.6)   // cut at ~153

        #expect(mask.pixels[3] == 255)
        #expect(mask.pixels[7] == 255)
        #expect(mask.pixels[11] == 0)
        #expect(mask.pixels[15] == 0)
        // The soft halo is the defect this exists to remove.
        #expect(mask.softEdgeFraction == 0)
    }

    @Test("Soft edges are measured against the kept area, not the whole frame")
    func softEdgeFractionIsRelativeToSubject() {
        // A small product on a large background would always look crisp if the
        // halo were divided by the frame.
        var px = [UInt8](repeating: 0, count: 4 * 4)
        px[3] = 255; px[7] = 200; px[11] = 0; px[15] = 0
        let mask = RefinableMask(width: 4, height: 1, pixels: px)

        #expect(mask.coverage == 0.5)
        #expect(mask.softEdgeFraction == 0.5, "one of two kept pixels is soft")
    }

    @Test("Undo takes back the last stroke")
    func undoRestoresPreviousState() {
        var mask = solid(8)
        #expect(!mask.canUndo)

        mask.beginStroke()
        mask.erase(atX: 4, y: 4, radius: 3)
        #expect(mask.coverage < 1.0)
        #expect(mask.canUndo)

        mask.undo()
        #expect(mask.coverage == 1.0)
        #expect(!mask.canUndo)
    }

    @Test("Undo on a fresh mask is harmless")
    func undoWithoutHistoryDoesNothing() {
        var mask = solid(4)
        mask.undo()
        #expect(mask.coverage == 1.0)
    }

    @Test("History is bounded so a long session cannot exhaust memory")
    func undoHistoryIsBounded() {
        var mask = solid(8)
        for _ in 0..<10 {
            mask.beginStroke()
            mask.erase(atX: 4, y: 4, radius: 1)
        }
        var undos = 0
        while mask.canUndo { mask.undo(); undos += 1 }
        #expect(undos == 2, "a full-resolution capture cannot keep every step")
    }

    @Test("Hardening restores the colour of a pixel it promotes to opaque")
    func hardeningUnpremultipliesColour() {
        // The buffer is premultiplied because CoreGraphics offers no 8-bit
        // straight-alpha context. A half-transparent red pixel is stored at
        // half brightness; promoting it to opaque without scaling the colour
        // back up leaves a grey rim where the halo used to be.
        var px: [UInt8] = [100, 0, 0, 128]
        var mask = RefinableMask(width: 1, height: 1, pixels: px)

        mask.hardenEdges(threshold: 0.4)

        #expect(mask.pixels[3] == 255)
        #expect(mask.pixels[0] > 180, "colour was not restored: got \(mask.pixels[0])")

        // A pixel dropped below the cut loses colour as well as alpha.
        px = [100, 0, 0, 60]
        var dropped = RefinableMask(width: 1, height: 1, pixels: px)
        dropped.hardenEdges(threshold: 0.5)
        #expect(dropped.pixels[3] == 0)
        #expect(dropped.pixels[0] == 0)
    }

    @Test("An already-opaque pixel is left exactly as it was")
    func hardeningLeavesOpaquePixelsAlone() {
        var mask = RefinableMask(width: 1, height: 1, pixels: [200, 60, 60, 255])
        mask.hardenEdges(threshold: 0.5)
        #expect(mask.pixels == [200, 60, 60, 255])
    }

    // MARK: Coordinate mapping

    @Test("A tap maps onto the pixel under it, allowing for letterboxing")
    func tapMapsThroughTheFittedRect() throws {
        let mask = solid(100)
        // 100x100 fitted into 400x200 draws 200x200 at x=100.
        let centre = try #require(mask.imagePoint(fromViewPoint: CGPoint(x: 200, y: 100),
                                                  viewSize: CGSize(width: 400, height: 200)))
        #expect(centre.x == 50 && centre.y == 50)

        let topLeft = try #require(mask.imagePoint(fromViewPoint: CGPoint(x: 100, y: 0),
                                                   viewSize: CGSize(width: 400, height: 200)))
        #expect(topLeft.x == 0 && topLeft.y == 0)
    }

    @Test("A tap in the letterbox is rejected rather than wrapping to the far edge")
    func tapOutsideTheImageIsRejected() {
        let mask = solid(100)
        let size = CGSize(width: 400, height: 200)
        // x = 20 is in the empty band to the left of the fitted image.
        #expect(mask.imagePoint(fromViewPoint: CGPoint(x: 20, y: 100), viewSize: size) == nil)
        #expect(mask.imagePoint(fromViewPoint: CGPoint(x: 390, y: 100), viewSize: size) == nil)
        #expect(mask.imagePoint(fromViewPoint: CGPoint(x: 200, y: -5), viewSize: size) == nil)
    }

    @Test("Brush radius is converted into image pixels, never zero")
    func brushRadiusScalesIntoImageSpace() {
        let mask = solid(100)
        // Image drawn at 2x, so a 20pt brush covers 10 image pixels.
        #expect(mask.imageRadius(fromViewRadius: 20, viewSize: CGSize(width: 400, height: 200)) == 10)
        // A tiny brush on a big image must still erase something.
        #expect(mask.imageRadius(fromViewRadius: 0.01, viewSize: CGSize(width: 400, height: 200)) == 1)
    }

    @Test("A zero-sized view cannot produce a coordinate")
    func emptyViewIsRejected() {
        let mask = solid(10)
        #expect(mask.imagePoint(fromViewPoint: .zero, viewSize: .zero) == nil)
        #expect(mask.imageRadius(fromViewRadius: 10, viewSize: .zero) == 0)
    }
}
