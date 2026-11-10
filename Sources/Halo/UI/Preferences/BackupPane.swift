import AppKit
import SwiftUI

/// Export, import and reset in one place, so every destructive control lives
/// where the user goes looking for it rather than hidden behind an About page.
struct BackupPane: View {

    @ObservedObject private var store = ConfigStore.shared
    @State private var lastAction: String?

    var body: some View {
        Form {
            Section("書き出し") {
                LabeledContent("すべての設定") {
                    Button("書き出す…") {
                        ConfigTransfer.export(store.config, scope: .everything)
                        note(String(localized: "設定を書き出しました"))
                    }
                }
                LabeledContent("リングのみ") {
                    Button("書き出す…") {
                        ConfigTransfer.export(store.config, scope: .ringsOnly)
                        note(String(localized: "リングを書き出しました"))
                    }
                }
                Text("「リングのみ」は専用ショートカットや AI 設定を含みません。他の環境と共有するときはこちらを使ってください。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("読み込み") {
                LabeledContent("設定ファイル") {
                    Button("読み込む…") { performImport() }
                }
                Text("「すべて置き換える」と「リングを追加する」を選べます。追加のときは ID を振り直すので、既存のリングと衝突しません。参照先が見つからないサブリングは自動的に外されます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("設定ファイル") {
                LabeledContent(ConfigStore.fileURL.path) {
                    Button("Finder で表示") { store.revealConfigInFinder() }
                }
                .labeledContentStyle(.automatic)
            }

            Section("リセット") {
                ForEach(ConfigTransfer.ResetScope.allCases) { scope in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(scope.title)
                            Spacer()
                            Button(scope.isDestructive ? "初期化…" : "初期化") {
                                performReset(scope)
                            }
                            .tint(scope.isDestructive ? .red : nil)
                        }
                        Text(scope.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 1)
                }
            }

            if let lastAction {
                Section {
                    Label(lastAction, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func performImport() {
        guard let imported = ConfigTransfer.importConfig(into: store.config) else { return }
        store.config = imported
        store.save()
        reapply()
        note(String(localized: "読み込みました（リング \(imported.rings.count) 個）"))
    }

    private func performReset(_ scope: ConfigTransfer.ResetScope) {
        var config = store.config
        guard ConfigTransfer.reset(scope, config: &config) else { return }
        store.config = config
        store.save()
        reapply()
        note(String(localized: "初期化しました"))
    }

    /// Anything that lives outside the config file has to be re-derived after a
    /// wholesale change: hot keys, the alternative triggers, the login item.
    private func reapply() {
        (NSApp.delegate as? AppDelegate)?.refreshHotKeys()
        TriggerMonitor.shared.apply(store.config.triggers)
        LoginItem.sync(enabled: store.config.launchAtLogin)
    }

    private func note(_ message: String) {
        lastAction = message
        let expected = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if lastAction == expected { lastAction = nil }
        }
    }
}
