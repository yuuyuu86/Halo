import Foundation

/// Seam for AI features.
///
/// Halo ships with one provider: Apple's on-device model. Nothing leaves the
/// machine, there is no key to manage, and there is no network call to fail —
/// which is why it is the only one wired up by default. The protocol stays
/// deliberately small so a cloud or local-server provider can be dropped in
/// later without touching ring items, the executor, or the settings UI.
protocol AIProvider: Sendable {

    var identifier: String { get }
    var displayName: String { get }

    /// Whether this provider can run right now, and why not when it cannot.
    @MainActor func readiness() -> AIReadiness

    /// One-shot completion.
    func complete(prompt: String, config: AIConfig) async throws -> String

    /// Incremental completion. Each element is the full text so far, not a
    /// delta, so callers can assign it straight to a label.
    func stream(prompt: String, config: AIConfig) -> AsyncThrowingStream<String, Error>
}

extension AIProvider {
    /// Providers that cannot stream fall back to waiting for the whole answer.
    func stream(prompt: String, config: AIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await complete(prompt: prompt, config: config))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Whether AI can run, in a form the settings screen can show directly.
enum AIReadiness: Equatable {
    case ready
    case notReady(reason: String, hint: String?)

    var isReady: Bool { self == .ready }
}

enum AIError: LocalizedError {
    case disabled
    case noProvider(String)
    case notReady(String)
    case emptyInput
    case emptyResponse
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return String(localized: "AI 機能が無効です。設定 > AI から有効にしてください。")
        case .noProvider(let name):
            return "プロバイダ '\(name)' は登録されていません。"
        case .notReady(let reason):
            return reason
        case .emptyInput:
            return String(localized: "入力が空です。テキストを選択するかコピーしてから実行してください。")
        case .emptyResponse:
            return String(localized: "モデルから応答がありませんでした。")
        case .cancelled:
            return String(localized: "キャンセルしました。")
        case .failed(let detail):
            return detail
        }
    }
}

@MainActor
final class AIService {

    static let shared = AIService()

    private var providers: [String: AIProvider] = [:]

    private init() {
        if #available(macOS 26.0, *) {
            register(AppleOnDeviceProvider())
        }
    }

    func register(_ provider: AIProvider) {
        providers[provider.identifier] = provider
    }

    var registeredProviders: [AIProvider] {
        providers.values.sorted { $0.identifier < $1.identifier }
    }

    func provider(for config: AIConfig) -> AIProvider? {
        providers[config.provider] ?? providers.values.first
    }

    /// Whether the configured provider can run, without considering the
    /// enabled flag — the settings screen wants to explain the situation even
    /// while AI is switched off.
    func readiness(for config: AIConfig) -> AIReadiness {
        guard let provider = provider(for: config) else {
            if #unavailable(macOS 26.0) {
                return .notReady(reason: String(localized: "オンデバイスモデルには macOS 26 以降が必要です。"),
                                 hint: nil)
            }
            return .notReady(reason: String(localized: "利用できるプロバイダがありません。"), hint: nil)
        }
        return provider.readiness()
    }

    /// Fills a prompt template. `{input}` is replaced with the input text; a
    /// template without the placeholder gets the input appended.
    nonisolated func fill(prompt: String, input: String) -> String {
        let template = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("{input}") else {
            return input.isEmpty ? template : template + "\n\n" + input
        }
        return template.replacingOccurrences(of: "{input}", with: input)
    }
}
