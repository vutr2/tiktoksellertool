//
//  ScriptPlayerView.swift
//  ListingForge
//
//  9:16 preview of a 30-second video script, ported (in English) from
//  tiktok_tools' script-player. The on-screen caption switches on the exact
//  second its segment starts, so the seller can shoot to the same timing.
//

import SwiftUI

@MainActor
@Observable
final class ScriptPlayer {
    let segments: [Segment]
    let total: Double
    private(set) var elapsed: Double = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastTick: Date?

    init(_ script: ScriptShape) {
        segments = VideoScriptTimeline.build(script)
        total = VideoScriptTimeline.totalSeconds(segments)
    }

    deinit { ticker?.cancel() }

    var currentIndex: Int { VideoScriptTimeline.segmentIndex(segments, at: elapsed) }
    var current: Segment? { segments.indices.contains(currentIndex) ? segments[currentIndex] : nil }
    var progress: Double { total > 0 ? min(1, elapsed / total) : 0 }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying, total > 0 else { return }
        if elapsed >= total { elapsed = 0 }
        isPlaying = true
        lastTick = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                await self?.advance()
            }
        }
    }

    func pause() {
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        lastTick = nil
    }

    func seek(to seconds: Double) {
        elapsed = min(max(0, seconds), total)
        lastTick = Date()
    }

    private func advance() {
        guard isPlaying, let last = lastTick else { return }
        let now = Date()
        elapsed = min(total, elapsed + now.timeIntervalSince(last))
        lastTick = now
        if elapsed >= total { pause() }
    }
}

struct ScriptPlayerView: View {
    @State private var player: ScriptPlayer
    /// Optional composited studio image shown behind the captions.
    let background: UIImage?

    init(script: ScriptShape, background: UIImage? = nil) {
        _player = State(initialValue: ScriptPlayer(script))
        self.background = background
    }

    var body: some View {
        VStack(spacing: 16) {
            phoneFrame
            controls
            if let segment = player.current { beatDetail(segment) }
        }
    }

    // MARK: 9:16 frame

    private var phoneFrame: some View {
        ZStack {
            if let background {
                Image(uiImage: background).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [.black, .gray.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(0.25)

            VStack {
                HStack {
                    if let segment = player.current {
                        Text(segment.label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    Text("\(VideoScriptTimeline.mmss(player.elapsed)) / \(VideoScriptTimeline.mmss(player.total))")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if let text = player.current?.onScreenText, !text.isEmpty {
                    Text(text)
                        .font(.title2.weight(.heavy))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                        .transition(.opacity)
                        .id(player.currentIndex)
                }
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxHeight: 460)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .animation(.easeInOut(duration: 0.2), value: player.currentIndex)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * player.progress)
                    // Segment boundary ticks.
                    ForEach(player.segments.dropLast(), id: \.start) { segment in
                        let x = player.total > 0 ? geo.size.width * (segment.end / player.total) : 0
                        Rectangle().fill(.background).frame(width: 1.5)
                            .offset(x: x)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard player.total > 0 else { return }
                    player.seek(to: player.total * (location.x / geo.size.width))
                }
            }
            .frame(height: 8)

            Button {
                player.toggle()
            } label: {
                Label(player.isPlaying ? "Pause" : "Play",
                      systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Beat detail (voiceover + shot for the current segment)

    private func beatDetail(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(segment.voiceover, systemImage: "quote.bubble")
                .font(.subheadline)
            Label(segment.shot, systemImage: "camera")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview {
    let script = ScriptShape(
        id: "demo",
        hook: Beat(seconds: 3, voiceover: "Oily skin but still flaky?",
                   shot: "Close-up on the serum bottle catching the light",
                   onScreenText: "Oily skin but STILL flaky?"),
        scenes: [
            Beat(seconds: 7, voiceover: "This niacinamide serum balances oil in two weeks.",
                 shot: "Hand pumping serum onto fingertip",
                 onScreenText: "2 weeks to balanced skin"),
            Beat(seconds: 8, voiceover: "Lightweight, absorbs fast, no sticky finish.",
                 shot: "Serum spreading on the back of the hand",
                 onScreenText: "Zero sticky finish"),
            Beat(seconds: 7, voiceover: "40% cheaper than the imports you know.",
                 shot: "Product next to a price tag",
                 onScreenText: "40% cheaper"),
            Beat(seconds: 5, voiceover: "Tap the cart before this batch sells out.",
                 shot: "Finger tapping an add-to-cart button",
                 onScreenText: "Tap the cart 🛒"),
        ]
    )
    return ScriptPlayerView(script: script).padding()
}
#endif
