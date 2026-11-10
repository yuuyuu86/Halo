import Foundation

/// Thin wrapper around `Process`. Nothing here touches the UI, so it is safe to
/// call from a detached task while the ring animates away.
enum Shell {

    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs a command to completion and captures its output.
    /// A hard timeout keeps a runaway script from leaking a process forever.
    static func run(_ launchPath: String,
                    arguments: [String],
                    stdin: String?,
                    timeout: TimeInterval = 20) -> Result {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe = Pipe()
        if stdin != nil { process.standardInput = inPipe }

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }

        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        // Read both pipes concurrently so a large stdout cannot deadlock us.
        let outData = UnsafeSendableBox<Data>(Data())
        let errData = UnsafeSendableBox<Data>(Data())
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            outData.value = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            errData.value = errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            process.terminate()
            return Result(status: -1, output: "", error: "タイムアウト（\(Int(timeout)) 秒）")
        }
        group.wait()

        return Result(status: process.terminationStatus,
                      output: String(data: outData.value, encoding: .utf8) ?? "",
                      error: String(data: errData.value, encoding: .utf8) ?? "")
    }

    /// Fire-and-forget: used for system commands whose output we never read.
    static func detach(_ launchPath: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            NSLog("Halo: failed to launch %@ — %@", launchPath, error.localizedDescription)
        }
    }
}

/// Minimal mutable box so the two pipe readers can hand data back.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Carries a non-Sendable value across a hop we have already proven is safe.
///
/// AppKit's local event monitors always fire on the main thread, but `NSEvent`
/// is explicitly non-Sendable, so handing one to `MainActor.assumeIsolated`
/// trips a concurrency diagnostic. Boxing it states the invariant once instead
/// of suppressing the warning at every call site.
struct MainThreadBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
