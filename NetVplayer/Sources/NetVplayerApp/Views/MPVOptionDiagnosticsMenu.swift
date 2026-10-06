import SwiftUI
import Models
import PlayerEngine

struct MPVOptionDiagnosticsMenu: View {
    let diagnostics: [MPVOptionDiagnostic]
    var body: some View {
        Menu(L10n.text("播放参数来源")) {
            ForEach(diagnostics) { item in
                Text(item.name + " · " + origin(item.origin)
                     + (item.status == .rejected ? " · " + L10n.text("已忽略") : ""))
            }
        }
    }
    private func origin(_ value: MPVOptionOrigin) -> String {
        switch value {
        case .source: L10n.text("片源建议")
        case .user: L10n.text("界面偏好")
        case .session: L10n.text("当前播放")
        case .transport: L10n.text("传输约束")
        }
    }
}
