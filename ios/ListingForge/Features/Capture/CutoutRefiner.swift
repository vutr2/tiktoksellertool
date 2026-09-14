//
//  CutoutRefiner.swift
//  ListingForge
//
//  Bridges a stored cutout to the editable mask and back.
//
//  The pixel rules live in RefinableMask, which has no image IO so it stays
//  testable. This file is the thin layer that decodes the PNG, hands the bytes
//  over, and re-encodes the result — re-running the same quality assessment
//  that judged the original, so a refined cutout is graded by the same standard
//  and not simply declared good because a human touched it.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CutoutRefiner {

    /// Decodes a cutout into an editable mask.
    static func mask(from cutout: ProductCutout) -> RefinableMask? {
        guard !cutout.pngData.isEmpty,
              let source = CGImageSourceCreateWithData(cutout.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // CoreGraphics has no 8-bit straight-alpha RGBA context — `.last` is
        // rejected outright — so the buffer is premultiplied. That is why
        // hardenEdges has to un-premultiply a pixel it promotes to opaque.
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return RefinableMask(width: width, height: height, pixels: pixels)
    }

    /// A displayable image for the editor, without the cost of PNG encoding.
    ///
    /// Encoding a full-resolution PNG on every brush stroke would make the
    /// editor feel broken; PNG is produced once, when the seller is done.
    static func preview(from mask: RefinableMask) -> CGImage? {
        var pixels = mask.pixels
        guard let ctx = CGContext(data: &pixels, width: mask.width, height: mask.height,
                                  bitsPerComponent: 8, bytesPerRow: mask.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    /// Re-encodes an edited mask and re-grades it.
    static func cutout(from mask: RefinableMask) -> ProductCutout? {
        var pixels = mask.pixels
        guard let ctx = CGContext(data: &pixels, width: mask.width, height: mask.height,
                                  bitsPerComponent: 8, bytesPerRow: mask.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let quality = CutoutQuality(coverage: mask.coverage, softEdgeFraction: mask.softEdgeFraction)
        // instanceCount 1: the subject came from Vision originally, and erasing
        // cannot create or remove an instance — only the measurements change.
        let verdict = CutoutAssessment.verdict(for: quality, instanceCount: 1)

        return ProductCutout(pngData: data as Data, quality: quality, verdict: verdict,
                             widthPx: mask.width, heightPx: mask.height)
    }
}
