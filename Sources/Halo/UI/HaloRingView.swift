import AppKit
import SwiftUI

/// The summoned ring.
///
/// Composition, outside in:
///   · a backdrop (none / dim / vignette / blur)
///   · echo rings — every parent ring, shrunk and dimmed, still visible inside
///   · the halo itself: a hairline circle, plus a lit arc that tracks selection
///   · a comet head that slides along the halo toward the selected node
///   · nodes floating *on* the circumference, never wedges
///   · a core showing the ring name, the selected label, and depth pips
///
/// Almost every constant here is user-tunable through `Appearance`, so the view
/// reads its geometry from the layout rather than hard-coding a full circle.
struct HaloRingView: View {

    @ObservedObject private var controller = RingController.shared
    @ObservedObject private var store = ConfigStore.shared

    /// Length of the lit arc, in turns.
    private static let arcSpan = 0.20

    private var appearance: Appearance { store.config.appearance }
    private var theme: HaloTheme { HaloTheme.from(appearance) }
    private var glow: Double { appearance.glowIntensity }

    private var items: [RingItem] { controller.visibleItems }
    private var layout: RingLayout { appearance.layout(count: max(items.count, 1)) }

    // MARK: Summoning

    /// The entrance is driven by one boolean rather than by interpolating an
    /// opacity: each layer then owns its own timing, which is what turns a fade
    /// into a summoning — the ring draws itself around, the nodes arrive in
    /// sequence, and a ripple leaves the centre.
    private var shown: Bool { controller.presentationProgress > 0.5 }

    /// User-tunable speed, applied to every entrance duration.
    private var speed: Double { max(appearance.animationSpeed, 0.2) }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whole-ring settle. Exits fast so dismissing never feels sticky.
    private var groupAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return shown
            ? .spring(response: 0.42 / speed, dampingFraction: 0.74)
            : .easeIn(duration: 0.12 / speed)
    }

    /// Nodes arrive one after another, sweeping around the ring.
    private func nodeAnimation(index: Int) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        guard shown else { return .easeIn(duration: 0.10 / speed) }
        return .spring(response: 0.40 / speed, dampingFraction: 0.68)
            .delay(0.055 / speed + Double(index) * 0.028 / speed)
    }

    private var ringDrawAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return shown
            ? .easeOut(duration: 0.42 / speed)
            : .easeIn(duration: 0.12 / speed)
    }

    var body: some View {
        GeometryReader { proxy in
            let center = viewCenter(in: proxy.size)
            ZStack {
                backdrop(center: center, size: proxy.size)
                    .opacity(shown ? 1 : 0)
                    .animation(.easeOut(duration: (shown ? 0.26 : 0.12) / speed), value: shown)

                ZStack {
                    echoRings(center: center)
                    halo(center: center)
                    if shown && !controller.isOffscreenRender && !reduceMotion {
                        SummonRipple(radius: appearance.ringRadius,
                                     color: theme.accent, speed: speed)
                            .position(center)
                    }
                    nodes(center: center)
                    core(center: center)
                }
                .compositingGroup()
                // Scale and rotation are cosmetic only — selection is computed
                // from the cursor against the fixed centre, never from the view.
                .scaleEffect(shown ? 1 : 0.84, anchor: anchorUnit(center: center, in: proxy.size))
                .rotationEffect(.degrees(shown || reduceMotion ? 0 : -9),
                                anchor: anchorUnit(center: center, in: proxy.size))
                .opacity(shown ? 1 : 0)
                .animation(groupAnimation, value: shown)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(controller.activeRing?.title ?? "Halo")
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func backdrop(center: CGPoint, size: CGSize) -> some View {
        switch appearance.backdrop {
        case .none:
            EmptyView()
        case .dim:
            Rectangle().fill(Color.black.opacity(appearance.backdropStrength))
        case .vignette:
            RadialGradient(
                gradient: Gradient(colors: [Color.black.opacity(appearance.backdropStrength),
                                            Color.black.opacity(0.0)]),
                center: .init(x: center.x / max(size.width, 1), y: center.y / max(size.height, 1)),
                startRadius: 0,
                endRadius: appearance.ringRadius * 2.1
            )
            .blendMode(.multiply)
        case .blur:
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(appearance.backdropStrength * 0.5))
        }
    }

    /// Parent rings do not disappear when you dive — they contract inward and
    /// stay lit, so the path you took is always readable.
    private func echoRings(center: CGPoint) -> some View {
        let depth = controller.stack.count
        return ZStack {
            ForEach(0..<max(depth - 1, 0), id: \.self) { level in
                let stepsIn = depth - 1 - level
                let scale = pow(0.56, Double(stepsIn))
                Circle()
                    .stroke(theme.ringBase.opacity(0.5 / Double(stepsIn)),
                            lineWidth: appearance.ringThickness)
                    .frame(width: appearance.ringRadius * 2 * scale,
                           height: appearance.ringRadius * 2 * scale)
                    .position(center)
            }
        }
    }

    // MARK: - Halo

    private func halo(center: CGPoint) -> some View {
        let radius = appearance.ringRadius
        let selectedAngle = controller.selection.map { RingGeometry.angle(index: $0, layout: layout) }

        return ZStack {
            // Base hairline. A partial sweep draws only the arc the nodes use,
            // and on summon the stroke is drawn on rather than faded in.
            Circle()
                .trim(from: 0, to: shown ? sweepFraction : 0)
                .stroke(theme.ringBase, lineWidth: appearance.ringThickness)
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(baseRingRotation)
                .position(center)
                .animation(ringDrawAnimation, value: shown)

            if let selectedAngle, appearance.showArc {
                // `trim` starts at 3 o'clock and runs clockwise, so the segment
                // has to be rotated back by its own span to sit on the node.
                Circle()
                    .trim(from: 0, to: Self.arcSpan)
                    .stroke(
                        LinearGradient(colors: [theme.accent.opacity(0.0),
                                                theme.accent,
                                                theme.secondary.opacity(0.0)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.4 + appearance.ringThickness, lineCap: .round)
                    )
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.radians(-selectedAngle - Self.arcSpan * 2 * .pi))
                    .position(center)
                    .blur(radius: 0.4)
                    .shadow(color: theme.accent.opacity(0.55 * glow), radius: 10 * glow)
                    .animation(.spring(response: 0.22, dampingFraction: 0.72), value: controller.selection)
            }

            if appearance.showComet, controller.selection != nil {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: theme.accent.opacity(0.9 * glow), radius: 8 * glow)
                    .position(RingGeometry.point(index: controller.selection ?? 0,
                                                 layout: layout,
                                                 radius: radius,
                                                 center: center))
                    .animation(.spring(response: 0.24, dampingFraction: 0.7), value: controller.selection)
            }

            // A filament from the core to the selection — the "summoning" thread.
            if let selectedAngle, appearance.showFilament {
                Path { path in
                    path.move(to: center)
                    path.addLine(to: CGPoint(x: center.x + radius * cos(selectedAngle),
                                             y: center.y - radius * sin(selectedAngle)))
                }
                .stroke(
                    LinearGradient(colors: [theme.accent.opacity(0.0), theme.accent.opacity(0.35)],
                                   startPoint: .center, endPoint: .top),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 5])
                )
                .animation(.easeOut(duration: 0.18), value: controller.selection)
            }
        }
    }

    /// Fraction of the circle the base ring should draw for the current sweep.
    private var sweepFraction: Double {
        min(max(appearance.sweepDegrees, 30), 360) / 360
    }

    /// Rotates the trimmed base ring so it starts where the first node does.
    private var baseRingRotation: Angle {
        guard sweepFraction < 1 else { return .zero }
        let first = layout.angle(at: 0)
        let last = layout.angle(at: max(layout.count - 1, 0))
        let arcStart = appearance.clockwise ? last : first
        return .radians(-arcStart - sweepFraction * 2 * .pi)
    }

    // MARK: - Nodes

    private func nodes(center: CGPoint) -> some View {
        let radius = appearance.ringRadius
        let showLabels = appearance.labelPlacement != .hidden

        return ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let position = RingGeometry.point(index: index, layout: layout,
                                                  radius: radius, center: center)
                let isSelected = controller.selection == index

                NodeView(item: item,
                         index: index,
                         isSelected: isSelected,
                         appearance: appearance,
                         theme: theme)
                    .scaleEffect(shown ? 1 : 0.35)
                    .opacity(shown ? 1 : 0)
                    .position(shown ? position : center)
                    .zIndex(isSelected ? 1 : 0)
                    .animation(nodeAnimation(index: index), value: shown)
                    .accessibilityElement()
                    .accessibilityLabel(item.title)
                    .accessibilityValue(item.action.kind.displayName)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

                if showLabels, appearance.labelPlacement != .selectedOnly || isSelected {
                    NodeLabel(text: item.title,
                              isSelected: isSelected,
                              size: appearance.labelSize,
                              theme: theme)
                        .opacity(shown ? 1 : 0)
                        .position(labelPosition(index: index, radius: radius, center: center))
                        .animation(nodeAnimation(index: index), value: shown)
                        .accessibilityHidden(true)   // the node already says this
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: items.map(\.id))
    }

    // MARK: - Core

    @ViewBuilder
    private func core(center: CGPoint) -> some View {
        if appearance.coreStyle != .hidden {
            let selectedItem = controller.selection.flatMap { controller.itemAt($0) }
            let filtering = !controller.filter.isEmpty
            let title = filtering
                ? controller.filter
                : (selectedItem?.title ?? controller.activeRing?.title ?? "Halo")

            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    if filtering {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: appearance.labelSize - 1.5, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    Text(title)
                        .font(.system(size: appearance.labelSize + 1,
                                      weight: (selectedItem == nil && !filtering) ? .medium : .semibold,
                                      design: .rounded))
                        .foregroundStyle((selectedItem == nil && !filtering)
                                         ? theme.label : theme.labelSelected)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if filtering && items.isEmpty {
                    Text("一致なし")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.4))
                } else if filtering, let selectedItem {
                    Text(selectedItem.title)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.accent.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if controller.stack.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(0..<controller.stack.count, id: \.self) { level in
                            Circle()
                                .fill(level == controller.stack.count - 1
                                      ? theme.accent : Color.white.opacity(0.28))
                                .frame(width: 3.5, height: 3.5)
                        }
                    }
                } else if controller.sticky {
                    Text("クリックで実行 · 入力で絞り込み")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
            .padding(.horizontal, appearance.coreStyle == .capsule ? 12 : 0)
            .padding(.vertical, appearance.coreStyle == .capsule ? 9 : 0)
            .background {
                if appearance.coreStyle == .capsule {
                    Capsule(style: .continuous)
                        .fill(theme.coreFill)
                        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                        .overlay(Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.75))
                        .clipShape(Capsule(style: .continuous))
                }
            }
            .shadow(color: .black.opacity(appearance.coreStyle == .minimal ? 0.8 : 0), radius: 4)
            .scaleEffect(shown ? 1 : 0.55)
            .opacity(shown ? 1 : 0)
            .position(center)
            .animation(.easeOut(duration: 0.12), value: controller.selection)
            .animation(.easeOut(duration: 0.12), value: controller.filter)
            .animation(reduceMotion ? .easeOut(duration: 0.12)
                       : .spring(response: 0.34 / speed, dampingFraction: 0.7), value: shown)
        }
    }

    // MARK: - Geometry helpers

    /// The panel spans the whole screen, so the ring's centre is the summon
    /// point converted from screen (y-up) to view (y-down) coordinates.
    private func viewCenter(in size: CGSize) -> CGPoint {
        let frame = controller.screenFrame
        guard frame.width > 0 else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(x: controller.center.x - frame.minX,
                       y: frame.maxY - controller.center.y)
    }

    /// Unit-space position of the ring centre, so scale and rotation pivot on
    /// the cursor instead of the middle of the screen.
    private func anchorUnit(center: CGPoint, in size: CGSize) -> UnitPoint {
        UnitPoint(x: center.x / max(size.width, 1), y: center.y / max(size.height, 1))
    }

    /// Labels sit clear of the node along its own direction. Nodes near 3 and 9
    /// o'clock get an extra horizontal push, where a purely radial offset still
    /// leaves the text grazing the circle.
    private func labelPosition(index: Int, radius: Double, center: CGPoint) -> CGPoint {
        let angle = RingGeometry.angle(index: index, layout: layout)
        let clearance = appearance.nodeSize / 2 + appearance.labelSize + 8
        let inside = appearance.labelPlacement == .inside
        let offset = inside ? -clearance : clearance + abs(cos(angle)) * 38
        return RingGeometry.point(index: index, layout: layout,
                                  radius: radius + offset, center: center)
    }
}

// MARK: - Summon ripple

/// A single ring of light leaving the centre as Halo is summoned.
///
/// Driven by `onAppear` rather than by the shared progress value so it plays
/// once per summon and is simply absent — not merely transparent — while the
/// ring is closing.
private struct SummonRipple: View {

    let radius: Double
    let color: Color
    let speed: Double

    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1.6)
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(expanded ? 1.18 : 0.12)
                .opacity(expanded ? 0 : 0.85)

            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.28), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: radius))
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(expanded ? 1.0 : 0.05)
                .opacity(expanded ? 0 : 0.9)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.58 / speed)) { expanded = true }
        }
    }
}

// MARK: - Node

private struct NodeView: View {

    let item: RingItem
    let index: Int
    let isSelected: Bool
    let appearance: Appearance
    let theme: HaloTheme

    private var size: Double { appearance.nodeSize }
    private var glow: Double { appearance.glowIntensity }

    private var tint: Color {
        item.tint.flatMap { Color(hex: $0) } ?? theme.accent
    }

    var body: some View {
        ZStack {
            shape
                .fill(theme.nodeFill)
                .background(shape.fill(.ultraThinMaterial))
                .clipShape(shape)

            shape
                .stroke(isSelected ? tint.opacity(0.85) : theme.nodeStroke,
                        lineWidth: isSelected ? 1.4 : 0.75)

            icon

            if appearance.showKeyHints && index < 9 {
                keyHint
            }
        }
        .frame(width: size, height: size)
        .shadow(color: isSelected ? tint.opacity(0.55 * glow) : .black.opacity(0.28),
                radius: isSelected ? 14 * glow : 6,
                y: isSelected ? 0 : 2)
        .scaleEffect(isSelected ? 1.20 : 1.0)
        .animation(.spring(response: 0.24, dampingFraction: 0.65), value: isSelected)
    }

    private var shape: AnyShape {
        switch appearance.nodeShape {
        case .circle:
            return AnyShape(Circle())
        case .roundedSquare:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        case .hexagon:
            return AnyShape(RegularPolygon(sides: 6, rotation: .degrees(90)))
        case .diamond:
            return AnyShape(RegularPolygon(sides: 4, rotation: .degrees(90)))
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let appIcon = AppIndex.icon(for: item.action) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 0.52, height: size * 0.52)
                .saturation(appearance.iconStyle == .monochrome ? 0 : (isSelected ? 1.0 : 0.82))
                .opacity(isSelected ? 1.0 : 0.88)
        } else {
            Image(systemName: item.effectiveGlyph)
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(isSelected ? tint : theme.glyph)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var keyHint: some View {
        Text("\(index + 1)")
            .font(.system(size: size * 0.20, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(width: size * 0.30, height: size * 0.30)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .offset(x: size * 0.34, y: -size * 0.34)
    }
}

/// Regular polygon used for the hexagon and diamond node shapes.
private struct RegularPolygon: Shape {
    let sides: Int
    var rotation: Angle = .zero

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0..<max(sides, 3) {
            let angle = rotation.radians + 2 * .pi * Double(i) / Double(max(sides, 3))
            let point = CGPoint(x: center.x + radius * cos(angle),
                                y: center.y - radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct NodeLabel: View {

    let text: String
    let isSelected: Bool
    let size: Double
    let theme: HaloTheme

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: isSelected ? .semibold : .regular, design: .rounded))
            .foregroundStyle(isSelected ? theme.labelSelected : theme.label)
            .lineLimit(1)
            .truncationMode(.tail)
            // fixedSize keeps the pill hugging the text; without it every label
            // would reserve the full width and the selected one would render as
            // a wide black bar.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background {
                if isSelected {
                    Capsule().fill(Color.black.opacity(0.5))
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 3)
            .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}
