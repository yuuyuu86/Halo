import Foundation
import FoundationModels

/// Apple's on-device language model.
///
/// Everything runs locally: no key, no account, no network, and nothing the
/// user selects ever leaves the machine. The trade-off is availability — the
/// model needs macOS 26 with Apple Intelligence switched on — so every entry
/// point reports *why* it cannot run rather than failing silently.
@available(macOS 26.0, *)
struct AppleOnDeviceProvider: AIProvider {

    let identifier = "apple"
    let displayName = String(localized: "Apple オンデバイス")

    @MainActor
    func readiness() -> AIReadiness {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            return .notReady(reason: Self.describe(reason), hint: Self.hint(for: reason))
        @unknown default:
            return .notReady(reason: String(localized: "オンデバイスモデルを利用できません。"), hint: nil)
        }
    }

    // MARK: - Generation

    func complete(prompt: String, config: AIConfig) async throws -> String {
        let session = makeSession(config)
        do {
            let response = try await session.respond(to: prompt, options: options(config))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIError.emptyResponse }
            return text
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            throw AIError.failed(Self.describe(error))
        }
    }

    func stream(prompt: String, config: AIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = makeSession(config)
                do {
                    // Each partial carries the whole answer so far, so callers
                    // can assign it straight to a label without accumulating.
                    for try await partial in session.streamResponse(to: prompt,
                                                                    options: options(config)) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: AIError.failed(Self.describe(error)))
                } catch {
                    continuation.finish(throwing: AIError.failed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession(_ config: AIConfig) -> LanguageModelSession {
        LanguageModelSession(instructions: config.systemPrompt)
    }

    private func options(_ config: AIConfig) -> GenerationOptions {
        GenerationOptions(temperature: config.temperature,
                          maximumResponseTokens: config.maxTokens)
    }

    /// Warms the model so the first summon after launch is not the slow one.
    @MainActor
    static func prewarm() {
        guard SystemLanguageModel.default.isAvailable else { return }
        LanguageModelSession().prewarm()
    }

    // MARK: - Messages

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return String(localized: "Apple Intelligence が有効になっていません。")
        case .deviceNotEligible:
            return String(localized: "この Mac はオンデバイスモデルに対応していません。")
        case .modelNotReady:
            return String(localized: "モデルの準備中です。しばらくしてからもう一度お試しください。")
        @unknown default:
            return String(localized: "オンデバイスモデルを利用できません。")
        }
    }

    private static func hint(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String? {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return String(localized: "システム設定 →「Apple Intelligence と Siri」で有効にしてください。")
        case .modelNotReady:
            return String(localized: "初回はモデルのダウンロードに時間がかかることがあります。")
        case .deviceNotEligible:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return String(localized: "入力が長すぎます。短くしてからもう一度お試しください。")
        case .guardrailViolation:
            return String(localized: "この内容には応答できませんでした。")
        case .unsupportedLanguageOrLocale:
            return String(localized: "この言語には対応していません。")
        case .assetsUnavailable:
            return String(localized: "モデルのデータを利用できません。")
        case .rateLimited:
            return String(localized: "リクエストが多すぎます。少し時間をおいてください。")
        default:
            return error.localizedDescription
        }
    }
}
