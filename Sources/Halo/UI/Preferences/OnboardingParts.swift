import AppKit
import SwiftUI

// MARK: - Animated mark

/// The Halo mark, alive: the ring draws itself on, a highlight orbits, and the
/// node breathes. Used on the first page of onboarding, where a static logo
/// would say nothing about what the app does.
struct AnimatedHaloMark: View {

    var accent: Color = Color(hex: "#FFC46B") ?? .orange
    var secondary: Color = Color(hex: "#9B8CFF") ?? .purple

    @State private var drawn = false
    @State private var orbit = false
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = size * 0.36

            ZStack {
                // Base ring, drawn on rather than faded in.
                Circle()
                    .trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Color.primary.opacity(0.20),
                            style: StrokeStyle(lineWidth: size * 0.018, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(-90))
                    .position(center)

                // Highlight running around the ring.
                Circle()
                    .trim(from: 0, to: 0.16)
                    .stroke(LinearGradient(colors: [accent.opacity(0), accent, secondary.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: size * 0.030, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(orbit ? 270 : -90))
                    .position(center)
                    .opacity(drawn ? 1 : 0)
                    .shadow(color: accent.opacity(0.5), radius: size * 0.05)

                // The one lit node.
                Circle()
                    .fill(accent)
                    .frame(width: size * 0.10, height: size * 0.10)
                    .shadow(color: accent.opacity(0.85), radius: size * (breathing ? 0.11 : 0.05))
                    .scaleEffect(drawn ? (breathing ? 1.12 : 0.94) : 0.2)
                    .position(x: center.x, y: center.y - radius)

                // Core.
                Circle()
                    .fill(Color.primary.opacity(0.13))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .scaleEffect(drawn ? 1 : 0.3)
                    .position(center)
            }
        }
        .onAppear(perform: start)
    }

    private func start() {
        guard !reduceMotion else {
            drawn = true
            return
        }
        withAnimation(.easeOut(duration: 0.7)) { drawn = true }
        withAnimation(.linear(duration: 6).repeatForever(autoreverses: false).delay(0.3)) {
            orbit = true
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.7)) {
            breathing = true
        }
    }
}

// MARK: - Gesture demo

/// A miniature Halo that performs the summon gesture on a loop.
///
/// The gesture is the whole product and it is hard to describe in a sentence,
/// so onboarding shows it instead: the ring blooms, a pointer flicks toward a
/// node, the node fires, everything clears, and it goes again with a different
/// target.
struct GestureDemoView: View {

    var accent: Color = Color(hex: "#FFC46B") ?? .orange

    private enum Phase { case summon, aim, fire, clear }

    private let glyphs = ["safari", "envelope", "terminal", "globe",
                          "doc.on.clipboard", "gearshape"]

    @State private var phase: Phase = .clear
    @State private var target = 0
    @State private var pointer: CGSize = .zero
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { phase != .clear }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = min(proxy.size.width, proxy.size.height) / 2 - 24
            let layout = RingLayout(startAngle: .pi / 2, sweep: 2 * .pi,
                                    clockwise: true, count: glyphs.count)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.11))

                Circle()
                    .trim(from: 0, to: isOpen ? 1 : 0)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(-90))
                    .position(center)

                ForEach(Array(glyphs.enumerated()), id: \.offset) { index, glyph in
                    let point = RingGeometry.point(index: index, layout: layout,
                                                   radius: radius, center: center)
                    let selected = phase != .summon && phase != .clear && index == target
                    node(glyph: glyph, selected: selected, firing: selected && phase == .fire)
                        .position(isOpen ? point : center)
                        .opacity(isOpen ? 1 : 0)
                        .scaleEffect(isOpen ? 1 : 0.3)
                }

                // Pointer: the thing the user's hand is doing.
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .overlay {
                        Circle()
                            .stroke(accent.opacity(phase == .fire ? 0.9 : 0), lineWidth: 2)
                            .scaleEffect(phase == .fire ? 3.2 : 1)
                            .opacity(phase == .fire ? 0 : 1)
                    }
                    .position(center)
                    .offset(pointer)
                    .opacity(isOpen ? 1 : 0)

                Text(caption)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .position(x: center.x, y: proxy.size.height - 12)
            }
            .onAppear { start(radius: radius, layout: layout) }
            .onDisappear { timer?.invalidate(); timer = nil }
        }
    }

    private var caption: String {
        switch phase {
        case .summon: return "押したまま — リングが出る"
        case .aim:    return "方向へ弾く"
        case .fire:   return "離す — 実行"
        case .clear:  return " "
        }
    }

    private func node(glyph: String, selected: Bool, firing: Bool) -> some View {
        ZStack {
            Circle().fill(Color(red: 0.14, green: 0.14, blue: 0.17))
            Circle().stroke(selected ? accent.opacity(0.9) : Color.white.opacity(0.14),
                            lineWidth: selected ? 1.3 : 0.75)
            Image(systemName: glyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? accent : Color.white.opacity(0.72))
        }
        .frame(width: 34, height: 34)
        .scaleEffect(firing ? 1.42 : (selected ? 1.18 : 1))
        .shadow(color: selected ? accent.opacity(0.6) : .clear, radius: firing ? 18 : 10)
    }

    // MARK: Loop

    private func start(radius: Double, layout: RingLayout) {
        guard timer == nil else { return }
        guard !reduceMotion else {
            phase = .aim
            return
        }
        runCycle(radius: radius, layout: layout)
        let timer = Timer.scheduledTimer(withTimeInterval: 3.4, repeats: true) { _ in
            MainActor.assumeIsolated { runCycle(radius: radius, layout: layout) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func runCycle(radius: Double, layout: RingLayout) {
        target = Int.random(in: 0..<glyphs.count)
        let angle = layout.angle(at: target)
        // View space is y-down, so the vertical component is negated.
        let destination = CGSize(width: radius * cos(angle) * 0.74,
                                 height: -radius * sin(angle) * 0.74)

        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
            phase = .summon
            pointer = .zero
        }
        after(0.55) {
            withAnimation(.spring(response: 0.40, dampingFraction: 0.7)) {
                phase = .aim
                pointer = destination
            }
        }
        after(1.55) {
            withAnimation(.easeOut(duration: 0.26)) { phase = .fire }
        }
        after(2.15) {
            withAnimation(.easeIn(duration: 0.24)) {
                phase = .clear
                pointer = .zero
            }
        }
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }
}

// MARK: - Staggered reveal

/// Fades a view in from slightly below, after a delay. Used to let onboarding
/// pages assemble themselves instead of appearing all at once.
struct Reveal<Content: View>: View {

    let delay: Double
    @ViewBuilder let content: Content

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(delay)) {
                    shown = true
                }
            }
    }
}
