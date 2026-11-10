import AppKit

/// One AI invocation, from ring item to delivered result.
///
/// Kept apart from `ActionExecutor` because it is the only action with a
/// lifetime: it streams, it can be cancelled, and it has to say something while
/// the user waits. Only one run happens at a time — starting another replaces
/// the first, which is what someone hammering the ring expects.
///
/// By default the answer goes to a review panel rather than straight into the
/// user's document. Replacing a selection is a destructive edit, and a model is
/// not a good enough reason to make one unseen.
@MainActor
final class AIRun {

    static let shared = AIRun()

    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    /// Everything needed to run the same request again from the review panel.
    private struct Request {
        var prompt: String
        var provider: AIProvider
        var config: AIConfig
        var sink: ResultSink
        var title: String
        var input: String
    }

    private var lastRequest: Request?

    private init() {}

    // MARK: - Entry point

    func start(action: HaloAction, item: RingItem?) {
        let config = ConfigStore.shared.config.ai
        guard config.enabled else {
            HaloNotifier.failure("Halo AI", body: AIError.disabled.localizedDescription)
            return
        }

        let service = AIService.shared
        guard let provider = service.provider(for: config) else {
            HaloNotifier.failure("Halo AI", body: AIError.noProvider(config.provider).localizedDescription)
            return
        }
        if case .notReady(let reason, let hint) = provider.readiness() {
            HaloNotifier.failure("Halo AI", body: [reason, hint].compactMap { $0 }.joined(separator: " "))
            return
        }

        let source = AIInputSource(rawValue: action.argument) ?? .clipboard
        let input: String
        switch source {
        case .clipboard: input = ClipboardHistory.shared.current
        case .selection: input = SelectionReader.selectedText() ?? ClipboardHistory.shared.current
        case .typed:     input = ActionExecutor.shared.typedText
        case .none:      input = ""
        }

        // A prompt that says "translate this" with nothing to translate wastes
        // the user's time — refuse before spinning up the model.
        if source != .none, input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HaloNotifier.failure("Halo AI", body: AIError.emptyInput.localizedDescription)
            return
        }

        let request = Request(
            prompt: service.fill(prompt: ActionExecutor.shared.expand(action.value), input: input),
            provider: provider,
            config: config,
            sink: action.sink == .discard ? .clipboard : action.sink,
            title: item?.title ?? "Halo AI",
            input: input)

        lastRequest = request
        config.reviewBeforeApplying ? runReviewed(request) : runDirect(request)
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        isRunning = false

        if AIResultPanelController.shared.isVisible {
            AIResultPanelController.shared.model.state = .failed(String(localized: "キャンセルしました。"))
        } else {
            HaloHUD.shared.show("Halo AI", body: String(localized: "キャンセルしました"), kind: .info)
        }
    }

    // MARK: - Reviewed run

    /// Streams into the review panel and waits for the user to decide.
    private func runReviewed(_ request: Request) {
        let controller = AIResultPanelController.shared
        let model = controller.model

        model.title = request.title
        model.input = request.input
        model.text = ""
        model.state = .generating
        model.replaces = request.sink == .paste

        model.onStop = { [weak self] in self?.cancel() }
        model.onClose = {
            controller.close()
            ActionExecutor.shared.returnFocusToContextApp()
        }
        model.onCopy = { text in
            ClipboardHistory.shared.put(text)
            controller.close()
            HaloHUD.shared.show(request.title, body: String(localized: "クリップボードにコピーしました"), kind: .success)
        }
        model.onReplace = { text in
            controller.close()
            ClipboardHistory.shared.put(text)
            // Focus has to be back in the document before ⌘V, and the panel
            // must be gone or it will swallow the keystroke.
            ActionExecutor.shared.synthesizePaste(plainText: false, after: 0.16)
            HaloHUD.shared.show(request.title, body: String(localized: "置き換えました"), kind: .success)
        }
        model.onRegenerate = { [weak self] in
            guard let self, let last = self.lastRequest else { return }
            self.runReviewed(last)
        }

        controller.present()
        stream(request) { partial in
            model.text = partial
        } completion: { result in
            switch result {
            case .success(let text):
                model.text = text
                model.state = .finished
            case .failure(let error):
                model.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Direct run

    /// Applies the answer without asking. Only reachable when the user has
    /// turned the review step off.
    private func runDirect(_ request: Request) {
        HaloHUD.shared.show(request.title, body: String(localized: "考えています…"), kind: .info, duration: .infinity)

        stream(request) { partial in
            HaloHUD.shared.show(request.title, body: Self.preview(partial),
                                kind: .info, duration: .infinity)
        } completion: { [weak self] result in
            switch result {
            case .success(let text):
                self?.deliver(text, sink: request.sink, title: request.title)
            case .failure(let error):
                HaloNotifier.failure(request.title, body: error.localizedDescription)
            }
        }
    }

    private func deliver(_ output: String, sink: ResultSink, title: String) {
        switch sink {
        case .discard, .notification:
            // The full text still goes to the pasteboard: the HUD can only show
            // the first few lines, and losing the rest would be worse.
            ClipboardHistory.shared.put(output)
            HaloNotifier.success(title, body: Self.preview(output))
        case .clipboard:
            ClipboardHistory.shared.put(output)
            HaloNotifier.success(title, body: String(localized: "クリップボードにコピーしました"))
        case .paste:
            ClipboardHistory.shared.put(output)
            HaloHUD.shared.show(title, body: String(localized: "置き換えました"), kind: .success)
            ActionExecutor.shared.synthesizePaste(plainText: false, after: 0.05)
        }
    }

    // MARK: - Streaming

    private func stream(_ request: Request,
                        onPartial: @escaping (String) -> Void,
                        completion: @escaping (Result<String, Error>) -> Void) {
        task?.cancel()
        isRunning = true

        task = Task { [weak self] in
            var latest = ""
            do {
                for try await text in request.provider.stream(prompt: request.prompt,
                                                              config: request.config) {
                    if Task.isCancelled { break }
                    latest = text
                    onPartial(text)
                }
                guard !Task.isCancelled else {
                    self?.finish()
                    return
                }
                let output = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.isEmpty {
                    completion(.failure(AIError.emptyResponse))
                } else {
                    completion(.success(output))
                }
            } catch is CancellationError {
                // cancel() already told the user.
            } catch {
                if !Task.isCancelled { completion(.failure(error)) }
            }
            self?.finish()
        }
    }

    private func finish() {
        isRunning = false
        task = nil
    }

    /// Trims a growing answer to something a three-line HUD can hold.
    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}
