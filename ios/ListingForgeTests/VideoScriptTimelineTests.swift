import Foundation
import Testing
@testable import ListingForge

@Suite("Video script timeline")
struct VideoScriptTimelineTests {
    private func beat(_ seconds: Double, _ text: String = "x") -> Beat {
        Beat(seconds: seconds, voiceover: text, shot: "close-up", onScreenText: text)
    }

    private var script: ScriptShape {
        ScriptShape(id: "s1", hook: beat(3, "Oily skin still dry?"),
                    scenes: [beat(7), beat(8), beat(7), beat(5)])
    }

    @Test("Durations accumulate into start marks, not used as marks themselves")
    func accumulatesStarts() {
        let t = VideoScriptTimeline.build(script)
        #expect(t.map(\.start) == [0, 3, 10, 18, 25])
        #expect(t.map(\.end) == [3, 10, 18, 25, 30])
    }

    @Test("The hook comes first and is labelled on its own")
    func hookFirst() {
        let t = VideoScriptTimeline.build(script)
        #expect(t[0].kind == .hook)
        #expect(t[0].label == "HOOK")
        #expect(t[1].label == "SCENE 1")
    }

    @Test("The total comes from the sum, not a model-provided total")
    func totalFromSum() {
        #expect(VideoScriptTimeline.totalSeconds(VideoScriptTimeline.build(script)) == 30)
    }

    @Test("A zero-second scene never stalls the playhead")
    func zeroSecondScene() {
        let t = VideoScriptTimeline.build(ScriptShape(id: "z", hook: beat(0), scenes: [beat(0)]))
        #expect(t.allSatisfy { $0.duration > 0 })
        #expect(VideoScriptTimeline.totalSeconds(t) > 0)
    }

    @Test("Garbage values from the model never produce NaN")
    func garbageValues() {
        let bad = ScriptShape(id: "b", hook: beat(.nan),
                              scenes: [beat(-5), beat(.infinity)])
        let t = VideoScriptTimeline.build(bad)
        #expect(t.allSatisfy { $0.start.isFinite && $0.duration > 0 })
    }

    @Test("A script with no scenes still yields exactly one hook")
    func noScenes() {
        #expect(VideoScriptTimeline.build(ScriptShape(id: "h", hook: beat(3), scenes: [])).count == 1)
    }

    @Test("Second 0 is the hook")
    func secondZeroIsHook() {
        #expect(VideoScriptTimeline.segmentIndex(VideoScriptTimeline.build(script), at: 0) == 0)
    }

    @Test("On a boundary it moves to the next scene, not stuck on the previous")
    func boundaryMovesForward() {
        let t = VideoScriptTimeline.build(script)
        #expect(VideoScriptTimeline.segmentIndex(t, at: 2.999) == 0)
        #expect(VideoScriptTimeline.segmentIndex(t, at: 3) == 1)
        #expect(VideoScriptTimeline.segmentIndex(t, at: 10) == 2)
    }

    @Test("Past the end it holds on the last scene rather than returning -1")
    func pastEndHolds() {
        let t = VideoScriptTimeline.build(script)
        #expect(VideoScriptTimeline.segmentIndex(t, at: 30) == 4)
        #expect(VideoScriptTimeline.segmentIndex(t, at: 999) == 4)
    }

    @Test("An empty timeline returns 0, never negative")
    func emptyReturnsZero() {
        #expect(VideoScriptTimeline.segmentIndex([], at: 5) == 0)
    }

    @Test("Time marks format as m:ss")
    func formatsTime() {
        #expect(VideoScriptTimeline.mmss(0) == "0:00")
        #expect(VideoScriptTimeline.mmss(7.9) == "0:07")
        #expect(VideoScriptTimeline.mmss(30) == "0:30")
    }

    @Test("Negative seconds never produce garbage")
    func negativeTime() {
        #expect(VideoScriptTimeline.mmss(-3) == "0:00")
    }
}
