import AppKit

/// Command-line entry points used while developing.
///
/// They exist so the parts that cannot be reached from a screenshot — the model
/// round trip, the review panel — can be exercised without driving the ring by
/// hand. None of them are reachable from the UI.
@MainActor
enum DebugCommands {

    /// Handles a debug flag and reports whether the process should stop after.
    /// Returns nil when no debug flag was given.
    static func run() -> Bool? {
        if let prompt = value(for: "--ai-test") {
            runModelCheck(prompt: prompt)
            return true
        }
        return nil
    }

    /// Called after launch: ordering a window front before `NSApp.run()` does
    /// not put it on screen.
    static func showPanelDemoIfRequested() {
        guard CommandLine.arguments.contains("--ai-panel-demo") else { return }
        showPanelDemo()
    }

    /// Exercises the real provider — options, session, error mapping — rather
    /// than the framework directly, then exits with a useful status.
    private static func runModelCheck(prompt: String) {
        guard #available(macOS 26.0, *) else {
            print("macOS 26 以降が必要です")
            exit(2)
        }
        let provider = AppleOnDeviceProvider()
        switch provider.readiness() {
        case .notReady(let reason, let hint):
            print("利用不可: \(reason) \(hint ?? "")")
            exit(2)
        case .ready:
            break
        }

        var config = AIConfig.default
        config.enabled = true

        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0

        Task.detached {
            do {
                var streamed = ""
                for try await partial in provider.stream(prompt: prompt, config: config) {
                    streamed = partial
                }
                print("--- streamed ---")
                print(streamed)

                let once = try await provider.complete(prompt: prompt, config: config)
                print("--- complete ---")
                print(once)
            } catch {
                print("エラー: \(error.localizedDescription)")
                status = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(status)
    }

    /// Puts the review panel on screen with canned content.
    private static func showPanelDemo() {
        let controller = AIResultPanelController.shared
        let model = controller.model
        model.title = "日本語に"
        model.input = "The ring appears around the cursor."
        model.text = "リングはカーソルの周りに現れます。"
        model.replaces = true
        model.state = .finished
        model.onClose = { controller.close() }
        controller.present()
    }

    private static func value(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
