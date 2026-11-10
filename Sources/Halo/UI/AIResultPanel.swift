import AppKit
import SwiftUI

/// Review step between the model and the user's document.
///
/// Pasting a generated answer straight over someone's selection is a
/// destructive edit made on the model's say-so. This shows the result first,
/// lets it be edited, and only replaces the selection when the user says to.
/// The text streams in, so the wait is visible rather than blank.
@MainActor
final class AIResultModel: ObservableObject {

    enum State: Equatable {
        case generating
        case finished
        case failed(String)
    }

    @Published var title = "Halo AI"
    @Published var input = ""
    @Published var text = ""
    @Published var state: State = .generating
    /// Whether replacing the selection is the expected outcome for this item.
    @Published var replaces = false

    var onReplace: (String) -> Void = { _ in }
    var onCopy: (String) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
    var onStop: () -> Void = {}
    var onClose: () -> Void = {}
}

@MainActor
final class AIResultPanelController {

    static let shared = AIResultPanelController()

    let model = AIResultModel()
    private var panel: NSPanel?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func present() {
        let panel = ensurePanel()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        panel.title = "Halo AI"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: AIResultView(model: model))
        self.panel = panel
        return panel
    }

    /// Near the cursor, but always fully on screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }

        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}

/// Lets one button pick its style at runtime.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {

    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { configuration in
            AnyView(Button(configuration).buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

struct AIResultView: View {

    @ObservedObject var model: AIResultModel
    @ObservedObject private var store = ConfigStore.shared

    init(model: AIResultModel) { self.model = model }

    private var accent: Color { Color(hex: store.config.appearance.accentHex) ?? .orange }

    private var isGenerating: Bool { model.state == .generating }

    private var canApply: Bool {
        model.state == .finished && !model.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: model.state)
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 340)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(accent)
            Text(model.title).font(.headline)
            Spacer()
            if isGenerating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func body(for state: AIResultModel.State) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.input.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("元のテキスト").font(.caption).foregroundStyle(.tertiary)
                    Text(model.input)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("結果").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        if !isGenerating {
                            Text("編集できます").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    TextEditor(text: $model.text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.75))
                        .disabled(isGenerating)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isGenerating {
                Button("中止") { model.onStop() }
            } else {
                Button {
                    model.onRegenerate()
                } label: {
                    Label("もう一度", systemImage: "arrow.clockwise")
                }
                .disabled(model.state == .generating)
            }

            Spacer()

            Button("閉じる") { model.onClose() }
                .keyboardShortcut(.cancelAction)

            // Whichever action the item implies gets Return; the other stays
            // available but secondary.
            Button("コピー") { model.onCopy(model.text) }
                .disabled(!canApply)
                .buttonStyle(model.replaces ? AnyPrimitiveButtonStyle(.bordered)
                                            : AnyPrimitiveButtonStyle(.borderedProminent))
                .tint(model.replaces ? nil : accent)
                .keyboardShortcut(model.replaces ? KeyEquivalent("c") : .return,
                                  modifiers: model.replaces ? [.command, .shift] : [])

            if model.replaces {
                Button("選択範囲を置き換える") { model.onReplace(model.text) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!canApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(14)
        .background(.bar)
    }
}
