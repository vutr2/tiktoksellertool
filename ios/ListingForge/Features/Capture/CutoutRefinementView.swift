//
//  CutoutRefinementView.swift
//  ListingForge
//
//  Manual cutout refinement (SPEC §4.1: "tell the user and offer manual
//  refinement rather than shipping a bad cutout").
//
//  What this screen offers is bounded by what a stored cutout still contains.
//  Vision's removed pixels are gone, so the seller can rub out background the
//  mask wrongly kept and harden a soft outline — the failure SPEC names for
//  thin, transparent and reflective products — but there is no "restore" brush,
//  because it could not do anything.
//

import CoreGraphics
import SwiftUI

struct CutoutRefinementView: View {
    @Environment(\.dismiss) private var dismiss

    let original: ProductCutout
    /// Called with the refined cutout when the seller keeps the result.
    var onRefined: (ProductCutout) -> Void

    @State private var mask: RefinableMask?
    @State private var preview: CGImage?
    @State private var brushRadius: CGFloat = 24
    @State private var isStroking = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let preview {
                canvas(preview)
            } else if failed {
                ContentUnavailableView(
                    "This photo can’t be edited",
                    systemImage: "wand.and.stars.inverse",
                    description: Text("Take another shot with a plain, contrasting background.")
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            controls
        }
        .background(Color(.systemGroupedBackground))
        .task { load() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Text("Refine cutout").font(.headline)
            Spacer()
            Button("Use this") { finish() }
                .fontWeight(.semibold)
                .disabled(mask == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Canvas

    private func canvas(_ image: CGImage) -> some View {
        GeometryReader { proxy in
            ZStack {
                // A checkerboard so erased areas read as transparent rather
                // than as a white product on a white card.
                Checkerboard()
                    .fill(Color(.systemGray5))
                    .background(Color(.systemBackground))

                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in paint(value.location, viewSize: proxy.size) }
                    .onEnded { _ in isStroking = false }
            )
        }
        .padding(16)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "eraser").foregroundStyle(.secondary)
                Slider(value: $brushRadius, in: 8...72)
                Text("\(Int(brushRadius))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Button {
                    guard var current = mask else { return }
                    current.beginStroke()
                    // 0.5 keeps what was more in than out, which is what makes
                    // a halo disappear without eating the product's edge.
                    current.hardenEdges(threshold: 0.5)
                    apply(current)
                } label: {
                    Label("Harden edges", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(mask == nil)

                Button {
                    guard var current = mask else { return }
                    current.undo()
                    apply(current)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(mask?.canUndo != true)
            }

            Text("Rub out anything left over from the background. Erased areas can’t be brought back — retake the photo if too much goes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }

    // MARK: Actions

    private func load() {
        guard let decoded = CutoutRefiner.mask(from: original) else {
            failed = true
            return
        }
        mask = decoded
        preview = CutoutRefiner.preview(from: decoded)
    }

    private func paint(_ point: CGPoint, viewSize: CGSize) {
        guard var current = mask else { return }
        // One undo entry per stroke, not per touch update.
        if !isStroking {
            current.beginStroke()
            isStroking = true
        }
        guard let target = current.imagePoint(fromViewPoint: point, viewSize: viewSize) else {
            mask = current
            return
        }
        current.erase(atX: target.x, y: target.y,
                      radius: current.imageRadius(fromViewRadius: brushRadius, viewSize: viewSize))
        apply(current)
    }

    private func apply(_ updated: RefinableMask) {
        mask = updated
        preview = CutoutRefiner.preview(from: updated)
    }

    private func finish() {
        guard let mask, let refined = CutoutRefiner.cutout(from: mask) else { return }
        onRefined(refined)
        dismiss()
    }
}

/// A transparency checkerboard.
private struct Checkerboard: Shape {
    var square: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : square)
            while x < rect.maxX {
                path.addRect(CGRect(x: x, y: y, width: square, height: square).intersection(rect))
                x += square * 2
            }
            y += square
            row += 1
        }
        return path
    }
}
