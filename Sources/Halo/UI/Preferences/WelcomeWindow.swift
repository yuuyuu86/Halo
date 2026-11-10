import AppKit
import SwiftUI

/// First-run guide.
///
/// Dropping a new user straight into the preferences window told them nothing
/// about the one gesture the whole app is built on. This walks through it, shows
/// the gesture rather than describing it, and lets them try the real ring before
/// deciding anything.
@MainActor
final class WelcomeWindowController: NSWindowController {

    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = String(localized: "Halo へようこそ")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        // The page is painted on a dark plate, so the chrome and the system
        // colours inside it have to be dark too — regardless of the user's
        // system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            self?.dismiss()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let window else { return }
        // Rise into place rather than snapping on, so the first thing Halo does
        // matches how it behaves from then on.
        if !window.isVisible {
            window.alphaValue = 0
            let final = window.frame
            window.setFrame(final.insetBy(dx: 14, dy: 10), display: false)
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                window.animator().setFrame(final, display: true)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Fades out instead of vanishing, then hands the Dock icon back.
    func dismiss() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            window.orderOut(nil)
            window.alphaValue = 1
            self?.finishActivationPolicy()
        }
    }

    private func finishActivationPolicy() {
        // Preferences may have been opened from the last page; only drop back to
        // an agent when no ordinary window is left.
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain
        }
        if !hasVisibleWindow { NSApp.setActivationPolicy(.accessory) }
    }
}

struct WelcomeView: View {

    let onFinish: () -> Void
    /// Offscreen rendering starts on a chosen page and skips the reveals.
    var initialStep: Int = 0

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.initialStep = initialStep
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    @ObservedObject private var store = ConfigStore.shared
    @State private var step: Int
    @State private var goingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stepCount = 3
    private var accent: Color { Color(hex: store.config.appearance.accentHex) ?? .orange }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 44)
                    .padding(.top, 18)
                    // Re-running the page's reveals on every change is the point:
                    // each step assembles itself as you arrive.
                    .id(step)
                    .transition(pageTransition)

                footer
            }
        }
        .frame(minWidth: 600, minHeight: 540)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    /// A slow wash of the accent behind everything, so the window feels lit by
    /// the same light as the ring.
    private var background: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.10)
            RadialGradient(colors: [accent.opacity(0.16), .clear],
                           center: .init(x: 0.5, y: 0.32),
                           startRadius: 10, endRadius: 380)
            RadialGradient(colors: [(Color(hex: store.config.appearance.secondaryHex) ?? .purple)
                                        .opacity(0.10), .clear],
                           center: .init(x: 0.15, y: 0.88),
                           startRadius: 10, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let insertionEdge: Edge = goingForward ? .trailing : .leading
        let removalEdge: Edge = goingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity))
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:  intro
        case 1:  gesture
        default: setup
        }
    }

    private var intro: some View {
        VStack(spacing: 22) {
            Spacer()
            Reveal(delay: 0) {
                AnimatedHaloMark(
                    accent: accent,
                    secondary: Color(hex: store.config.appearance.secondaryHex) ?? .purple)
                    .frame(width: 120, height: 120)
            }
            Reveal(delay: 0.20) {
                VStack(spacing: 10) {
                    Text("Halo")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text("必要な操作を、必要な瞬間に、\nカーソルの周りへ召喚する。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
            }
            Reveal(delay: 0.42) {
                Text("メニューバーに常駐します。Dock にはアイコンが出ません。")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var gesture: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 8)

            Reveal(delay: 0) {
                Text("ひとつのジェスチャで完結します")
                    .font(.title2.weight(.semibold))
            }

            Reveal(delay: 0.12) {
                GestureDemoView(accent: accent)
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 11) {
                Reveal(delay: 0.26) {
                    row("keyboard",
                        String(localized: "\(KeyCodeNames.describe(store.config.hotKey)) を押したままにする"),
                        String(localized: "カーソルの位置にリングが現れます"))
                }
                Reveal(delay: 0.36) {
                    row("cursorarrow.motionlines",
                        String(localized: "使いたい項目の方向へマウスを弾く"),
                        String(localized: "距離は要りません。向きだけで決まります"))
                }
                Reveal(delay: 0.46) {
                    row("hand.tap",
                        String(localized: "キーを離す"),
                        String(localized: "選択中の項目が実行されます"))
                }
            }

            Reveal(delay: 0.58) {
                Button {
                    // Let the window yield focus before the ring appears.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        RingController.shared.summon()
                    }
                } label: {
                    Label("いま試してみる", systemImage: "play.circle.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Spacer(minLength: 8)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()

            Reveal(delay: 0) {
                Text("はじめの設定").font(.title2.weight(.semibold))
            }

            Reveal(delay: 0.12) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("ログイン時に Halo を起動する", isOn: $store.config.launchAtLogin)
                        .onChange(of: store.config.launchAtLogin) { _, value in
                            LoginItem.sync(enabled: value)
                        }

                    HStack {
                        Text("召喚ショートカット")
                        Spacer()
                        HotKeyRecorder(config: $store.config.hotKey) {
                            (NSApp.delegate as? AppDelegate)?.refreshHotKeys()
                        }
                    }
                }
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.75))
                }
            }

            Reveal(delay: 0.26) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("いま必要な権限はありません", systemImage: "lock.open")
                        .font(.callout.weight(.medium))
                    Text("アプリ起動・URL・スクリプト・スクリーンショットは権限なしで動きます。ペーストや、修飾キーのダブルタップでの召喚を使うときだけ、アクセシビリティ権限を求めます。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Reveal(delay: 0.38) {
                Text("リングの中身は、メニューバーの Halo アイコン →「設定」からいつでも編集できます。")
                    .font(.callout).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 30, height: 30)
                Image(systemName: symbol).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? accent : Color.white.opacity(0.22))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.75), value: step)

            Spacer()

            if step > 0 {
                Button("戻る") { go(to: step - 1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            if step < stepCount - 1 {
                Button("次へ") { go(to: step + 1) }
                    .keyboardShortcut(.defaultAction)
                    .tint(accent)
            } else {
                Button("設定を開く") {
                    onFinish()
                    PreferencesWindowController.shared.show()
                }
                .buttonStyle(.bordered)

                Button("はじめる") { onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .tint(accent)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(18)
        .background(.ultraThinMaterial)
    }

    private func go(to newStep: Int) {
        goingForward = newStep > step
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15)
                      : .spring(response: 0.42, dampingFraction: 0.86)) {
            step = newStep
        }
    }
}
