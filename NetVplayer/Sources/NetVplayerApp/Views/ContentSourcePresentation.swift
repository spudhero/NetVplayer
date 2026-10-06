import SwiftUI
import AppKit
import Models

extension Notification.Name {
    static let contentSourceCloudAuthCompleted = Notification.Name("NetVplayer.contentSourceCloudAuthCompleted")
}

struct ContentSourceCloudAuthResult {
    let provider: DriveProvider
    let completion: CloudAuthCompletion
}

enum ContentSourceCategory: String, CaseIterable, Identifiable {
    case online, cloud, files, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .online: L10n.text("在线视频与直播")
        case .cloud: L10n.text("网盘账号")
        case .files: L10n.text("NAS 与本地媒体")
        case .search: L10n.text("搜索与连接检查")
        }
    }
    var navigationTitle: String {
        switch self {
        case .online: L10n.text("在线内容")
        case .cloud: L10n.text("网盘账号")
        case .files: L10n.text("NAS / 本地")
        case .search: L10n.text("搜索与检查")
        }
    }
}

struct ContentSourceGroup<Content: View>: View {
    @Environment(\.appThemePalette) private var palette
    let category: ContentSourceCategory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(category.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: AppSurfaceVisualPolicy.pageSectionGap) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(category)
    }
}

struct SettingsFieldStyle: TextFieldStyle {
    @Environment(\.appThemePalette) private var palette
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 34)
            .background {
                AppGlassSurface(cornerRadius: 8, role: .control, usesSystemMaterial: false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? palette.accent : .clear, lineWidth: 2)
            }
            .focused($focused)
            .tint(palette.accent)
    }
}

struct SettingsChoicePicker<Value: Hashable>: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    @Binding var selection: Value
    let choices: [Value]
    let label: (Value) -> String

    var body: some View {
        Menu {
            ForEach(choices, id: \.self) { value in
                Button { selection = value } label: {
                    if value == selection {
                        Label(label(value), systemImage: "checkmark")
                    } else {
                        Text(label(value))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label(selection)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background {
                AppGlassSurface(cornerRadius: 8, role: .control, usesSystemMaterial: false)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(palette.foreground)
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }
}

struct SettingsInlineMessage: View {
    @Environment(\.appThemePalette) private var palette
    let message: String
    var role: AppSemanticColorRole = .danger

    var body: some View {
        Label(message, systemImage: role == .success ? "checkmark.circle" : "exclamationmark.circle")
            .font(.system(size: 12))
            .foregroundStyle(palette.color(for: role))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum FileConnectionPresentation {
    static let choices: [FileServiceKind] = [.local, .smb, .webDAV, .alist, .openList]
    static func title(_ kind: FileServiceKind) -> String {
        switch kind {
        case .local: L10n.text("本机文件夹")
        case .smb: L10n.text("NAS / 共享文件夹（SMB）")
        case .webDAV: L10n.text("文件服务器（WebDAV）")
        case .alist: L10n.text("AList 文件列表")
        case .openList: L10n.text("OpenList 文件列表")
        }
    }
    static func hint(_ kind: FileServiceKind) -> String {
        switch kind {
        case .local: L10n.text("选择这台 Mac 上的视频文件夹。更换电脑后需要重新选择。")
        case .smb: L10n.text("粘贴或输入完整的文件夹地址，账号和密码在下方填写。")
        case .webDAV: L10n.text("连接支持 WebDAV 的 NAS 或文件服务器，填写服务方提供的地址。")
        case .alist: L10n.text("连接自己的 AList 文件列表，浏览其中的视频与文件夹。")
        case .openList: L10n.text("连接自己的 OpenList 文件列表，浏览其中的视频与文件夹。")
        }
    }
    static func metadataTitle(_ source: MetadataSource) -> String {
        switch source {
        case .automatic: L10n.text("自动选择")
        case .local: L10n.text("仅使用本地资料")
        default: L10n.text(source.title)
        }
    }
}

private struct SettingsEditorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A sheet grows with its form. Its header and actions stay outside the scroll area.
struct SettingsEditorContainer<Content: View, Actions: View>: View {
    @Environment(\.appThemePalette) private var palette
    let title: String
    var width: CGFloat = 620
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @State private var contentHeight: CGFloat = 1
    @State private var availableHeight: CGFloat = 720

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)
            Divider()
            ThemedScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: SettingsEditorHeightKey.self, value: geometry.size.height)
                        }
                    }
            }
            .frame(height: min(contentHeight, max(120, availableHeight - 132)))
            Divider()
            HStack(spacing: 10) { actions }
                .frame(minHeight: 32)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .textFieldStyle(SettingsFieldStyle())
        .themedPresentation()
        .background {
            SettingsEditorHostMetrics { height in
                if abs(availableHeight - height) > 1 { availableHeight = height }
            }
        }
        .onPreferenceChange(SettingsEditorHeightKey.self) { height in
            if abs(contentHeight - height) > 1 { contentHeight = height }
        }
    }
}

private struct SettingsEditorHostMetrics: NSViewRepresentable {
    let updateHeight: (CGFloat) -> Void
    func makeNSView(context: Context) -> SettingsEditorMetricsView {
        let view = SettingsEditorMetricsView()
        view.updateHeight = updateHeight
        return view
    }
    func updateNSView(_ view: SettingsEditorMetricsView, context: Context) {
        view.updateHeight = updateHeight
    }
}

private final class SettingsEditorMetricsView: NSView {
    var updateHeight: ((CGFloat) -> Void)?
    private var observation: SettingsEditorResizeObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation = nil
        guard let window else { return }
        let host = window.sheetParent ?? window
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.measure() }
        }
        observation = SettingsEditorResizeObservation(token: token)
        DispatchQueue.main.async { [weak self] in self?.measure() }
    }

    private func measure() {
        guard let window else { return }
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 840
        let hostHeight = window.sheetParent?.contentLayoutRect.height ?? screenHeight
        updateHeight?(max(252, min(720, screenHeight - 120, hostHeight - 48)))
    }

}

// The immutable token can be released from a nonisolated deinit; removal is thread safe.
private final class SettingsEditorResizeObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
