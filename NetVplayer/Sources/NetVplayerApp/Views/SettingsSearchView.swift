import SwiftUI
import AppKit
import Models

struct SettingsSearchBar: View {
    @Environment(\.appThemePalette) private var palette
    let navigate: (SettingsSearchTarget) -> Void
    let availability: (SettingsSearchTarget) -> String?
    var onSearch: () -> Void = {}
    @State private var query = ""
    @State private var showsResults = false
    @State private var selectedIndex = 0
    @State private var resultsHeight: CGFloat = 0
    @FocusState private var focused: Bool
    private var results: [SettingsSearchEntry] { SettingsSearchIndex.matches(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("搜索设置"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityIdentifier("settings-search-field")
                    .onSubmit { activateSelection() }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onExitCommand { dismissResults() }
                if !query.isEmpty {
                    Button { query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("清除搜索"))
                } else {
                    Text("⌘F").font(.caption.monospaced()).foregroundStyle(palette.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4).frame(minHeight: 40)
            .background { AppGlassSurface(cornerRadius: 8, role: .control, usesSystemMaterial: false) }
            .onChange(of: query) { _, _ in selectedIndex = 0; showsResults = true; onSearch() }
            .onChange(of: focused) { _, value in if value && !query.isEmpty { showsResults = true } }

            if showsResults && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if results.isEmpty {
                    Text(L10n.text("没有匹配的设置，试试其他关键词。"))
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                        .accessibilityIdentifier("settings-search-empty")
                } else {
                    Text(L10n.text("{0} 项设置 · ↑↓ 选择，回车定位", [String(results.count)]))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { offset, entry in
                                    Button { activate(entry.id) } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(palette.accent)
                                                .opacity(offset == selectedIndex ? 1 : 0)
                                                .frame(width: 20).accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.title).font(.system(size: 13, weight: .semibold))
                                                Text(entry.path).font(.caption).foregroundStyle(palette.muted)
                                                if let reason = availability(entry.id) {
                                                    Label(reason, systemImage: "info.circle")
                                                        .font(.caption).foregroundStyle(palette.muted)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "arrow.up.right").font(.caption)
                                                .foregroundStyle(palette.muted).accessibilityHidden(true)
                                        }
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(9)
                                        .background(offset == selectedIndex ? palette.accent.opacity(0.14) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(offset == selectedIndex ? palette.accent : .clear, lineWidth: 2)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(entry.id)
                                    .accessibilityIdentifier("settings-result-" + entry.id.rawValue)
                                    .accessibilityHint(L10n.text("定位设置"))
                                    .accessibilityAddTraits(offset == selectedIndex ? .isSelected : [])
                                }
                            }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: SettingsSearchResultsHeightKey.self, value: geometry.size.height)
                                }
                            }
                        }
                        .frame(height: min(230, resultsHeight > 0 ? resultsHeight : 230))
                        .onPreferenceChange(SettingsSearchResultsHeightKey.self) { resultsHeight = $0 }
                        .onChange(of: selectedIndex) { _, index in
                            if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                        }
                    }
                }
            }
        }
        .background {
            Button(L10n.text("搜索设置")) { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        showsResults = true
        selectedIndex = min(results.count - 1, max(0, selectedIndex + delta))
    }
    private func activateSelection() {
        guard showsResults, results.indices.contains(selectedIndex) else { return }
        activate(results[selectedIndex].id)
    }
    private func activate(_ target: SettingsSearchTarget) {
        dismissResults()
        navigate(target)
    }
    private func dismissResults() { showsResults = false; focused = false }
}

private struct SettingsSearchResultsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsSearchLocation: Equatable {
    let target: SettingsSearchTarget
    let request: UUID
    let highlighted: Bool
}
private struct SettingsSearchLocationKey: EnvironmentKey {
    static let defaultValue: SettingsSearchLocation? = nil
}
extension EnvironmentValues {
    var settingsSearchLocation: SettingsSearchLocation? {
        get { self[SettingsSearchLocationKey.self] }
        set { self[SettingsSearchLocationKey.self] = newValue }
    }
}
struct SettingsSearchAnchorPosition: Equatable {
    let request: UUID
    let frame: CGRect
}
struct SettingsSearchViewportKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}
struct SettingsSearchAnchorKey: PreferenceKey {
    static let defaultValue: [SettingsSearchTarget: SettingsSearchAnchorPosition] = [:]
    static func reduce(value: inout [SettingsSearchTarget: SettingsSearchAnchorPosition],
                       nextValue: () -> [SettingsSearchTarget: SettingsSearchAnchorPosition]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct SettingsSearchAnchor: ViewModifier {
    let target: SettingsSearchTarget
    @Environment(\.settingsSearchLocation) private var location
    @Environment(\.appThemePalette) private var palette
    func body(content: Content) -> some View {
        content
            .id(target)
            .accessibilityIdentifier("settings-target-" + target.rawValue)
            .background {
                if location?.target == target, location?.highlighted == true {
                    RoundedRectangle(cornerRadius: 8).fill(palette.accent.opacity(0.10))
                }
            }
            .overlay {
                if location?.target == target, location?.highlighted == true {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(palette.accent, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if location?.target == target {
                    SettingsSearchScrollAnchor(request: location?.request)
                }
            }
            .background {
                if let location {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SettingsSearchAnchorKey.self,
                            value: [target: SettingsSearchAnchorPosition(request: location.request,
                                                                        frame: geometry.frame(in: .global))])
                    }
                }
            }
    }
}
extension View {
    func settingsSearchAnchor(_ target: SettingsSearchTarget) -> some View {
        modifier(SettingsSearchAnchor(target: target))
    }
}

/// ScrollViewReader does not reliably register IDs hosted in GroupBox labels on macOS.
/// This bridge receives only an ephemeral request and scrolls the existing container.
private struct SettingsSearchScrollAnchor: NSViewRepresentable {
    let request: UUID?
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.request = request; view.schedule() }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.request = nil }

    final class AnchorView: NSView {
        var request: UUID?
        private var completed: UUID?
        private var scheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            guard !scheduled, let request, request != completed, window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.request == request, self.completed != request, self.window != nil,
                      let scroll = self.enclosingScrollView, let document = scroll.documentView,
                      !self.bounds.isEmpty else { return }
                let clip = scroll.contentView
                let rect = self.convert(self.bounds, to: document)
                let y = min(max(document.bounds.minY, rect.midY - clip.bounds.height / 2),
                            max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
                self.completed = request
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }
}
