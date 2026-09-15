//
//  CameraSession.swift
//  ListingForge
//
//  The custom capture session SPEC §4.2 requires — not UIImagePickerController.
//
//  Everything that can be decided without a camera lives in CaptureGuidance and
//  CaptureSeries; this file is the thin shell that drives AVFoundation and
//  feeds those decisions. The simulator has no camera, so `state` carries the
//  reason rather than leaving a black screen.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CameraSession {

    enum State: Equatable {
        case idle
        /// No camera, or permission refused. Carries what to tell the seller.
        case unavailable(String)
        case running
    }

    private(set) var state: State = .idle
    private(set) var isCapturing = false
    /// Updated a few times a second from the preview stream.
    private(set) var lighting: LightingVerdict = .good
    let series = CaptureSeries()

    /// Handed to the SwiftUI preview layer.
    private let hardware = CameraHardware()
    var captureSession: AVCaptureSession { hardware.session }
    private var photoDelegate: PhotoCaptureDelegate?
    private var startID: UUID?
    private var captureID: UUID?
    private var wantsRunning = false
    private var sessionObservation: SessionObservation?

    init() {
        let notifications: [Notification.Name] = [
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.interruptionEndedNotification,
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.didStopRunningNotification,
            AVCaptureSession.didStartRunningNotification
        ]
        let observers = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: captureSession, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sessionChanged(name) }
            }
        }
        sessionObservation = SessionObservation(observers)
    }

    // MARK: Lifecycle

    func start() async {
        wantsRunning = true
        guard state != .running || !captureSession.isRunning || captureSession.isInterrupted else { return }
        guard startID == nil else { return }
        let id = UUID()
        startID = id
        defer { if startID == id { startID = nil } }

        let hasAccess = await requestAccess()
        guard startID == id, !Task.isCancelled else { return }
        guard hasAccess else {
            state = .unavailable("Listing Force needs camera access. Enable it in Settings to photograph products.")
            return
        }
        do {
            try await hardware.start { [weak self] stats in
                Task { @MainActor in self?.lighting = LightingAssessment.verdict(for: stats) }
            }
        } catch {
            guard startID == id else { return }
            state = .unavailable(error is CameraHardware.NoCamera
                ? "No camera on this device. Import a photo from your library instead."
                : "The camera could not be started. Try again.")
            return
        }
        guard startID == id, !Task.isCancelled else { return }
        state = captureSession.isRunning && !captureSession.isInterrupted
            ? .running : .unavailable("The camera could not be started. Try again.")
    }

    func stop() {
        wantsRunning = false
        startID = nil
        photoDelegate?.fail(CancellationError())
        hardware.stop()
        state = .idle
    }

    private func sessionChanged(_ notification: Notification.Name) {
        guard wantsRunning else { return }
        switch notification {
        case AVCaptureSession.wasInterruptedNotification:
            state = .unavailable("Camera paused by the system. It will resume when the camera is available.")
            photoDelegate?.fail(CameraError.interrupted)
        case AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification:
            state = .unavailable("The camera stopped. Try starting it again.")
            photoDelegate?.fail(CameraError.interrupted)
        case AVCaptureSession.interruptionEndedNotification:
            Task { [weak self] in
                guard let self, self.wantsRunning else { return }
                await self.start()
            }
        case AVCaptureSession.didStartRunningNotification:
            if captureSession.isRunning, !captureSession.isInterrupted { state = .running }
        default:
            break
        }
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// All metering changes share the hardware queue with configuration and capture.
    func applyExposureLock(_ locked: Bool) { hardware.applyExposureLock(locked) }

    // MARK: Capture

    func resetSeries() {
        guard !isCapturing else { return }
        series.reset()
        applyExposureLock(false)
    }

    func discardLastShot() {
        series.discardLastShot()
        applyExposureLock(series.exposureLock == .locked)
    }

    /// Keeps the HEIF data and its orientation metadata until segmentation.
    func capturePhoto(flashMode: AVCaptureDevice.FlashMode = .auto) async throws -> Data {
        guard state == .running, captureSession.isRunning, !captureSession.isInterrupted else { throw CameraError.notRunning }
        guard !isCapturing, series.canCapture else { throw CameraError.captureUnavailable }
        try Task.checkCancellation()
        let id = UUID()
        captureID = id
        isCapturing = true
        var timeout: Task<Void, Never>?
        defer {
            timeout?.cancel()
            isCapturing = false
            captureID = nil
            photoDelegate = nil
        }

        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = PhotoCaptureDelegate { result in
                    continuation.resume(with: result)
                }
                self.photoDelegate = delegate
                timeout = Task { [weak self, weak delegate] in
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { return }
                    guard let self, self.captureID == id else { return }
                    delegate?.fail(CameraError.captureTimedOut)
                    self.stop()
                    self.state = .unavailable("The camera took too long. Try starting it again.")
                }
                hardware.capture(flashMode: flashMode, delegate: delegate)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.captureID == id else { return }
                self.photoDelegate?.fail(CancellationError())
            }
        }

        try Task.checkCancellation()
        guard state == .running else { throw CameraError.notRunning }
        series.recordShot()
        applyExposureLock(series.exposureLock == .locked)
        return data
    }
}


/// AVFoundation mutable state is confined to `queue`; only the immutable session
/// reference is exposed for the preview layer and thread-safe status reads.
private final class CameraHardware: @unchecked Sendable {
    struct NoCamera: Error {}
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.ctt.listingforge.camera")
    private var device: AVCaptureDevice?
    private var photoOutput: AVCapturePhotoOutput?
    private var analyzer: FrameAnalyzer?
    private var configured = false

    func start(onStats: @escaping @Sendable (LuminanceStats) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    if !configured {
                        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        else { throw NoCamera() }
                        try configure(camera: camera, onStats: onStats)
                        device = camera
                        configured = true
                    }
                    session.startRunning()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { sessionQueue.async { [self] in session.stopRunning() } }

    func capture(flashMode: AVCaptureDevice.FlashMode, delegate: PhotoCaptureDelegate) {
        sessionQueue.async { [self] in
            guard session.isRunning, !session.isInterrupted, let photoOutput else {
                delegate.fail(CameraError.notRunning)
                return
            }
            let settings = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func applyExposureLock(_ locked: Bool) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
                let whiteBalance: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
                if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
                if device.isWhiteBalanceModeSupported(whiteBalance) { device.whiteBalanceMode = whiteBalance }
            } catch { /* Capture remains available when hardware cannot lock metering. */ }
        }
    }

    private func configure(camera: AVCaptureDevice, onStats: @escaping @Sendable (LuminanceStats) -> Void) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        var succeeded = false
        defer {
            if !succeeded {
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                photoOutput = nil
                analyzer = nil
            }
        }

        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        let photo = AVCapturePhotoOutput()
        guard session.canAddOutput(photo) else { throw CameraError.configurationFailed }
        session.addOutput(photo)
        photoOutput = photo
        if let connection = photo.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // Preview frames, used only to judge the light.
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let analyzer = FrameAnalyzer(onStats: onStats)
        video.setSampleBufferDelegate(analyzer, queue: sessionQueue)
        if session.canAddOutput(video) {
            session.addOutput(video)
            self.analyzer = analyzer
        }
        succeeded = true
    }

}

/// Removes observers on release without accessing main-actor state in deinit.
private final class SessionObservation {
    private let observers: [NSObjectProtocol]

    init(_ observers: [NSObjectProtocol]) { self.observers = observers }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

enum CameraError: LocalizedError {
    case configurationFailed
    case notRunning
    case noImageData
    case captureUnavailable
    case interrupted
    case captureTimedOut

    var errorDescription: String? {
        switch self {
        case .configurationFailed, .notRunning:
            return "The camera isn’t ready. Try again."
        case .noImageData:
            return "That photo didn’t save. Try again."
        case .captureUnavailable:
            return "Finish the current photo or start a new product before taking another shot."
        case .interrupted:
            return "The camera was interrupted. Wait for it to resume, then try the photo again."
        case .captureTimedOut:
            return "The camera took too long to return a photo. Start it again and retry this shot."
        }
    }
}

// MARK: - Photo delegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    // Device callbacks, cancellation, and timeout must resolve a shot only once.
    private let lock = NSLock()
    private var finished = false
    private var result: Result<Data, Error>?

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let processed: Result<Data, Error>
        if let error {
            processed = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            processed = .success(data)
        } else {
            processed = .failure(CameraError.noImageData)
        }
        lock.lock()
        if !finished { result = processed }
        lock.unlock()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        lock.lock()
        let processed = result
        lock.unlock()
        if let error {
            fail(error)
        } else {
            finish(processed ?? .failure(CameraError.noImageData))
        }
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ outcome: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        result = nil
        lock.unlock()
        completion(outcome)
    }
}

// MARK: - Lighting from the preview stream

/// Reads the luma plane of preview frames to judge the light.
///
/// The Y plane of a 420 buffer *is* luminance, so no colour conversion is
/// needed — and sampling a grid rather than every pixel keeps this off the
/// frame budget.
private final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let onStats: (LuminanceStats) -> Void
    private var lastRun = Date.distantPast
    /// Four times a second is plenty for advice a human reads.
    private let interval: TimeInterval = 0.25

    init(onStats: @escaping (LuminanceStats) -> Void) {
        self.onStats = onStats
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastRun) >= interval else { return }
        lastRun = now

        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let stats = Self.luminance(of: buffer) else { return }
        onStats(stats)
    }

    static func luminance(of buffer: CVPixelBuffer) -> LuminanceStats? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return nil }

        let step = max(1, min(width, height) / 120)
        var sum = 0.0
        var sumSquares = 0.0
        var shadows = 0
        var highlights = 0
        var count = 0

        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: step) {
                let value = Double(row[x]) / 255.0
                sum += value
                sumSquares += value * value
                if value < 0.04 { shadows += 1 }
                if value > 0.96 { highlights += 1 }
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)

        return LuminanceStats(
            mean: mean,
            standardDeviation: variance.squareRoot(),
            clippedShadowFraction: Double(shadows) / Double(count),
            clippedHighlightFraction: Double(highlights) / Double(count)
        )
    }
}
