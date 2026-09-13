//
//  CaptureSeries.swift
//  ListingForge
//
//  One product's run of shots.
//
//  SPEC §4.2: "Locked exposure and white balance across a capture series, so
//  multiple angles of the same SKU match. Expose a 'lock' affordance after the
//  first shot." Unlocked metering between angles is what makes a seller's
//  gallery look like three different products.
//

import Foundation
import Observation

@MainActor
@Observable
final class CaptureSeries {

    enum ExposureLock: Equatable {
        /// Camera is still metering freely — before the first shot.
        case unlocked
        /// Held at the first shot's settings so later angles match.
        case locked
    }

    /// Three angles: main plus two supporting shots (Figma, screen 1).
    nonisolated static let defaultShotCount = 3

    let maximumShots: Int
    private(set) var shotsTaken = 0
    private(set) var exposureLock: ExposureLock = .unlocked

    init(maximumShots: Int = CaptureSeries.defaultShotCount) {
        self.maximumShots = max(1, maximumShots)
    }

    /// 1-based number of the shot about to be taken, clamped when finished.
    var currentShotNumber: Int { min(shotsTaken + 1, maximumShots) }

    var isComplete: Bool { shotsTaken >= maximumShots }
    var canCapture: Bool { !isComplete }

    /// The caption under the shutter.
    var statusText: String {
        if isComplete {
            return "All \(maximumShots) shots taken"
        }
        let prefix = "Shot \(currentShotNumber) of \(maximumShots)"
        switch exposureLock {
        case .unlocked:
            return "\(prefix) · exposure will lock after the first shot"
        case .locked:
            return "\(prefix) · exposure and white balance locked"
        }
    }

    /// Records a capture and locks metering from the first shot onward.
    func recordShot() {
        guard canCapture else { return }
        shotsTaken += 1
        if exposureLock == .unlocked {
            exposureLock = .locked
        }
    }

    /// Re-meters the scene. Offered as the "Lock AE/AWB" affordance so a seller
    /// who changed the lighting on purpose is not stuck with stale settings.
    func unlockExposure() {
        exposureLock = .unlocked
    }

    func lockExposure() {
        exposureLock = .locked
    }

    /// A failed cutout must leave room to retry the same angle.
    func discardLastShot() {
        shotsTaken = max(0, shotsTaken - 1)
        if shotsTaken == 0 { exposureLock = .unlocked }
    }

    /// Starts a new product. The lock must drop too — a fresh SKU is a fresh
    /// scene, and carrying the previous product's exposure over is a bug that
    /// only shows up as subtly wrong colour.
    func reset() {
        shotsTaken = 0
        exposureLock = .unlocked
    }
}
