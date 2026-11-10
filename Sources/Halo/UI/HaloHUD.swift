import AppKit
import SwiftUI

/// Transient message shown near the top of the active screen.
///
/// Halo used to route feedback through User Notifications, which needs an
/// authorised, properly signed bundle — so on a locally built copy a failing
/// script produced nothing but a line in the system log. The HUD is drawn by
/// Halo itself, so it always appears, needs no permission, and disappears on
/// its own.
@MainActor
final class HaloHUD {

    static let shared = HaloHUD()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private let model = Model()

    /// Observable payload so repeated messages reuse the same window.
    final class Model: ObservableObject {
        @Published var title = ""
        @Published var body = ""
        @Published var kind: Kind = .info
        @Published var visible = false
    }

    enum Kind {
        case info, success, failure

        var symbol: String {
            switch self {
            case .info:    return "circle.dotted"
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info:    return .white.opacity(0.7)
            case .success: return Color(hex: "#7BD88F") ?? .green
            case .failure: return Color(hex: "#FF9F6B") ?? .orange
            }
        }
    }

    private init() {}

    /// A non-finite `duration` keeps the HUD up until the next `show` or
    /// `dismiss` — used while a run is in progress.
    func show(_ title: String, body: String, kind: Kind = .info,
              duration: TimeInterval = 2.6) {
        model.title = title
        model.body = body
        model.kind = kind

        let panel = ensurePanel()
        position(panel)
        panel.orderFrontRegardless()

        withAnimation(.spring(response: 0.30, dampingFraction: 0.8)) {
            model.visible = true
        }

        Announcer.announce([title, body].filter { !$0.isEmpty }.joined(separator: "、"),
                           interrupts: kind == .failure)

        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard duration.isFinite else { return }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        hide()
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.18)) {
            model.visible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    // MARK: - Window

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 92),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        // Purely informational: never take a click away from the app underneath.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: HUDView(model: model))

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.visibleFrame.maxY - size.height - 12))
    }
}

struct HUDView: View {

    @ObservedObject var model: HaloHUD.Model

    init(model: HaloHUD.Model) { self.model = model }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.kind.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                if !model.body.isEmpty {
                    Text(model.body)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 400, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.82))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.75))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .padding(10)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible ? 0 : -14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
