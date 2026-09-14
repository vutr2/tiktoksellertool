//
//  RefinableMask.swift
//  ListingForge
//
//  The pixel arithmetic behind manual cutout refinement (SPEC §4.1: "offer
//  manual refinement rather than shipping a bad cutout").
//
//  Deliberately free of CoreGraphics image IO and of SwiftUI, so the behaviour
//  that decides what the seller uploads is testable without a camera, without
//  Vision, and without a screen.
//
//  What it can and cannot do is set by what survives in a cutout. The stored
//  PNG keeps the product's colour only where the mask kept it; the pixels
//  Vision removed are gone. So the seller can erase what was wrongly kept and
//  harden a soft edge, but nothing here can bring back a part that was cut
//  away — offering that would be a button that silently does nothing.
//

import CoreGraphics
import Foundation

struct RefinableMask {
    let width: Int
    let height: Int
    /// RGBA, 8 bits per channel, row-major. Only the alpha channel is edited.
    private(set) var pixels: [UInt8]

    private var undoStack: [[UInt8]] = []
    /// Two steps is enough for a brush correction and costs little memory on a
    /// full-resolution capture.
    private let undoLimit = 2

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Share of the frame still opaque enough to count as product.
    var coverage: Double {
        guard width > 0, height > 0 else { return 0 }
        var inside = 0
        for i in stride(from: 3, to: pixels.count, by: 4) where pixels[i] > 127 { inside += 1 }
        return Double(inside) / Double(width * height)
    }

    /// Share of the kept area that is only partly opaque — the soft halo that
    /// makes a composite look cut out.
    var softEdgeFraction: Double {
        var inside = 0
        var soft = 0
        for i in stride(from: 3, to: pixels.count, by: 4) {
            let a = pixels[i]
            if a > 127 { inside += 1 }
            if a > 25 && a < 230 { soft += 1 }
        }
        return inside > 0 ? min(1, Double(soft) / Double(inside)) : 0
    }

    /// Records the current state so one stroke can be taken back.
    mutating func beginStroke() {
        undoStack.append(pixels)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        pixels = previous
    }

    /// Clears alpha inside a circle, in image coordinates.
    ///
    /// Erasing only ever lowers alpha: a stroke can never resurrect a pixel,
    /// which keeps the operation honest about what the data supports.
    mutating func erase(atX x: Int, y: Int, radius: Int) {
        guard radius > 0 else { return }
        let r2 = radius * radius
        let minX = max(0, x - radius), maxX = min(width - 1, x + radius)
        let minY = max(0, y - radius), maxY = min(height - 1, y + radius)
        guard minX <= maxX, minY <= maxY else { return }

        for py in minY...maxY {
            let dy = py - y
            for px in minX...maxX {
                let dx = px - x
                guard dx * dx + dy * dy <= r2 else { continue }
                let i = (py * width + px) * 4 + 3
                pixels[i] = 0
                // Zero the colour too: a transparent pixel that still carries
                // colour reappears as a fringe once something composites it
                // without honouring alpha.
                pixels[i - 3] = 0; pixels[i - 2] = 0; pixels[i - 1] = 0
            }
        }
    }

    /// Pushes every partly transparent pixel fully in or fully out.
    ///
    /// This is the fix for the soft outline Vision leaves on reflective and
    /// translucent products — the case SPEC §4.1 calls out by name.
    mutating func hardenEdges(threshold: Double) {
        let cut = UInt8(max(0, min(255, Int(threshold * 255))))
        for i in stride(from: 3, to: pixels.count, by: 4) {
            let previous = pixels[i]
            if previous >= cut {
                // The buffer is premultiplied, so raising alpha without scaling
                // the colour back up leaves a half-lit pixel — a grey rim
                // exactly where the halo used to be.
                if previous > 0 && previous < 255 {
                    let gain = 255.0 / Double(previous)
                    for channel in (i - 3)...(i - 1) {
                        pixels[channel] = UInt8(min(255, (Double(pixels[channel]) * gain).rounded()))
                    }
                }
                pixels[i] = 255
            } else {
                pixels[i] = 0
                pixels[i - 3] = 0; pixels[i - 2] = 0; pixels[i - 1] = 0
            }
        }
    }

    /// Maps a point in a displayed view onto image coordinates.
    ///
    /// The preview is fitted, so the image is letterboxed: a tap outside the
    /// fitted rect must not wrap around to the opposite edge.
    func imagePoint(fromViewPoint point: CGPoint, viewSize: CGSize) -> (x: Int, y: Int)? {
        guard viewSize.width > 0, viewSize.height > 0, width > 0, height > 0 else { return nil }
        let scale = min(viewSize.width / CGFloat(width), viewSize.height / CGFloat(height))
        let drawn = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        let origin = CGPoint(x: (viewSize.width - drawn.width) / 2, y: (viewSize.height - drawn.height) / 2)

        let x = Int(((point.x - origin.x) / scale).rounded())
        let y = Int(((point.y - origin.y) / scale).rounded())
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return (x, y)
    }

    /// Converts a brush radius in view points to image pixels.
    func imageRadius(fromViewRadius radius: CGFloat, viewSize: CGSize) -> Int {
        guard viewSize.width > 0, viewSize.height > 0, width > 0, height > 0 else { return 0 }
        let scale = min(viewSize.width / CGFloat(width), viewSize.height / CGFloat(height))
        guard scale > 0 else { return 0 }
        return max(1, Int((radius / scale).rounded()))
    }
}
