import AppKit
import SwiftUI

/// Curated SF Symbol catalogue.
///
/// The system exposes no way to enumerate its symbols, so Halo ships a hand-
/// picked list covering the things ring items actually are. Every name is
/// checked against the running OS before it is offered, so a symbol added in a
/// newer macOS never renders as a blank node.
enum SymbolCatalogue {

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let names: [String]
    }

    static let groups: [Group] = [
        Group(title: String(localized: "よく使う"), names: [
            "bolt.fill", "star.fill", "heart.fill", "flame.fill", "sparkles",
            "circle.fill", "square.fill", "diamond.fill", "hexagon.fill", "seal.fill",
            "checkmark.circle.fill", "xmark.circle.fill", "questionmark.circle",
            "exclamationmark.triangle", "pin.fill", "bookmark.fill", "tag.fill"
        ]),
        Group(title: String(localized: "アプリ・起動"), names: [
            "app.badge", "app.dashed", "square.grid.2x2", "square.grid.3x3",
            "square.stack", "square.stack.3d.up", "rectangle.3.group",
            "macwindow", "menubar.rectangle", "dock.rectangle", "rectangle.on.rectangle"
        ]),
        Group(title: String(localized: "Web・通信"), names: [
            "globe", "safari", "network", "link", "antenna.radiowaves.left.and.right",
            "wifi", "cloud", "icloud", "arrow.down.circle", "arrow.up.circle",
            "paperplane.fill", "envelope", "envelope.open", "at", "bubble.left",
            "message", "phone", "video"
        ]),
        Group(title: String(localized: "ファイル・テキスト"), names: [
            "folder", "folder.fill", "doc", "doc.text", "doc.plaintext", "doc.on.doc",
            "doc.on.clipboard", "arrow.down.doc", "arrow.up.doc", "tray", "tray.full",
            "archivebox", "trash", "textformat", "textformat.size", "text.quote",
            "character.book.closed", "list.bullet", "checklist", "note.text"
        ]),
        Group(title: String(localized: "開発"), names: [
            "chevron.left.forwardslash.chevron.right", "terminal", "terminal.fill",
            "hammer", "wrench.and.screwdriver", "ant", "ladybug", "cpu", "memorychip",
            "externaldrive", "server.rack", "arrow.triangle.branch",
            "arrow.triangle.pull", "arrow.triangle.merge", "curlybraces", "function",
            "point.3.filled.connected.trianglepath.dotted"
        ]),
        Group(title: String(localized: "システム"), names: [
            "gearshape", "gearshape.2", "slider.horizontal.3", "switch.2",
            "lock", "lock.open", "power", "moon", "sun.max", "circle.lefthalf.filled",
            "display", "desktopcomputer", "laptopcomputer", "keyboard", "cursorarrow",
            "battery.100", "speaker.wave.2", "speaker.slash", "bell", "bell.slash"
        ]),
        Group(title: String(localized: "メディア"), names: [
            "play.fill", "pause.fill", "stop.fill", "forward.fill", "backward.fill",
            "camera", "camera.viewfinder", "photo", "photo.on.rectangle", "film",
            "music.note", "mic", "headphones", "waveform", "play.rectangle"
        ]),
        Group(title: String(localized: "ナビゲーション"), names: [
            "arrow.up", "arrow.down", "arrow.left", "arrow.right",
            "arrow.clockwise", "arrow.counterclockwise", "arrow.uturn.backward",
            "chevron.up", "chevron.down", "chevron.left", "chevron.right",
            "magnifyingglass", "location", "map", "scope", "target"
        ]),
        Group(title: String(localized: "時間・予定"), names: [
            "clock", "clock.arrow.circlepath", "alarm", "timer", "stopwatch",
            "calendar", "calendar.badge.plus", "hourglass"
        ]),
        Group(title: String(localized: "人・場所"), names: [
            "person", "person.2", "person.crop.circle", "house", "building.2",
            "cart", "creditcard", "bag", "gift", "briefcase", "graduationcap"
        ])
    ]

    /// Names present on the running system, in catalogue order.
    static let available: [Group] = groups.compactMap { group in
        let names = group.names.filter { exists($0) }
        return names.isEmpty ? nil : Group(title: group.title, names: names)
    }

    static func exists(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return available.flatMap(\.names).filter { $0.contains(q) }
    }
}

/// Grid picker with search, shown from the item editor.
struct SymbolPicker: View {

    @Binding var glyph: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("シンボルを検索", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(10)

            Divider()

            ScrollView {
                if query.isEmpty {
                    ForEach(SymbolCatalogue.available) { group in
                        section(title: group.title, names: group.names)
                    }
                } else {
                    let results = SymbolCatalogue.search(query)
                    if results.isEmpty {
                        ContentUnavailableView("見つかりません", systemImage: "questionmark.circle",
                                               description: Text("名前を直接入力することもできます"))
                            .padding(.top, 40)
                    } else {
                        section(title: String(localized: "検索結果"), names: results)
                    }
                }
            }

            Divider()

            HStack {
                Text(glyph.isEmpty ? "未選択" : glyph)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("クリア") { glyph = "" }
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 460, height: 480)
    }

    private func section(title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button {
                        glyph = name
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 18))
                            .frame(width: 40, height: 40)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(glyph == name
                                          ? Color.accentColor.opacity(0.28)
                                          : Color.secondary.opacity(0.10))
                            }
                            .overlay {
                                if glyph == name {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}
