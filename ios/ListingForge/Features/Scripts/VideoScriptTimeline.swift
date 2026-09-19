//
//  VideoScriptTimeline.swift
//  ListingForge
//
//  The timeline of a 30-second video script. Ported from tiktok_tools'
//  `timeline.ts`.
//
//  Kept separate from the view because this is the easy-to-get-wrong part and
//  it must be testable: each beat's `seconds` is a DURATION, not a start mark.
//  Summing them wrong makes the playhead drift from the voiceover.
//
//  Total duration always comes from this sum, never from a model-provided
//  total — models miscount, which is exactly what the server-side audit catches.
//

import Foundation

/// One beat of a script: what to say, how to shoot it, the on-screen caption,
/// and how long it lasts.
struct Beat: Codable, Hashable {
    let seconds: Double
    let voiceover: String
    let shot: String
    let onScreenText: String
}

/// A generated script: a 3-second hook followed by scenes.
struct ScriptShape: Codable, Hashable, Identifiable {
    let id: String
    let hook: Beat
    let scenes: [Beat]
}

/// A resolved segment with absolute start/end times, ready to drive a playhead.
struct Segment: Hashable {
    enum Kind { case hook, scene }

    let beat: Beat
    let kind: Kind
    let label: String
    let start: Double
    let end: Double
    let duration: Double

    var voiceover: String { beat.voiceover }
    var shot: String { beat.shot }
    var onScreenText: String { beat.onScreenText }
}

enum VideoScriptTimeline {
    /// Shortest allowed segment — a model returning 0 would stall the playhead.
    static let minSegmentSeconds = 0.5

    static func build(_ script: ScriptShape) -> [Segment] {
        var out: [Segment] = []
        var t = 0.0

        func push(_ beat: Beat, _ kind: Segment.Kind, _ label: String) {
            let raw = beat.seconds
            let duration = (raw.isFinite && raw > 0) ? max(minSegmentSeconds, raw) : 1
            out.append(Segment(beat: beat, kind: kind, label: label,
                               start: t, end: t + duration, duration: duration))
            t += duration
        }

        push(script.hook, .hook, "HOOK")
        for (i, scene) in script.scenes.enumerated() {
            push(scene, .scene, "SCENE \(i + 1)")
        }
        return out
    }

    static func totalSeconds(_ segments: [Segment]) -> Double {
        segments.last?.end ?? 0
    }

    /// The segment playing at `elapsed`. Past the end, holds on the last one.
    static func segmentIndex(_ segments: [Segment], at elapsed: Double) -> Int {
        if let i = segments.firstIndex(where: { elapsed < $0.end }) { return i }
        return max(0, segments.count - 1)
    }

    static func mmss(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }
}
