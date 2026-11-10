import AppKit

// Halo is an agent app: no storyboard, no main menu nib, no Dock icon.
// Everything is assembled here so the launch path stays obvious.
MainActor.assumeIsolated {
    let application = NSApplication.shared

    // Offscreen render mode exits before any UI is put on screen.
    if PreviewRenderer.runIfRequested() { exit(0) }
    if let shouldExit = DebugCommands.run(), shouldExit { exit(0) }

    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // Keep the delegate alive for the process lifetime; `run()` never returns.
    objc_setAssociatedObject(application, "halo.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.run()
}
