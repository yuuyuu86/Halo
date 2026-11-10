import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Three-column ring editor: rings → items → item detail, plus a live preview
/// of the ring being edited.
struct RingsPane: View {

    @ObservedObject private var store = ConfigStore.shared
    @State private var selectedRingID: String?
    @State private var selectedItemID: UUID?
    @State private var hotKeyWarning: String?

    private var selectedRingIndex: Int? {
        guard let selectedRingID else { return nil }
        return store.config.rings.firstIndex { $0.id == selectedRingID }
    }

    private var selectedItemIndex: Int? {
        guard let ringIndex = selectedRingIndex, let selectedItemID else { return nil }
        return store.config.rings[ringIndex].items.firstIndex { $0.id == selectedItemID }
    }

    var body: some View {
        HSplitView {
            ringList
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            itemList
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            detail
                .frame(minWidth: 340)
        }
        .onAppear {
            if selectedRingID == nil { selectedRingID = store.config.rootRingID }
        }
    }

    // MARK: - Rings column

    private var ringList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedRingID) {
                ForEach(store.config.rings) { ring in
                    HStack(spacing: 6) {
                        Image(systemName: ring.id == store.config.rootRingID
                              ? "circle.circle.fill" : "circle.circle")
                            .foregroundStyle(ring.id == store.config.rootRingID ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ring.title)
                            HStack(spacing: 5) {
                                Text("\(ring.activeItems.count) 項目")
                                if let hotKey = ring.hotKey, hotKey.enabled {
                                    Text(KeyCodeNames.describe(hotKey))
                                        .padding(.horizontal, 4)
                                        .background(RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.secondary.opacity(0.18)))
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(ring.id)
                    .contextMenu {
                        Button("ルートリングに設定") { store.config.rootRingID = ring.id }
                        Button("複製") { duplicate(ring) }
                        Divider()
                        Button("削除", role: .destructive) { store.deleteRing(id: ring.id) }
                            .disabled(ring.id == store.config.rootRingID)
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Button {
                    let ring = store.addRing()
                    selectedRingID = ring.id
                } label: { Image(systemName: "plus") }
                Button {
                    if let id = selectedRingID { store.deleteRing(id: id) }
                    selectedRingID = store.config.rootRingID
                } label: { Image(systemName: "minus") }
                .disabled(selectedRingID == nil || selectedRingID == store.config.rootRingID)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(7)
        }
    }

    // MARK: - Items column

    @ViewBuilder
    private var itemList: some View {
        if let ringIndex = selectedRingIndex {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("リング名", text: Binding(
                        get: { store.config.rings[ringIndex].title },
                        set: { store.config.rings[ringIndex].title = $0 }))
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 6) {
                        Toggle("専用キー", isOn: Binding(
                            get: { store.config.rings[ringIndex].hotKey?.enabled ?? false },
                            set: { enabled in
                                var hotKey = store.config.rings[ringIndex].hotKey ?? HotKeyConfig()
                                hotKey.enabled = enabled
                                store.config.rings[ringIndex].hotKey = enabled ? hotKey : nil
                                applyHotKeys()
                            }))
                        .toggleStyle(.checkbox)

                        if store.config.rings[ringIndex].hotKey?.enabled == true {
                            HotKeyRecorder(config: Binding(
                                get: { store.config.rings[ringIndex].hotKey ?? HotKeyConfig() },
                                set: { store.config.rings[ringIndex].hotKey = $0 }),
                                           onChange: applyHotKeys)
                        }
                        Spacer()
                    }
                    .font(.callout)

                    if let message = hotKeyWarning {
                        Text(message)
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)

                Divider()

                List(selection: $selectedItemID) {
                    ForEach(store.config.rings[ringIndex].items) { item in
                        HStack(spacing: 8) {
                            ItemIcon(item: item)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                Text(item.action.kind.displayName)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !item.enabled {
                                Image(systemName: "eye.slash").foregroundStyle(.tertiary)
                            }
                        }
                        .tag(item.id)
                    }
                    .onMove { indices, destination in
                        store.config.rings[ringIndex].items.move(fromOffsets: indices,
                                                                 toOffset: destination)
                    }
                    .onDelete { offsets in
                        store.config.rings[ringIndex].items.remove(atOffsets: offsets)
                    }
                }

                Divider()
                HStack(spacing: 6) {
                    Button {
                        let item = RingItem()
                        store.config.rings[ringIndex].items.append(item)
                        selectedItemID = item.id
                    } label: { Image(systemName: "plus") }

                    Button {
                        if let itemIndex = selectedItemIndex {
                            store.config.rings[ringIndex].items.remove(at: itemIndex)
                            selectedItemID = nil
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedItemIndex == nil)

                    Menu {
                        Button("アプリから追加…") { addAppsViaPanel(ringIndex: ringIndex) }
                        Button("クリップボード履歴リング") {
                            var item = RingItem(title: "履歴", glyph: "clock.arrow.circlepath")
                            item.action = .clip(.history)
                            store.config.rings[ringIndex].items.append(item)
                        }
                        Button("起動中アプリのリング") {
                            var item = RingItem(title: "アプリ切替", glyph: "square.stack")
                            item.action = .subring(DynamicRing.runningApps.rawValue)
                            store.config.rings[ringIndex].items.append(item)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()
                    Text("ドラッグで並び替え")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .padding(7)
            }
        } else {
            ContentUnavailableView("リングを選択してください", systemImage: "circle.circle")
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detail: some View {
        if let ringIndex = selectedRingIndex, let itemIndex = selectedItemIndex {
            ItemEditor(item: Binding(
                get: { store.config.rings[ringIndex].items[itemIndex] },
                set: { store.config.rings[ringIndex].items[itemIndex] = $0 }))
        } else if let ringIndex = selectedRingIndex {
            VStack(spacing: 14) {
                RingPreview(ring: store.config.rings[ringIndex])
                    .frame(height: 320)
                Text("項目を選ぶと編集できます")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ContentUnavailableView("項目を選択してください", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: - Helpers

    /// Re-registers every hot key and reports the ones the system refused —
    /// usually because another app already owns the combination.
    private func applyHotKeys() {
        let failed = (NSApp.delegate as? AppDelegate)?.refreshHotKeys() ?? []
        let names = failed.compactMap { target -> String? in
            guard case .ring(let id) = target else { return String(localized: "メインのショートカット") }
            return store.config.ring(withID: id)?.title
        }
        // Joined outside the interpolation: a nested quote inside a localised
        // string literal breaks the key the strings file has to match.
        let joined = names.joined(separator: String(localized: "、"))
        hotKeyWarning = names.isEmpty
            ? nil
            : String(localized: "このキーは登録できませんでした（\(joined)）。ほかのアプリが使用中の可能性があります。")
    }

    private func duplicate(_ ring: Ring) {
        var copy = ring
        copy.id = "ring." + UUID().uuidString.prefix(8).lowercased()
        copy.title = String(localized: "\(ring.title) のコピー")
        copy.hotKey = nil       // two rings must not fight over one key
        copy.items = ring.items.map { item in
            var new = item
            new.id = UUID()
            return new
        }
        store.config.rings.append(copy)
        selectedRingID = copy.id
    }

    private func addAppsViaPanel(ringIndex: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "追加")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            store.config.rings[ringIndex].items.append(
                RingItem(title: name, glyph: "", action: .app(url.path)))
        }
    }
}

// MARK: - Small pieces

struct ItemIcon: View {
    let item: RingItem

    var body: some View {
        Group {
            if let icon = AppIndex.icon(for: item.action) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: item.effectiveGlyph)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Static rendering of a ring, used so the editor shows what will be summoned.
struct RingPreview: View {

    let ring: Ring
    @ObservedObject private var store = ConfigStore.shared

    init(ring: Ring) { self.ring = ring }

    var body: some View {
        let appearance = store.config.appearance
        let theme = HaloTheme.from(appearance)
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            // Scale the real geometry down to whatever space the editor gives us.
            let fit = min(proxy.size.width, proxy.size.height) / 2 - 52
            let scale = min(1, fit / max(appearance.ringRadius, 1))
            let radius = appearance.ringRadius * scale
            let nodeSize = appearance.nodeSize * scale
            let items = ring.activeItems
            let layout = appearance.layout(count: max(items.count, 1))

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.88))

                Circle()
                    .trim(from: 0, to: min(max(appearance.sweepDegrees, 30), 360) / 360)
                    .stroke(theme.ringBase, lineWidth: appearance.ringThickness)
                    .frame(width: radius * 2, height: radius * 2)
                    .rotationEffect(baseRotation(layout: layout, appearance: appearance))
                    .position(center)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let point = RingGeometry.point(index: index, layout: layout,
                                                   radius: radius, center: center)
                    ZStack {
                        Circle().fill(theme.nodeFill)
                        Circle().stroke(theme.nodeStroke, lineWidth: 0.75)
                        if let icon = AppIndex.icon(for: item.action) {
                            Image(nsImage: icon).resizable()
                                .frame(width: nodeSize * 0.52, height: nodeSize * 0.52)
                                .saturation(appearance.iconStyle == .monochrome ? 0 : 1)
                        } else {
                            Image(systemName: item.effectiveGlyph)
                                .font(.system(size: nodeSize * 0.40))
                                .foregroundStyle(theme.glyph)
                        }
                    }
                    .frame(width: nodeSize, height: nodeSize)
                    .position(point)

                    if appearance.labelPlacement == .outside || appearance.labelPlacement == .inside {
                        let angle = RingGeometry.angle(index: index, layout: layout)
                        let clearance = nodeSize / 2 + appearance.labelSize * scale + 8
                        let inside = appearance.labelPlacement == .inside
                        Text(item.title)
                            .font(.system(size: appearance.labelSize * scale, design: .rounded))
                            .foregroundStyle(theme.label)
                            .lineLimit(1)
                            .fixedSize()
                            .position(RingGeometry.point(
                                index: index, layout: layout,
                                radius: radius + (inside ? -clearance
                                                         : clearance + abs(cos(angle)) * 26 * scale),
                                center: center))
                    }
                }

                if appearance.coreStyle != .hidden {
                    Text(ring.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.labelSelected)
                        .position(center)
                }
            }
        }
    }

    private func baseRotation(layout: RingLayout, appearance: Appearance) -> Angle {
        let fraction = min(max(appearance.sweepDegrees, 30), 360) / 360
        guard fraction < 1 else { return .zero }
        let first = layout.angle(at: 0)
        let last = layout.angle(at: max(layout.count - 1, 0))
        let arcStart = appearance.clockwise ? last : first
        return .radians(-arcStart - fraction * 2 * .pi)
    }
}
