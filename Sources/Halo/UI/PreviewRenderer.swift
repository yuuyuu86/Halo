import AppKit
import SwiftUI

/// Offscreen renderer for the ring.
///
/// `Halo --render-preview <out.png> [--depth 2] [--select 3]` draws the overlay
/// into a PNG and exits. Materials do not composite in an offscreen renderer, so
/// a dark plate stands in for the desktop behind the ring — everything else
/// (geometry, glow, labels, core, echo rings) is the real view.
@MainActor
enum PreviewRenderer {

    static func runIfRequested() -> Bool {
        if renderWelcomeIfRequested() { return true }
        if renderAIPanelIfRequested() { return true }
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview"),
              CommandLine.arguments.indices.contains(flagIndex + 1) else { return false }

        let path = CommandLine.arguments[flagIndex + 1]
        let depth = intArgument("--depth") ?? 1
        let select = intArgument("--select")
        let filter = stringArgument("--filter") ?? ""
        let hud = CommandLine.arguments.contains("--hud")
        let size = CGSize(width: 760, height: 560)

        RingController.shared.prepareForOffscreenRender(size: size, depth: depth,
                                                        selection: select, filter: filter,
                                                        ringID: stringArgument("--ring"))

        let model = HaloHUD.Model()
        model.title = "スクリプト完了"
        model.body = "クリップボードにコピーしました"
        model.kind = .success
        model.visible = true

        let view = ZStack(alignment: .top) {
            Rectangle().fill(
                LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.21),
                                        Color(red: 0.07, green: 0.07, blue: 0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            HaloRingView()
            if hud {
                HUDView(model: model)
                    .frame(width: 420, height: 92)
            }
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    /// `--render-welcome out.png [--step 1]` draws an onboarding page.
    private static func renderWelcomeIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--render-welcome"),
              CommandLine.arguments.indices.contains(index + 1) else { return false }
        let path = CommandLine.arguments[index + 1]
        let step = intArgument("--step") ?? 0

        let view = WelcomeView(initialStep: step) {}
            .frame(width: 600, height: 540)

        write(ImageRenderer(content: view), to: path)
        return true
    }

    /// `--render-ai-panel out.png [--generating]` draws the AI review panel.
    private static func renderAIPanelIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--render-ai-panel"),
              CommandLine.arguments.indices.contains(index + 1) else { return false }

        let model = AIResultModel()
        model.title = "日本語に"
        model.input = "The ring appears around the cursor, so the action you need is always the same flick away."
        model.text = "リングはカーソルの周りに現れます。必要な操作は、いつでも同じひと弾きの距離にあります。"
        model.replaces = true
        model.state = CommandLine.arguments.contains("--generating") ? .generating : .finished

        let view = AIResultView(model: model)
            .frame(width: 520, height: 380)
            .environment(\.colorScheme, .dark)

        write(ImageRenderer(content: view), to: CommandLine.arguments[index + 1])
        return true
    }

    private static func write<V: View>(_ renderer: ImageRenderer<V>, to path: String) {
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func intArgument(_ name: String) -> Int? {
        stringArgument(name).flatMap(Int.init)
    }

    private static func stringArgument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
