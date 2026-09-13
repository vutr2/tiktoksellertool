//
//  CaptureSeriesTests.swift
//  ListingForgeTests
//
//  SPEC §4.2 wants exposure and white balance held across a series so multiple
//  angles of one SKU match. These pin when the lock engages and when it drops.
//

import Foundation
import Testing
@testable import ListingForge

@MainActor
@Suite("Capture series")
struct CaptureSeriesTests {

    @Test("A new series starts unlocked on shot 1 of 3")
    func startsUnlocked() {
        let series = CaptureSeries()

        #expect(series.shotsTaken == 0)
        #expect(series.currentShotNumber == 1)
        #expect(series.maximumShots == 3)
        #expect(series.exposureLock == .unlocked)
        #expect(series.canCapture)
        #expect(!series.isComplete)
    }

    @Test("The caption matches the one in the design before the first shot")
    func captionBeforeFirstShot() {
        #expect(CaptureSeries().statusText == "Shot 1 of 3 · exposure will lock after the first shot")
    }

    @Test("Exposure locks on the first shot, so later angles match")
    func firstShotLocksExposure() {
        let series = CaptureSeries()

        series.recordShot()

        #expect(series.exposureLock == .locked)
        #expect(series.shotsTaken == 1)
        #expect(series.currentShotNumber == 2)
        #expect(series.statusText == "Shot 2 of 3 · exposure and white balance locked")
    }

    @Test("Later shots keep the lock rather than re-metering")
    func laterShotsKeepTheLock() {
        let series = CaptureSeries()
        series.recordShot()
        series.recordShot()

        #expect(series.exposureLock == .locked, "re-metering mid-series is the bug this guards")
        #expect(series.shotsTaken == 2)
    }

    @Test("The series stops at its maximum")
    func stopsAtMaximum() {
        let series = CaptureSeries()
        for _ in 0..<10 { series.recordShot() }

        #expect(series.shotsTaken == 3)
        #expect(series.isComplete)
        #expect(!series.canCapture)
        #expect(series.statusText == "All 3 shots taken")
    }

    @Test("The shot number never runs past the total once complete")
    func shotNumberClampsWhenComplete() {
        let series = CaptureSeries()
        for _ in 0..<3 { series.recordShot() }

        #expect(series.currentShotNumber == 3, "would read 'Shot 4 of 3'")
    }

    @Test("The lock affordance can re-meter and lock again")
    func lockCanBeToggled() {
        let series = CaptureSeries()
        series.recordShot()
        #expect(series.exposureLock == .locked)

        series.unlockExposure()
        #expect(series.exposureLock == .unlocked)
        #expect(series.statusText == "Shot 2 of 3 · exposure will lock after the first shot")

        series.lockExposure()
        #expect(series.exposureLock == .locked)
    }

    @Test("Re-metering mid-series does not re-lock until the next shot")
    func unlockSurvivesUntilNextShot() {
        let series = CaptureSeries()
        series.recordShot()
        series.unlockExposure()

        series.recordShot()

        // recordShot only locks when currently unlocked — so the seller's
        // deliberate re-meter is applied to this shot, then held again.
        #expect(series.exposureLock == .locked)
        #expect(series.shotsTaken == 2)
    }

    @Test("Starting a new product drops the previous product's exposure")
    func resetClearsTheLock() {
        let series = CaptureSeries()
        series.recordShot()
        series.recordShot()

        series.reset()

        // Carrying a lock across products shows up only as subtly wrong colour,
        // which is exactly the kind of bug nobody reports.
        #expect(series.shotsTaken == 0)
        #expect(series.exposureLock == .unlocked)
        #expect(series.canCapture)
    }

    @Test("A single-shot series is still valid")
    func singleShotSeries() {
        let series = CaptureSeries(maximumShots: 1)
        #expect(series.statusText == "Shot 1 of 1 · exposure will lock after the first shot")

        series.recordShot()
        #expect(series.isComplete)
    }

    @Test("A nonsensical shot count is clamped rather than breaking the shutter")
    func shotCountIsClamped() {
        #expect(CaptureSeries(maximumShots: 0).maximumShots == 1)
        #expect(CaptureSeries(maximumShots: -5).canCapture)
    }
}
