import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

// MARK: - Context

/// Maps frontmost apps to rings. This is what turns Halo from one menu into a
/// menu that already knows what you are doing.
struct ContextPane: View {

    @ObservedObject private var store = ConfigStore.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Table(of: ContextRule.self, selection: $selection) {
                TableColumn("有効") { rule in
                    Toggle("", isOn: binding(for: rule).enabled).labelsHidden()
                }
                .width(44)

                TableColumn("アプリ") { rule in
                    HStack(spacing: 6) {
                        if let icon = AppIndex.icon(forAppAt: rule.bundleIdentifier) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        }
                        Text(rule.displayName.isEmpty ? rule.bundleIdentifier : rule.displayName)
                    }
                }

                TableColumn("Bundle ID") { rule in
                    Text(rule.bundleIdentifier)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                TableColumn("リング") { rule in
                    Picker("", selection: binding(for: rule).ringID) {
                        Text("—").tag("")
                        ForEach(store.config.rings) { ring in
                            Text(ring.title).tag(ring.id)
                        }
                    }
                    .labelsHidden()
                }
            } rows: {
                ForEach(store.config.contextRules) { TableRow($0) }
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    addRuleViaPanel()
                } label: { Label("アプリを追加", systemImage: "plus") }

                Button {
                    addRuleForFrontmost()
                } label: { Label("最前面のアプリを追加", systemImage: "square.dashed.inset.filled") }

                Button(role: .destructive) {
                    if let selection {
                        store.config.contextRules.removeAll { $0.id == selection }
                    }
                } label: { Label("削除", systemImage: "minus") }
                .disabled(selection == nil)

                Spacer()
            }
            .padding(10)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Context Ring").font(.title3.weight(.semibold))
            Text("呼び出した瞬間に最前面だったアプリに応じて、開くリングを切り替えます。一致するルールがなければルートリングが開きます。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private func binding(for rule: ContextRule) -> Binding<ContextRule> {
        guard let index = store.config.contextRules.firstIndex(where: { $0.id == rule.id }) else {
            return .constant(rule)
        }
        return $store.config.contextRules[index]
    }

    private func addRuleViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            append(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func addRuleForFrontmost() {
        // The prefs window is frontmost right now, so look one app deeper.
        let candidate = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .max { ($0.isActive ? 1 : 0) < ($1.isActive ? 1 : 0) }
        guard let candidate, let id = candidate.bundleIdentifier else { return }
        append(bundleID: id, name: candidate.localizedName ?? id)
    }

    private func append(bundleID: String, name: String) {
        guard !store.config.contextRules.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        let ring = store.addRing(title: name)
        store.config.contextRules.append(
            ContextRule(bundleIdentifier: bundleID, displayName: name, ringID: ring.id))
    }
}

// MARK: - Hot key

struct HotKeyPane: View {

    @ObservedObject private var store = ConfigStore.shared
    @State private var triggersActive = false

    var body: some View {
        Form {
            Section("召喚ショートカット") {
                Toggle("グローバルショートカットを有効にする", isOn: $store.config.hotKey.enabled)
                    .onChange(of: store.config.hotKey.enabled) { _, _ in reregister() }

                HStack {
                    Text("キー")
                    Spacer()
                    HotKeyRecorder(config: $store.config.hotKey, onChange: reregister)
                }

                Text("押している間リングが出て、離すと選択中の項目を実行します。素早く押して離すとリングが開いたままになり、クリックで実行できます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("操作") {
                LabeledContent("実行", value: "キーを離す / クリック / Return / 1〜9")
                LabeledContent("サブリングへ", value: "外側へ押し出す / クリック")
                LabeledContent("親リングへ戻る", value: "中心へ戻して静止 / Tab / 右クリック")
                LabeledContent("キャンセル", value: "Esc / 中心でクリック")
                LabeledContent("選択を回す", value: "← → / スクロール")
            }

            Section("ほかの召喚方法") {
                Toggle("修飾キーのダブルタップで召喚", isOn: $store.config.triggers.doubleTapEnabled)
                    .onChange(of: store.config.triggers.doubleTapEnabled) { _, _ in applyTriggers() }
                Picker("キー", selection: $store.config.triggers.doubleTapModifier) {
                    ForEach(ModifierKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .disabled(!store.config.triggers.doubleTapEnabled)
                .onChange(of: store.config.triggers.doubleTapModifier) { _, _ in applyTriggers() }

                HStack {
                    Text("ダブルタップの間隔")
                    Spacer()
                    Text(String(format: "%.2f 秒", store.config.triggers.doubleTapWindow))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $store.config.triggers.doubleTapWindow, in: 0.15...0.70)
                    .disabled(!store.config.triggers.doubleTapEnabled)

                Divider()

                Toggle("マウス／トラックパッドのボタンで召喚",
                       isOn: $store.config.triggers.mouseButtonEnabled)
                    .onChange(of: store.config.triggers.mouseButtonEnabled) { _, _ in applyTriggers() }
                Picker("ボタン", selection: $store.config.triggers.mouseButton) {
                    Text("中クリック").tag(2)
                    Text("ボタン 4").tag(3)
                    Text("ボタン 5").tag(4)
                }
                .disabled(!store.config.triggers.mouseButtonEnabled)
                .onChange(of: store.config.triggers.mouseButton) { _, _ in applyTriggers() }

                if store.config.triggers.isAnyEnabled {
                    LabeledContent("状態") {
                        Text(triggersActive ? "動作中" : "アクセシビリティ権限が必要です")
                            .foregroundStyle(triggersActive ? .green : .orange)
                    }
                }
                Text("これらは全体のイベントを読むため、アクセシビリティ権限が必要です。Halo はイベントを横取りしないので、中クリックなどは元の動作もそのまま働きます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("起動") {
                Toggle("ログイン時に起動", isOn: $store.config.launchAtLogin)
                    .onChange(of: store.config.launchAtLogin) { _, value in
                        LoginItem.sync(enabled: value)
                    }
            }

            Section("クリップボード") {
                Toggle("履歴を記録する", isOn: $store.config.clipboardHistoryEnabled)
                Stepper("履歴の保持数: \(store.config.clipboardHistoryLimit)",
                        value: $store.config.clipboardHistoryLimit, in: 5...50)
                Text("履歴はメモリ上にのみ保持され、ディスクには書き出されません。パスワードマネージャなどが機密指定したコピーは記録しません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            triggersActive = store.config.triggers.isAnyEnabled && AXIsProcessTrusted()
        }
    }

    private func reregister() {
        (NSApp.delegate as? AppDelegate)?.refreshHotKeys()
    }

    private func applyTriggers() {
        triggersActive = TriggerMonitor.shared.apply(store.config.triggers,
                                                     promptForPermission: true)
    }
}

/// Click, then press a combination. Captures the next key event via a local monitor.
struct HotKeyRecorder: View {

    @Binding var config: HotKeyConfig
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "キーを押してください…" : KeyCodeNames.describe(config))
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 150)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { rawEvent in
            let box = MainThreadBox(rawEvent)
            return MainActor.assumeIsolated { () -> MainThreadBox<NSEvent?> in
                let event = box.value
                let swallow = MainThreadBox<NSEvent?>(nil)
                guard event.type == .keyDown else { return swallow }
                if event.keyCode == 53 {          // Escape cancels
                    stop()
                    return swallow
                }
                let modifiers = KeyCodeNames.carbonModifiers(from: event.modifierFlags)
                guard modifiers != 0 else { NSSound.beep(); return swallow }
                config.keyCode = UInt32(event.keyCode)
                config.modifiers = modifiers
                config.enabled = true
                stop()
                onChange()
                return swallow
            }.value
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Appearance

/// Everything about how the ring looks and feels, next to a live preview.
struct AppearancePane: View {

    @ObservedObject private var store = ConfigStore.shared

    private var appearance: Binding<Appearance> { $store.config.appearance }

    var body: some View {
        HSplitView {
            Form {
                Section("寸法") {
                    slider("リングの半径", appearance.ringRadius, 90...360, unit: "pt")
                    slider("ノードの大きさ", appearance.nodeSize, 32...120, unit: "pt")
                    slider("リングの太さ", appearance.ringThickness, 0.5...6, unit: "pt", decimals: 1)
                    slider("項目名の文字サイズ", appearance.labelSize, 8...20, unit: "pt")
                    slider("中心のデッドゾーン", appearance.deadZone, 16...110, unit: "pt")
                    slider("潜る距離の余白", appearance.diveMargin, 20...160, unit: "pt")
                }

                Section("配置") {
                    slider("開始角度", appearance.startAngleDegrees, 0...360, unit: "°")
                    slider("広がり", appearance.sweepDegrees, 60...360, unit: "°")
                    Picker("並ぶ向き", selection: appearance.clockwise) {
                        Text("時計回り").tag(true)
                        Text("反時計回り").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text("広がりを 360° 未満にすると、扇形に並びます。画面の端で呼び出すときに便利です。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("形") {
                    Picker("ノードの形", selection: appearance.nodeShape) {
                        ForEach(NodeShape.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("中心の表示", selection: appearance.coreStyle) {
                        ForEach(CoreStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("項目名の位置", selection: appearance.labelPlacement) {
                        ForEach(LabelPlacement.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("アイコン", selection: appearance.iconStyle) {
                        ForEach(IconStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("番号バッジ（1〜9）を表示", isOn: appearance.showKeyHints)
                }

                Section("光と色") {
                    ColorPicker("アクセント", selection: Binding(
                        get: { Color(hex: store.config.appearance.accentHex) ?? .orange },
                        set: { store.config.appearance.accentHex = $0.hexString }))
                    ColorPicker("セカンダリ", selection: Binding(
                        get: { Color(hex: store.config.appearance.secondaryHex) ?? .purple },
                        set: { store.config.appearance.secondaryHex = $0.hexString }))
                    slider("発光の強さ", appearance.glowIntensity, 0...2.5, unit: "×", decimals: 2)
                    Toggle("選択アークを表示", isOn: appearance.showArc)
                    Toggle("コメットを表示", isOn: appearance.showComet)
                    Toggle("中心からの線を表示", isOn: appearance.showFilament)
                }

                Section("背景") {
                    Picker("スタイル", selection: appearance.backdrop) {
                        ForEach(BackdropStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if store.config.appearance.backdrop != .none {
                        slider("強さ", appearance.backdropStrength, 0...0.9, unit: "", decimals: 2)
                    }
                }

                Section("挙動") {
                    slider("押しっぱなし判定", appearance.stickyThreshold, 0.05...0.80, unit: "秒", decimals: 2)
                    slider("戻るまでの静止時間", appearance.ascendDwell, 0.10...1.20, unit: "秒", decimals: 2)
                    slider("アニメーション速度", appearance.animationSpeed, 0.4...2.5, unit: "×", decimals: 2)
                    Toggle("外へ押し出してサブリングへ潜る", isOn: appearance.autoDive)
                    Toggle("中心へ引き戻して親リングへ戻る", isOn: appearance.pullToAscend)
                    Toggle("スクロールで選択を回す", isOn: appearance.scrollToRotate)
                    Toggle("数字キー（1〜9）で即実行", isOn: appearance.numberKeyShortcuts)
                    Toggle("選択時に触覚フィードバック", isOn: appearance.haptics)
                }

                Section {
                    HStack {
                        Button("既定値に戻す") { store.config.appearance = .default }
                        Spacer()
                        Menu("プリセット") {
                            Button("コンパクト") { apply(.compact) }
                            Button("大きく見やすく") { apply(.large) }
                            Button("最小限") { apply(.minimal) }
                            Button("扇形（画面端向け）") { apply(.fan) }
                        }
                        .fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 360)

            VStack(spacing: 8) {
                Text("プレビュー").font(.caption).foregroundStyle(.secondary)
                RingPreview(ring: previewRing)
                    .frame(minWidth: 320, minHeight: 340)
                    .padding()
            }
        }
    }

    /// Prefers the root ring, but falls back to any ring so the preview is never
    /// blank on a freshly emptied configuration.
    private var previewRing: Ring {
        store.config.rootRing ?? store.config.rings.first ?? Ring(title: "Halo")
    }

    // MARK: Presets

    private enum Preset { case compact, large, minimal, fan }

    private func apply(_ preset: Preset) {
        var a = store.config.appearance
        switch preset {
        case .compact:
            a.ringRadius = 118; a.nodeSize = 42; a.deadZone = 34
            a.labelSize = 9.5; a.labelPlacement = .selectedOnly
        case .large:
            a.ringRadius = 210; a.nodeSize = 78; a.deadZone = 56
            a.labelSize = 13; a.labelPlacement = .outside
        case .minimal:
            a.showArc = true; a.showComet = false; a.showFilament = false
            a.coreStyle = .minimal; a.labelPlacement = .selectedOnly
            a.backdrop = .none; a.glowIntensity = 0.6
        case .fan:
            a.sweepDegrees = 200; a.startAngleDegrees = 170; a.clockwise = true
        }
        store.config.appearance = a
    }

    // MARK: Slider helper

    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, unit: String,
                        decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.\(decimals)f%@", value.wrappedValue,
                            unit.isEmpty ? "" : " " + unit))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - AI

/// AI settings.
///
/// One provider, no key, no endpoint — the screen's real job is to say plainly
/// whether the model can run on this Mac, and what to do when it cannot.
struct AIPane: View {

    @ObservedObject private var store = ConfigStore.shared
    @State private var readiness: AIReadiness = .ready
    @State private var testInput = "Translate to Japanese: The ring appears around the cursor."
    @State private var testOutput: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle("AI アクションを有効にする", isOn: $store.config.ai.enabled)
                statusRow
            } header: {
                Text("Halo AI")
            } footer: {
                Text("Apple のオンデバイスモデルを使います。API キーもアカウントも不要で、入力したテキストがこの Mac の外に出ることはありません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("結果の適用") {
                Toggle("適用する前に結果を確認する", isOn: $store.config.ai.reviewBeforeApplying)
                Text("生成結果をパネルで確認・編集してから、選択範囲を置き換えます。オフにすると確認なしでその場に反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.config.ai.reviewBeforeApplying {
                    Label("確認なしで選択範囲が書き換わります。取り消しは各アプリの取り消し操作に依存します。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!store.config.ai.enabled)

            Section("応答の調整") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("システムプロンプト").font(.callout)
                    TextEditor(text: $store.config.ai.systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 74)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    Text("すべての AI 項目に共通で渡されます。既定では「説明を書かず結果だけ返す」よう指示しています。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("ばらつき")
                        Spacer()
                        Text(String(format: "%.2f", store.config.ai.temperature))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $store.config.ai.temperature, in: 0...1)
                    Text("低いほど毎回同じ結果に、高いほど表現が揺れます。翻訳や整形は低め推奨。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Stepper("最大トークン: \(store.config.ai.maxTokens)",
                        value: $store.config.ai.maxTokens, in: 128...4096, step: 128)
            }
            .disabled(!store.config.ai.enabled)

            Section("動作テスト") {
                TextField("入力", text: $testInput, axis: .vertical)
                    .lineLimit(1...4)
                HStack {
                    Button(testing ? "実行中…" : "試す") { runTest() }
                        .disabled(testing || !readiness.isReady)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let testOutput {
                    Text(testOutput)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.10)))
                }
            }

            Section("プライバシー") {
                Label("入力はこの Mac の中だけで処理されます", systemImage: "lock.laptopcomputer")
                Label("ネットワークには接続しません", systemImage: "wifi.slash")
                Label("履歴は保存されません", systemImage: "clock.badge.xmark")
            }
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: store.config.ai.provider) { _, _ in refresh() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch readiness {
        case .ready:
            Label("この Mac で利用できます", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notReady(let reason, let hint):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("システム設定を開く") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("再確認") { refresh() }
                }
            }
        }
    }

    private func refresh() {
        readiness = AIService.shared.readiness(for: store.config.ai)
    }

    private func runTest() {
        guard let provider = AIService.shared.provider(for: store.config.ai) else { return }
        testing = true
        testOutput = nil
        let config = store.config.ai
        let prompt = AIService.shared.fill(prompt: testInput, input: "")

        Task {
            do {
                testOutput = try await provider.complete(prompt: prompt, config: config)
            } catch {
                testOutput = "⚠️ " + error.localizedDescription
            }
            testing = false
            refresh()
        }
    }
}

// MARK: - About

struct AboutPane: View {

    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            HaloMark()
                .frame(width: 96, height: 96)

            VStack(spacing: 5) {
                Text("Halo").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("必要な操作を、必要な瞬間に、カーソルの周りへ召喚する。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("バージョン \(Bundle.main.shortVersion)")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            VStack(spacing: 6) {
                Text("設定の書き出し・読み込み・リセットは「バックアップ / リセット」にあります。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("設定ファイルを表示") { store.revealConfigInFinder() }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// The Halo mark: a ring, one lit node, and its filament.
struct HaloMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = size * 0.36
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.22), lineWidth: size * 0.02)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                Circle()
                    .trim(from: 0.0, to: 0.18)
                    .stroke(LinearGradient(colors: [Color(hex: "#FFC46B")!.opacity(0),
                                                    Color(hex: "#FFC46B")!],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(.degrees(-90))
                    .position(center)

                Circle()
                    .fill(Color(hex: "#FFC46B")!)
                    .frame(width: size * 0.10, height: size * 0.10)
                    .shadow(color: Color(hex: "#FFC46B")!.opacity(0.8), radius: size * 0.08)
                    .position(x: center.x, y: center.y - radius)

                Circle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .position(center)
            }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }
}
