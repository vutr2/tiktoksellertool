//
//  CaptureView.swift
//  ListingForge
//
//  The guided camera — step 1 of the wizard in the design.
//
//  The framing guide is drawn from the rules the API serves, never from a
//  constant: shooting for the strictest marketplace is what lets the seller
//  choose marketplaces later (step 3) instead of before the shutter.
//
//  TODO(M3): the design presents this modally over the product list ("Cancel"
//  in the top-left). It currently sits in the tab bar; the navigation change
//  lands with the Product details step.
//

import AVFoundation
import PhotosUI
import SwiftUI

struct CaptureView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var camera = CameraSession()
    @State private var flashMode: FlashMode = .auto
    @State private var captureError: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var processingTask: Task<Void, Never>?
    @State private var cutouts: [ProductCutout] = []
    @State private var latestCutout: ProductCutout?
    @State private var showingCutout = false
    @State private var showingRefinement = false
    @State private var showingDetails = false
    /// The listing just generated, shown in Review (design step 4).
    @State private var generatedListing: GenerateResultDTO?
    @State private var pendingListing: GenerateResultDTO?

    private var rules: RulesStore { appEnvironment.rules }
    private var hasRoomForPhoto: Bool {
        !appEnvironment.captureDraft.draft.uploadStarted && cutouts.count < CaptureSeries.defaultShotCount
    }

    enum FlashMode: String, CaseIterable {
        case auto = "Auto", on = "On", off = "Off"

        var captureMode: AVCaptureDevice.FlashMode {
            switch self {
            case .auto: return .auto
            case .on: return .on
            case .off: return .off
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                viewfinder
                Spacer(minLength: 12)
                lightingPill
                Spacer(minLength: 20)
                controls
                statusCaption
                continueToDetails
            }
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .task {
            cutouts = appEnvironment.captureDraft.draft.cutouts
            latestCutout = cutouts.last
            async let loadingRules: Void = rules.load()
            await camera.start()
            await loadingRules
        }
        .onDisappear {
            processingTask?.cancel()
            camera.stop()
        }
        .onChange(of: selectedPhoto) { _, photo in
            if let photo { importPhoto(photo) }
        }
        .sheet(isPresented: $showingCutout) { cutoutReview }
        .sheet(isPresented: $showingRefinement) {
            if let cutout = latestCutout {
                CutoutRefinementView(original: cutout) { refined in
                    latestCutout = refined
                    // A refined cutout is graded again by the same assessment,
                    // so it only joins the series if it now passes on merit.
                    if !refined.verdict.needsManualRefinement {
                        cutouts.append(refined)
                        appEnvironment.captureDraft.draft.cutouts = cutouts
                    }
                }
            }
        }
        .sheet(item: $generatedListing) { listing in
            ReviewView(
                productName: listing.facts.suggestedName,
                assets: listing.assets.map(ReviewAsset.init),
                productID: listing.productId,
                failures: listing.failures
            )
        }
        .sheet(isPresented: $showingDetails, onDismiss: {
            if let listing = pendingListing {
                pendingListing = nil
                generatedListing = listing
                appEnvironment.captureDraft.reset()
                cutouts.removeAll()
                latestCutout = nil
                camera.resetSeries()
            }
        }) {
            ProductDetailsView(
                cutouts: cutouts,
                onCreated: { _ in
                    // The product now exists on the server, so the in-memory
                    // series is finished with. Clearing it also drops the
                    // hardware exposure lock for the next product.
                    // resetSeries() also releases the hardware exposure and
                    // white-balance lock; series.reset() only clears the state
                    // machine, leaving the next product metered for the last one.
                    camera.resetSeries()
                },
                onGenerated: { result in
                    // Discarding this was the gap Codex flagged: credits are
                    // charged, so the seller must be handed the listing.
                    pendingListing = result
                    showingDetails = false
                }
            )
        }
        .alert("Couldn’t prepare that photo", isPresented: Binding(
            get: { captureError != nil },
            set: { if !$0 { captureError = nil } }
        )) {
            Button("OK") { captureError = nil }
        } message: {
            Text(captureError ?? "")
        }
    }

    /// Only appears once there is something to name. Until the server has the
    /// product, these cutouts live in memory alone — the wording says so.
    @ViewBuilder private var continueToDetails: some View {
        if !cutouts.isEmpty {
            Button {
                showingDetails = true
            } label: {
                Text("Continue with \(cutouts.count) photo\(cutouts.count == 1 ? "" : "s")")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isProcessing)
            .padding(.horizontal, 28)
            .padding(.top, 16)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button("Start over") {
                camera.resetSeries()
                cutouts.removeAll()
                latestCutout = nil
                appEnvironment.captureDraft.reset()
            }
                .foregroundStyle(.white)
                .disabled(isProcessing)

            Spacer()
            Text("New product").font(.headline).foregroundStyle(.white)
            Spacer()

            Button {
                let all = FlashMode.allCases
                let next = (all.firstIndex(of: flashMode).map { $0 + 1 } ?? 0) % all.count
                flashMode = all[next]
            } label: {
                Text("Flash \(flashMode.rawValue)").foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        GeometryReader { proxy in
            let guide = FramingGuide.forPreview(
                size: proxy.size,
                minimumFillRatio: rules.strictestMainFill?.ratio ?? 0.85
            )

            ZStack {
                switch camera.state {
                case .running:
                    CameraPreview(session: camera.captureSession)
                case .unavailable(let reason):
                    unavailableView(reason)
                case .idle:
                    ProgressView().tint(.white)
                }

                // The square that will actually be kept.
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: guide.cropRect.width, height: guide.cropRect.height)

                // How far the product must reach to satisfy the strictest rule.
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        .white.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 6])
                    )
                    .frame(width: guide.fillTargetRect.width, height: guide.fillTargetRect.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottom) {
            if let caption = rules.framingCaption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.bottom, -28)
            }
        }
        .padding(.bottom, 28)
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.4))
            Text(reason)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 32)
            Button("Try camera again") {
                Task { await camera.start() }
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
        }
    }

    // MARK: Lighting

    private var lightingPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(camera.lighting.isGood ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(camera.lighting.message)
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.14), in: Capsule())
        .opacity(camera.state == .running ? 1 : 0)
    }

    // MARK: Controls

    private var controls: some View {
        HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Import product photo")
            .disabled(isProcessing || !hasRoomForPhoto)

            Spacer()

            Button(action: takePhoto) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 74, height: 74)
                    Circle().fill(.white).frame(width: 62, height: 62)
                    if isProcessing { ProgressView().tint(.black) }
                }
            }
            .accessibilityLabel("Take product photo")
            .disabled(isProcessing || !hasRoomForPhoto || camera.isCapturing || camera.state != .running || !camera.series.canCapture)
            .opacity(hasRoomForPhoto ? 1 : 0.4)

            Spacer()

            Button {
                let locked = camera.series.exposureLock == .locked
                if locked { camera.series.unlockExposure() } else { camera.series.lockExposure() }
                camera.applyExposureLock(!locked)
            } label: {
                Text("Lock\nAE/AWB")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(camera.series.exposureLock == .locked ? .yellow : .white)
            }
            .frame(width: 52)
            .disabled(isProcessing || camera.state != .running)
        }
        .padding(.horizontal, 28)
    }

    private var statusCaption: some View {
        VStack(spacing: 8) {
            Text(isProcessing ? "Removing background on this device…" : "\(cutouts.count) of \(CaptureSeries.defaultShotCount) photos prepared")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            if camera.state == .running {
                Text(camera.series.exposureLock == .locked
                     ? "Exposure and white balance locked"
                     : "Exposure locks after your next shot")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            if latestCutout != nil {
                Button("Review cutout") { showingCutout = true }
                    .font(.caption)
                    .disabled(isProcessing)
            }
        }
        .padding(.top, 14)
    }

    private func takePhoto() {
        guard !isProcessing, hasRoomForPhoto else { return }
        isProcessing = true
        processingTask = Task {
            defer { isProcessing = false }
            do {
                let data = try await camera.capturePhoto(flashMode: flashMode.captureMode)
                do {
                    let cutout = try await prepareCutout(data)
                    if cutout.verdict.needsManualRefinement { camera.discardLastShot() }
                    show(cutout)
                } catch {
                    camera.discardLastShot()
                    throw error
                }
            } catch {
                report(error)
            }
        }
    }

    private func importPhoto(_ photo: PhotosPickerItem) {
        guard !isProcessing, hasRoomForPhoto else { return }
        isProcessing = true
        processingTask = Task {
            defer {
                isProcessing = false
                selectedPhoto = nil
            }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw CutoutError.invalidPhoto
                }
                let cutout = try await prepareCutout(data)
                show(cutout)
            } catch {
                report(error)
            }
        }
    }

    private func prepareCutout(_ data: Data) async throws -> ProductCutout {
        try Task.checkCancellation()
        // Vision and full-resolution image decoding must not block UI updates.
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try ProductSegmenter.cutout(from: data)
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private func show(_ cutout: ProductCutout) {
        latestCutout = cutout
        // Keep usable angles for the upcoming Product details step in M3.
        if !cutout.verdict.needsManualRefinement {
            cutouts.append(cutout)
            appEnvironment.captureDraft.draft.cutouts = cutouts
        }
        showingCutout = true
    }

    private func report(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        captureError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private var cutoutReview: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let cutout = latestCutout {
                        if let image = UIImage(data: cutout.pngData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 420)
                                .frame(maxWidth: .infinity)
                                .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
                                .accessibilityLabel("Product with background removed")
                        } else {
                            ContentUnavailableView("No product found", systemImage: "viewfinder")
                        }

                        if let message = cutout.verdict.message {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("Rub out what’s left of the background, or take another shot against a plainer surface.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            // SPEC §4.1 asks for manual refinement here rather
                            // than only sending the seller back to the camera.
                            Button {
                                showingRefinement = true
                            } label: {
                                Label("Refine cutout", systemImage: "wand.and.stars")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Label("Background removed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Check the product’s edges and label before taking another angle.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Button(cutout.verdict.needsManualRefinement ? "Try another photo" : "Back to capture") {
                            showingCutout = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle("Product cutout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingCutout = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview layer

/// Hosts `AVCaptureVideoPreviewLayer`. SwiftUI has no native equivalent, and
/// rendering frames through a SwiftUI Image would cost far more than it gains.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
