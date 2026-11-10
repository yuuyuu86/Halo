import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Editor for one ring item. The form reshapes itself around the action kind so
/// the user only ever sees the fields that matter.
struct ItemEditor: View {

    @Binding var item: RingItem
    @ObservedObject private var store = ConfigStore.shared
    @State private var shortcutNames: [String] = []
    @State private var loadingShortcuts = false
    @State private var showingSymbolPicker = false

    init(item: Binding<RingItem>) { self._item = item }

    var body: some View {
        Form {
            Section("項目") {
                TextField("タイトル", text: $item.title)

                HStack(spacing: 8) {
                    TextField("SF Symbol 名", text: $item.glyph, prompt: Text("例: bolt.fill"))
                    if !item.glyph.isEmpty && !SymbolCatalogue.exists(item.glyph) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("このシンボルはこの macOS には存在しません")
                    }
                    Button("選ぶ…") { showingSymbolPicker = true }
                    ItemIcon(item: item)
                }

                HStack {
                    Toggle("色を指定", isOn: Binding(
                        get: { item.tint != nil },
                        set: { item.tint = $0 ? (item.tint ?? "#FFC46B") : nil }))
                    if item.tint != nil {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: item.tint ?? "#FFC46B") ?? .orange },
                            set: { item.tint = $0.hexString }))
                        .labelsHidden()
                    }
                }

                Toggle("リングに表示", isOn: $item.enabled)
            }

            Section("アクション") {
                Picker("種類", selection: $item.action.kind) {
                    ForEach(ActionKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: item.action.kind) { _, _ in
                    item.action.value = ""
                    item.action.argument = ""
                }

                actionFields
            }

            Section {
                Toggle("実行前に確認する", isOn: $item.action.confirm)
                if item.action.kind == .system,
                   SystemOp(rawValue: item.action.value)?.isDestructive == true,
                   !item.action.confirm {
                    Label("取り消せない操作です。確認を有効にしておくことをおすすめします。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if supportsSink {
                Section("結果の扱い") {
                    Picker("出力先", selection: $item.action.sink) {
                        ForEach(ResultSink.allCases, id: \.self) { sink in
                            Text(sink.displayName).tag(sink)
                        }
                    }
                    if item.action.sink == .paste {
                        Text("ペーストにはアクセシビリティ権限が必要です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if supportsPlaceholders {
                Section("使えるプレースホルダ") {
                    Text("{clipboard} · {selection} · {app} · {bundleID} · {date} · {home}")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingSymbolPicker) {
            SymbolPicker(glyph: $item.glyph)
        }
        .task(id: item.action.kind) {
            if item.action.kind == .runShortcut { await loadShortcuts() }
        }
    }

    // MARK: - Per-kind fields

    @ViewBuilder
    private var actionFields: some View {
        switch item.action.kind {
        case .none:
            Text("この項目は何も実行しません。").foregroundStyle(.secondary)

        case .launchApp:
            HStack {
                TextField("アプリのパス / Bundle ID", text: $item.action.value)
                Button("選択…") { chooseApp() }
            }
            Picker("インストール済みから選ぶ", selection: $item.action.value) {
                Text("—").tag("")
                ForEach(AppIndex.allApplications(), id: \.path) { app in
                    Text(app.name).tag(app.path)
                }
            }

        case .openURL:
            TextField("URL", text: $item.action.value,
                      prompt: Text("https://example.com/search?q={clipboard}"))
                .textFieldStyle(.roundedBorder)

        case .runShortcut:
            HStack {
                TextField("ショートカット名", text: $item.action.value)
                if loadingShortcuts { ProgressView().controlSize(.small) }
            }
            if !shortcutNames.isEmpty {
                Picker("インストール済み", selection: $item.action.value) {
                    Text("—").tag("")
                    ForEach(shortcutNames, id: \.self) { Text($0).tag($0) }
                }
            }
            Toggle("クリップボードを入力として渡す", isOn: Binding(
                get: { item.action.argument == "clipboard" },
                set: { item.action.argument = $0 ? "clipboard" : "" }))

        case .runScript:
            VStack(alignment: .leading, spacing: 6) {
                Text("/bin/zsh -lc で実行されます").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $item.action.value)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }
            Toggle("クリップボードを標準入力に渡す", isOn: Binding(
                get: { item.action.argument == "clipboard" },
                set: { item.action.argument = $0 ? "clipboard" : "" }))

        case .clipboard:
            Picker("操作", selection: $item.action.value) {
                ForEach(ClipboardOp.allCases, id: \.self) { op in
                    Text(op.displayName).tag(op.rawValue)
                }
            }
            if item.action.value == ClipboardOp.copy.rawValue {
                TextField("コピーするテキスト", text: $item.action.argument)
            }

        case .system:
            Picker("操作", selection: $item.action.value) {
                ForEach(SystemOp.allCases, id: \.self) { op in
                    Text(op.displayName).tag(op.rawValue)
                }
            }
            .onChange(of: item.action.value) { _, value in
                if SystemOp(rawValue: value)?.isDestructive == true {
                    item.action.confirm = true
                }
            }

        case .subring:
            Picker("開くリング", selection: $item.action.value) {
                Text("—").tag("")
                ForEach(store.config.rings) { ring in
                    Text(ring.title).tag(ring.id)
                }
                Divider()
                ForEach(DynamicRing.allCases, id: \.rawValue) { dynamic in
                    Text(dynamic.title + "（自動生成）").tag(dynamic.rawValue)
                }
            }

        case .ai:
            VStack(alignment: .leading, spacing: 6) {
                Text("プロンプト（{input} が入力に置き換わります）")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $item.action.value)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            }
            Picker("入力", selection: Binding(
                get: { AIInputSource(rawValue: item.action.argument) ?? .clipboard },
                set: { item.action.argument = $0.rawValue })) {
                    ForEach(AIInputSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
            if !store.config.ai.enabled {
                Text("AI は現在無効です。「AI」タブで有効にしてください。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var supportsSink: Bool {
        switch item.action.kind {
        case .runScript, .runShortcut, .ai: return true
        default: return false
        }
    }

    private var supportsPlaceholders: Bool {
        switch item.action.kind {
        case .openURL, .runScript, .ai, .clipboard: return true
        default: return false
        }
    }

    // MARK: - Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        item.action.value = url.path
        if item.title.isEmpty || item.title == "新しい項目" {
            item.title = url.deletingPathExtension().lastPathComponent
        }
    }

    private func loadShortcuts() async {
        guard shortcutNames.isEmpty else { return }
        loadingShortcuts = true
        let names = await Task.detached { ActionExecutor.installedShortcuts() }.value
        shortcutNames = names
        loadingShortcuts = false
    }
}
