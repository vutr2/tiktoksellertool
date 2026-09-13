//
//  ProductCutout.swift
//  ListingForge
//
//  On-device subject segmentation (SPEC §4.1) — mandatory, and the reason the
//  unit economics work: the cutout is free and instant here instead of a paid
//  server round-trip. What gets uploaded is the cutout PNG with alpha, never
//  the original frame.
//
//  SPEC also demands a graceful failure: "if the mask is low-confidence (thin,
//  transparent, or reflective products), tell the user and offer manual
//  refinement rather than shipping a bad cutout." The judgement that decides
//  that lives in `CutoutAssessment`, kept free of Vision so it can be tested
//  without a camera.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Quality judgement (pure)

/// What the mask looks like, measured from its pixels.
struct CutoutQuality: Equatable {
    /// Share of the frame the subject covers, 0...1.
    let coverage: Double
    /// Share of the mask that is partially transparent rather than clearly in
    /// or out. High on reflective, furry or transparent products — exactly the
    /// cases SPEC §4.1 says to flag.
    let softEdgeFraction: Double
}

enum CutoutVerdict: Equatable {
    case usable
    case noSubjectFound
    case subjectTooSmall
    case maskCoversEverything
    case edgesUnreliable

    /// Shown to the seller. Nil when there is nothing to say.
    var message: String? {
        switch self {
        case .usable:
            return nil
        case .noSubjectFound:
            return "We couldn’t find the product in this shot. Try a plainer background."
        case .subjectTooSmall:
            return "The product is too small in the frame. Move closer and fill the guide."
        case .maskCoversEverything:
            return "We couldn’t separate the product from the background. Try a contrasting surface."
        case .edgesUnreliable:
            return "The edges came out soft — common with shiny or transparent products. Check the cutout before continuing."
        }
    }

    /// Whether to offer manual refinement instead of continuing silently.
    var needsManualRefinement: Bool { self != .usable }
}

enum CutoutAssessment {
    /// Below this the mask found a speck, not a product.
    static let minimumCoverage = 0.03
    /// Above this it selected the whole frame and separated nothing.
    static let maximumCoverage = 0.97
    /// Beyond this the outline cannot be trusted for compositing.
    static let maximumSoftEdgeFraction = 0.45

    /// TODO: tune against real seller photos. A wrong "usable" ships a bad
    /// cutout, which is worse than asking the seller to look.
    static func verdict(for quality: CutoutQuality, instanceCount: Int) -> CutoutVerdict {
        guard instanceCount > 0 else { return .noSubjectFound }
        if quality.coverage < minimumCoverage { return .subjectTooSmall }
        if quality.coverage > maximumCoverage { return .maskCoversEverything }
        if quality.softEdgeFraction > maximumSoftEdgeFraction { return .edgesUnreliable }
        return .usable
    }
}

// MARK: - Result

struct ProductCutout {
    /// PNG with alpha — this is what is uploaded (SPEC §4.1).
    let pngData: Data
    let quality: CutoutQuality
    let verdict: CutoutVerdict
    let widthPx: Int
    let heightPx: Int
}

enum CutoutError: LocalizedError {
    case segmentationFailed(Error)
    case maskUnreadable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .segmentationFailed:
            return "We couldn’t process this photo. Try taking it again."
        case .maskUnreadable, .encodingFailed:
            return "Something went wrong preparing the cutout. Try taking the photo again."
        }
    }
}

// MARK: - Vision

enum ProductSegmenter {

    /// Lifts the product off its background entirely on device.
    static func cutout(from image: CGImage) throws -> ProductCutout {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            throw CutoutError.segmentationFailed(error)
        }

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            // No subject at all — report it rather than uploading the frame.
            return ProductCutout(
                pngData: Data(),
                quality: CutoutQuality(coverage: 0, softEdgeFraction: 0),
                verdict: .noSubjectFound,
                widthPx: image.width,
                heightPx: image.height
            )
        }

        let instances = observation.allInstances

        let maskBuffer = try {
            do { return try observation.generateScaledMaskForImage(forInstances: instances, from: handler) }
            catch { throw CutoutError.segmentationFailed(error) }
        }()
        let quality = try measure(mask: maskBuffer)
        let verdict = CutoutAssessment.verdict(for: quality, instanceCount: instances.count)

        let maskedBuffer = try {
            do {
                return try observation.generateMaskedImage(
                    ofInstances: instances,
                    from: handler,
                    croppedToInstancesExtent: false
                )
            } catch { throw CutoutError.segmentationFailed(error) }
        }()

        return ProductCutout(
            pngData: try png(from: maskedBuffer),
            quality: quality,
            verdict: verdict,
            widthPx: image.width,
            heightPx: image.height
        )
    }

    /// Reads the grayscale mask to see how much was selected and how soft the
    /// boundary is. Pixels between the two cutoffs are neither in nor out.
    static func measure(mask: CVPixelBuffer) throws -> CutoutQuality {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(mask) else { throw CutoutError.maskUnreadable }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let format = CVPixelBufferGetPixelFormatType(mask)
        guard width > 0, height > 0 else { throw CutoutError.maskUnreadable }

        var inside = 0
        var soft = 0
        let total = width * height

        // Sub-sample: a full 12MP scan costs far more than the precision is
        // worth for a coverage estimate.
        let step = max(1, Int((Double(total) / 200_000).squareRoot().rounded(.up)))
        var sampled = 0

        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * stride)
            for x in Swift.stride(from: 0, to: width, by: step) {
                let value: Double
                switch format {
                case kCVPixelFormatType_OneComponent8:
                    value = Double(row.assumingMemoryBound(to: UInt8.self)[x]) / 255.0
                case kCVPixelFormatType_OneComponent32Float:
                    value = Double(row.assumingMemoryBound(to: Float.self)[x])
                default:
                    throw CutoutError.maskUnreadable
                }
                sampled += 1
                if value > 0.5 { inside += 1 }
                if value > 0.1 && value < 0.9 { soft += 1 }
            }
        }

        guard sampled > 0 else { throw CutoutError.maskUnreadable }
        let coverage = Double(inside) / Double(sampled)
        // Softness is judged against the subject, not the whole frame: a small
        // product on a big background would otherwise always look crisp.
        let softEdgeFraction = inside > 0 ? Double(soft) / Double(inside) : 0

        return CutoutQuality(coverage: coverage, softEdgeFraction: min(1, softEdgeFraction))
    }

    private static func png(from buffer: CVPixelBuffer) throws -> Data {
        guard let image = makeCGImage(from: buffer) else { throw CutoutError.encodingFailed }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw CutoutError.encodingFailed }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CutoutError.encodingFailed }
        return data as Data
    }
}

/// Bridges the masked pixel buffer to a CGImage, keeping the alpha channel —
/// without it the cutout would be composited onto a black rectangle.
private func makeCGImage(from buffer: CVPixelBuffer) -> CGImage? {
    let image = CIImage(cvPixelBuffer: buffer)
    return CIContext(options: [.useSoftwareRenderer: false])
        .createCGImage(image, from: image.extent)
}
