// NetVplayerApp/Views/CloudAuthView.swift
// Driver-aware cloud authorization. Share playback starts with Cookie; TV token authorization is optional.

import AppKit
import CoreImage
import SwiftUI
import Models
import Vision
import WebKit
import DriveEngine
import Networking

enum CloudAuthStep: Equatable {
    case tvToken
    case webCookie
    case manualCookie
}

enum CloudAuthStepPolicy {
    static func initialStep(provider: DriveProvider) -> CloudAuthStep {
        provider == .quark || provider == .uc || provider == .ali || provider == .p115 ? .webCookie : .tvToken
    }

    static func nextStep(provider: DriveProvider, completedCredentialKind: CloudCredentialKind, shouldDismiss: Bool) -> CloudAuthStep? {
        guard !shouldDismiss, provider == .quark || provider == .uc else { return nil }
        if completedCredentialKind == .cookie { return nil }
        return .webCookie
    }
}

enum CloudAuthQRCodeProviderPolicy {
    static func supportsLogin(_ provider: DriveProvider) -> Bool {
        provider == .quark || provider == .uc || provider == .baidu
    }
}

enum CloudAuthSettingsPolicy {
    static func supportsPrimaryQRCodeLogin(_ provider: DriveProvider) -> Bool {
        switch provider {
        case .quark, .uc, .ali, .p115, .baidu:
            return true
        default:
            return false
        }
    }
}

enum CloudAuthBaiduQRCodePresentation {
    static func image(from session: BaiduQRCodeSession) -> NSImage? {
        guard let image = NSImage(data: session.qrImageData),
              CloudAuthQRCodeImageInspector.looksLikeQRCode(image) else { return nil }
        return image
    }
}

enum CloudAuthP115WebLoginPolicy {
    static let loginURL = CloudAuthP115QRCodeLoginClient.tokenURL
}

enum CloudAuthQRCodePayloadSignature {
    static func make(_ payload: String) -> String {
        var hasher = Hasher()
        hasher.combine(payload)
        return "\(payload.utf8.count):\(hasher.finalize())"
    }
}

struct CloudAuthView: View {
    enum AuthMode: String, CaseIterable, Identifiable {
        case qr = "扫码 Token"
        case web = "网页扫码"
        case cookie = "粘贴 Cookie"

        var id: String { rawValue }
    }

    let request: CloudAuthRequest
    let onComplete: (CloudCredential) async throws -> CloudAuthCompletion

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appThemePalette) private var palette
    @State private var mode: AuthMode = .qr
    @State private var statusMessage: String?
    @State private var isWorking = false
    @State private var manualCookie = ""
    @State private var qrSession: QuarkTVQRCodeSession?
    @State private var baiduQRSession: BaiduQRCodeSession?
    @State private var pollingTask: Task<Void, Never>?
    @State private var webCookie = ""
    @State private var webLoginReloadID = UUID()
    @State private var ucWebQRImage: NSImage?
    @State private var ucWebLoginServiceTicket: String?
    @State private var ucWebLoginPollTask: Task<Void, Never>?
    @State private var lastUCWebCookieCandidate = ""
    @State private var aliWebQRImage: NSImage?
    @State private var lastAliWebTokenCandidate = ""
    @State private var p115QRSession: CloudAuthP115QRCodeSession?
    @State private var quarkStep = CloudAuthStepPolicy.initialStep(provider: .quark)
    @State private var quarkCookieCompleted = false
    @State private var quarkWebQRImage: NSImage?
    @State private var quarkWebQRReloadID = UUID()
    @State private var quarkWebCookieValidationStarted = false
    @State private var quarkWebLoginTicketURL: URL?
    @State private var quarkWebLoginPollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if request.provider == .quark {
                quarkWizard
                    .padding(18)
                    .frame(minWidth: 560, minHeight: 460)
            } else {
                legacyAuthContent
                    .padding(18)
                    .frame(minWidth: 520, minHeight: 430)
            }

            Divider()
            footer
        }
        .onAppear {
            if !availableModes.contains(mode), let first = availableModes.first {
                mode = first
            }
            if request.provider == .quark {
                refreshQuarkWebQRCode()
            } else if request.provider == .uc {
                mode = CloudAuthStepPolicy.initialStep(provider: .uc) == .webCookie ? .web : .qr
                statusMessage = pendingShareNeedsCookie
                    ? pendingShareCookieMessage
                    : "网页扫码一次保存 UC Cookie；播放时会先请求原文件，失败后才降级。"
            } else if request.provider == .ali {
                mode = .web
                statusMessage = "使用阿里云盘 App 扫码登录，成功后会自动保存 Token。"
                refreshAliWebLogin()
            } else if request.provider == .p115 {
                mode = CloudAuthStepPolicy.initialStep(provider: .p115) == .webCookie ? .web : .cookie
                statusMessage = "请打开 115生活 App，在 App 内使用“扫一扫”登录。"
                refreshP115WebLogin()
            } else if request.provider == .baidu {
                mode = .qr
                statusMessage = "请使用百度网盘 App 扫码，确认后会自动继续当前播放。"
            } else if pendingShareNeedsCookie {
                mode = request.provider == .uc ? .web : .cookie
                statusMessage = pendingShareCookieMessage
            } else if request.pendingEpisodeURL != nil {
                statusMessage = "\(request.provider.displayName) 分享播放会优先使用 Cookie。"
            }
            startQRCodeAuthIfNeeded()
            if request.provider == .uc, mode == .web {
                refreshUCWebLogin()
            }
        }
        .onChange(of: mode) { _, newValue in
            guard request.provider != .quark else { return }
            if newValue == .qr {
                startQRCodeAuthIfNeeded()
            } else if newValue == .web, request.provider == .uc {
                refreshUCWebLogin()
            } else if newValue == .web, request.provider == .ali {
                refreshAliWebLogin()
            } else if newValue == .web, request.provider == .p115 {
                refreshP115WebLogin()
            } else {
                pollingTask?.cancel()
                ucWebLoginPollTask?.cancel()
            }
        }
        .onChange(of: quarkStep) { _, newValue in
            guard request.provider == .quark else { return }
            if newValue == .tvToken {
                quarkWebLoginPollTask?.cancel()
                quarkWebLoginTicketURL = nil
                startQRCodeAuthIfNeeded()
            } else {
                pollingTask?.cancel()
                if newValue != .webCookie {
                    quarkWebLoginPollTask?.cancel()
                    quarkWebLoginTicketURL = nil
                }
            }
        }
        .onDisappear {
            pollingTask?.cancel()
            quarkWebLoginPollTask?.cancel()
            ucWebLoginPollTask?.cancel()
        }
    }

    private var legacyAuthContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $mode) {
                ForEach(availableModes) { mode in
                    Text(authModeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: request.provider == .uc ? 330 : 260)

            if mode == .qr {
                qrPanel
            } else if mode == .web {
                webCookiePanel
            } else {
                cookiePanel
            }
        }
    }

    private var availableModes: [AuthMode] {
        if request.provider == .uc { return [.web, .cookie, .qr] }
        if request.provider == .quark { return [.qr, .cookie] }
        if request.provider == .ali { return [.web, .cookie] }
        if request.provider == .p115 { return [.web, .cookie] }
        if request.provider == .baidu { return [.qr, .cookie] }
        return [.cookie]
    }

    private func authModeTitle(_ mode: AuthMode) -> String {
        if request.provider == .baidu, mode == .qr { return "扫码登录" }
        if request.provider == .p115 {
            return mode == .web ? "扫码登录" : "粘贴 Cookie"
        }
        guard request.provider == .ali else { return mode.rawValue }
        switch mode {
        case .web:
            return "扫码登录"
        case .cookie:
            return "粘贴 Token"
        case .qr:
            return mode.rawValue
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.title2)
                .foregroundStyle(palette.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.provider.displayName) 授权")
                    .font(.headline)
                Text(authSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .padding(16)
    }

    private var authSubtitle: String {
        switch request.provider {
        case .quark:
            return "扫码登录并保存 Cookie，验证成功后自动继续播放。"
        case .uc:
            return "优先用一次网页扫码保存 Cookie；原文件不可用时才降级播放。"
        case .ali:
            return "使用阿里云盘 App 扫码登录，成功后自动保存 Token。"
        case .p115:
            return "请使用 115生活 App 内的“扫一扫”，不要使用微信或系统相机。"
        case .baidu:
            return "使用百度网盘 App 扫码确认，登录成功后自动继续播放。"
        default:
            return "授权信息验证成功后才会保存。"
        }
    }

    private var quarkWizard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                quarkQRCodeCard

                VStack(alignment: .leading, spacing: 12) {
                    Text(quarkStepTitle)
                        .font(.headline)
                    Text(quarkStepDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        if quarkStep == .tvToken {
                            Button {
                                refreshQRCode()
                            } label: {
                                Label("刷新 Token 码", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)

                            Button {
                                showQuarkCookieQRCode()
                            } label: {
                                Label("返回扫码登录", systemImage: "qrcode.viewfinder")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                        } else if quarkStep == .webCookie {
                            Button {
                                refreshQuarkWebQRCode()
                            } label: {
                                Label("刷新二维码", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)

                            Button {
                                quarkStep = .manualCookie
                                statusMessage = "可手动粘贴夸克 Cookie；保存前会先验证。"
                            } label: {
                                Label("无法扫码？", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                        } else {
                            Button {
                                showQuarkCookieQRCode()
                            } label: {
                                Label("返回扫码登录", systemImage: "qrcode.viewfinder")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                        }
                    }

                    if quarkStep == .webCookie {
                        Button {
                            showQuarkTokenAuthorization()
                        } label: {
                            Label("高级 Token 授权", systemImage: "externaldrive.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(isWorking)

                        Text("扫码确认后会自动读取并验证登录凭据。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if quarkStep == .manualCookie {
                cookiePanel
            }

        }
        .background(alignment: .topLeading) {
            if quarkStep == .webCookie, let quarkWebLoginTicketURL {
                CloudCookieQRLoginView(
                    url: quarkWebLoginTicketURL,
                    provider: .quark,
                    reloadID: quarkWebQRReloadID,
                    serviceTicket: nil
                ) { image in
                    if quarkWebQRImage == nil {
                        quarkWebQRImage = image
                    }
                } onCookieSnapshot: { cookie in
                    handleQuarkWebCookieSnapshot(cookie)
                } onCredentialSnapshot: { _ in
                } onError: { message in
                    if quarkWebQRImage == nil {
                        statusMessage = message
                    }
                }
                .frame(width: 420, height: 520)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private var quarkQRCodeCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.35))
                .frame(width: 238, height: 238)

            if let image = currentQuarkQRCodeImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 218, height: 218)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if isWorking || quarkStep == .webCookie {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(quarkStep == .webCookie ? "正在提取二维码" : "正在获取二维码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if quarkStep == .manualCookie {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 62))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 238, height: 238)
    }

    private var currentQuarkQRCodeImage: NSImage? {
        switch quarkStep {
        case .tvToken:
            return qrImage
        case .webCookie:
            return quarkWebQRImage
        case .manualCookie:
            return nil
        }
    }

    private var quarkStepTitle: String {
        switch quarkStep {
        case .tvToken:
            return "可选：授权 QuarkTV Token"
        case .webCookie:
            return "扫码登录夸克"
        case .manualCookie:
            return "手动粘贴夸克 Cookie"
        }
    }

    private var quarkStepDescription: String {
        switch quarkStep {
        case .tvToken:
            return "Token 用于个人网盘和后续 Open API 能力，不是分享播放的必要步骤。保存成功后会返回登录二维码。"
        case .webCookie:
            return "使用夸克 App 扫描并确认登录。成功后即可继续公开分享的播放、转存和下载。"
        case .manualCookie:
            return "如果二维码无法提取，可以粘贴 pan.quark.cn Cookie 作为兜底。"
        }
    }

    private var qrPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.4))
                        .frame(width: 230, height: 230)

                    if let image = qrImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 214, height: 214)
                            .background(.white)
                            .accessibilityLabel("登录二维码")
                            .accessibilityIdentifier("cloud.auth.qrcode")
                    } else if isWorking {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: "qrcode")
                            .font(.system(size: 72))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("使用\(request.provider.displayName) App 扫描二维码，并在手机上确认登录。")
                        .font(.headline)

                    Text(qrTokenDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            refreshQRCode()
                        } label: {
                            Label("刷新二维码", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking)

                        if qrSession != nil || baiduQRSession != nil {
                            Label("等待确认", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !CloudAuthQRCodeProviderPolicy.supportsLogin(request.provider) {
                ContentUnavailableView(
                    "暂不支持扫码 Token",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("\(request.provider.displayName) 的扫码 token driver 尚未接入。")
                )
            }
        }
    }

    @ViewBuilder
    private var webCookiePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(webLoginTitle)
                        .font(.headline)
                    Text(webLoginDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if hasCapturedWebCredential {
                    Label(capturedWebCredentialLabel, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(palette.color(for: .success))
                }
            }

            Group {
                ZStack {
                    if request.provider != .p115 {
                        CloudCookieQRLoginView(
                            url: webLoginURL,
                            provider: request.provider,
                            reloadID: webLoginReloadID,
                            serviceTicket: ucWebLoginServiceTicket
                        ) { image in
                            if request.provider == .ali {
                                aliWebQRImage = image
                                statusMessage = "请使用阿里云盘 App 扫描二维码并确认登录。"
                            } else {
                                ucWebQRImage = image
                                statusMessage = "请使用手机 UC 浏览器扫描二维码并确认登录。"
                            }
                        } onCookieSnapshot: { cookie in
                            if request.provider == .uc {
                                validateUCWebCookieCandidate(cookie)
                            }
                        } onCredentialSnapshot: { token in
                            if request.provider == .ali {
                                validateAliWebTokenCandidate(token)
                            }
                        } onError: { message in
                            if currentWebQRCodeImage == nil {
                                statusMessage = message
                            }
                        }
                        .id(webLoginReloadID)
                        .frame(width: 420, height: 360)
                        .opacity(request.provider == .ali ? 0.001 : 1)
                        .allowsHitTesting(request.provider != .ali)
                        .accessibilityHidden(request.provider == .ali)
                    }

                    if let currentWebQRCodeImage {
                        VStack(spacing: 12) {
                            Image(nsImage: currentWebQRCodeImage)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 250, height: 250)
                            Text(webLoginPrompt)
                                .font(.callout.weight(.semibold))
                            Text(webLoginConfirmationDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    } else if request.provider == .ali {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("正在提取登录二维码")
                                .font(.callout.weight(.semibold))
                            Text("二维码加载完成后会自动显示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
            }
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            )

            HStack {
                Button {
                    if request.provider == .ali {
                        refreshAliWebLogin()
                    } else if request.provider == .p115 {
                        refreshP115WebLogin()
                    } else {
                        refreshUCWebLogin()
                    }
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)

                Button {
                    mode = .cookie
                } label: {
                    Label(request.provider == .ali ? "粘贴 Token" : "手动粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
    }

    private var webLoginTitle: String {
        switch request.provider {
        case .ali: return "阿里云盘扫码登录"
        case .p115: return "115 扫码登录"
        default: return "UC 网页扫码登录"
        }
    }

    private var webLoginDescription: String {
        switch request.provider {
        case .ali:
            return "扫码确认后自动读取阿里云盘登录 Token，并继续当前播放。"
        case .p115:
            return "使用 115生活 App 扫码确认后，自动读取并验证 Cookie。"
        default:
            return "网页登录成功后保存 Cookie，Wogg UC 分享会使用它播放。"
        }
    }

    private var currentWebQRCodeImage: NSImage? {
        switch request.provider {
        case .ali: return aliWebQRImage
        case .p115: return p115QRSession.flatMap { NSImage(data: $0.qrImageData) }
        default: return ucWebQRImage
        }
    }

    private var hasCapturedWebCredential: Bool {
        request.provider == .ali ? !lastAliWebTokenCandidate.isEmpty : !webCookie.isEmpty
    }

    private var capturedWebCredentialLabel: String {
        request.provider == .ali ? "已读取到 Token" : "已读取到 Cookie"
    }

    private var webLoginPrompt: String {
        if request.provider == .ali {
            return isWorking ? "正在保存阿里云盘 Token..." : "请使用阿里云盘 App 扫码"
        }
        if request.provider == .p115 {
            return isWorking ? "正在验证 115 账户..." : "打开 115生活 App → 扫一扫"
        }
        return isWorking ? "正在验证个人盘账户..." : "请使用手机 UC 浏览器扫码"
    }

    private var webLoginConfirmationDescription: String {
        switch request.provider {
        case .ali:
            return "确认登录后将自动保存 Token，无需手动粘贴。"
        case .p115:
            return "请勿使用微信或系统相机；确认登录后将自动继续当前剧集。"
        default:
            return "确认登录后将自动验证并继续转存，无需手动保存。"
        }
    }

    private var cookiePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(manualAuthTitle)
                .font(.headline)

            Text(manualAuthDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField(cookiePlaceholder, text: $manualCookie)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    saveCookie()
                } label: {
                    Label(isWorking ? "保存中..." : manualAuthButtonTitle, systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(manualCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                Button {
                    manualCookie = ""
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(manualCookie.isEmpty || isWorking)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let statusMessage {
                Label(statusMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
    }

    private var qrImage: NSImage? {
        if request.provider == .baidu {
            return baiduQRSession.flatMap(CloudAuthBaiduQRCodePresentation.image)
        }
        guard let qrData = qrSession?.qrData else { return nil }
        let payload: String
        if let comma = qrData.firstIndex(of: ",") {
            payload = String(qrData[qrData.index(after: comma)...])
        } else {
            payload = qrData
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSImage(data: data)
    }

    private var webLoginURL: URL {
        switch request.provider {
        case .uc:
            return URL(string: "https://drive.uc.cn/")!
        case .ali:
            return CloudAuthAliWebLoginPolicy.loginURL
        case .p115:
            return CloudAuthP115WebLoginPolicy.loginURL
        default:
            return URL(string: "https://pan.quark.cn/")!
        }
    }

    private func startQRCodeAuthIfNeeded() {
        let shouldStartQR = request.provider == .quark ? quarkStep == .tvToken : mode == .qr
        guard shouldStartQR,
              (request.provider == .quark || request.provider == .uc || request.provider == .baidu),
              (request.provider == .baidu ? baiduQRSession == nil : qrSession == nil),
              !isWorking else { return }
        refreshQRCode()
    }

    private var cookiePlaceholder: String {
        switch request.provider {
        case .ali:
            return "粘贴 refresh_token，或 access_token/open_token"
        case .p115:
            return "例如：UID=...; CID=...; SEID=..."
        case .pikpak:
            return "粘贴 access_token，或包含 access_token/refresh_token/device_id 的 JSON"
        case .uc:
            return "例如：__puus=...; ...（drive.uc.cn Cookie）"
        case .baidu:
            return "例如：BDUSS=...; STOKEN=..."
        default:
            return "例如：kps=...; __puus=...; puus=..."
        }
    }

    private var pendingShareNeedsCookie: Bool {
        guard let url = request.pendingEpisodeURL else { return false }
        if DriveFileReference.provider(for: url) == request.provider {
            return true
        }

        let lowercasedURL = url.lowercased()
        switch request.provider {
        case .quark:
            return lowercasedURL.contains("pan.quark.cn") || lowercasedURL.hasPrefix("quark://")
        case .uc:
            return lowercasedURL.contains("drive.uc.cn") || lowercasedURL.hasPrefix("uc://")
        case .ali:
            return lowercasedURL.contains("aliyundrive.com") || lowercasedURL.contains("alipan.com") || lowercasedURL.hasPrefix("ali://")
        case .p115:
            return lowercasedURL.contains("115.com") || lowercasedURL.hasPrefix("115://") || lowercasedURL.hasPrefix("p115://")
        case .pikpak:
            return lowercasedURL.contains("mypikpak.com") || lowercasedURL.hasPrefix("pikpak://")
        case .baidu:
            return lowercasedURL.contains("pan.baidu.com") || lowercasedURL.hasPrefix("baidu://")
        default:
            return false
        }
    }

    private var pendingShareCookieMessage: String {
        switch request.provider {
        case .uc:
            return "网页扫码一次保存 UC Cookie；随后会先请求个人盘原文件，失败后才使用智能播放或转码。"
        case .quark:
            return "夸克分享播放需要 Cookie；扫码 Token 仅用于个人网盘登录。"
        case .ali:
            return "阿里云盘分享播放需要 refresh_token / access_token；也可到设置页分别填写。"
        case .p115:
            return "115 分享播放需要 115 Cookie。"
        case .pikpak:
            return "PikPak 播放需要 access_token；也可以在设置页填写 refresh_token/device_id。"
        case .baidu:
            return "百度网盘播放需要账号 Cookie；推荐直接扫码登录。"
        default:
            return "\(request.provider.displayName) 分享播放需要 Cookie。"
        }
    }

    private func refreshAliWebLogin() {
        guard request.provider == .ali else { return }
        aliWebQRImage = nil
        lastAliWebTokenCandidate = ""
        webLoginReloadID = UUID()
        isWorking = false
        statusMessage = "正在加载阿里云盘登录二维码..."
    }

    private func refreshP115WebLogin() {
        guard request.provider == .p115 else { return }
        pollingTask?.cancel()
        p115QRSession = nil
        webCookie = ""
        webLoginReloadID = UUID()
        isWorking = true
        statusMessage = "正在生成 115 客户端登录二维码..."
        DiagnosticLog.write("[P115_AUTH] qrcode_session_started")

        Task {
            do {
                let session = try await CloudAuthP115QRCodeLoginClient().beginSession()
                await MainActor.run {
                    p115QRSession = session
                    isWorking = false
                    statusMessage = "请打开 115生活 App，在 App 内使用“扫一扫”并确认登录。"
                    startP115QRCodePolling(session)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = error.localizedDescription
                    DiagnosticLog.write("[P115_AUTH] qrcode_session_failed")
                }
            }
        }
    }

    private func startP115QRCodePolling(_ session: CloudAuthP115QRCodeSession) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }

                do {
                    switch try await CloudAuthP115QRCodeLoginClient().poll(session) {
                    case .waiting:
                        break
                    case .scanned:
                        await MainActor.run {
                            statusMessage = "二维码已扫描，请在 115生活 App 中确认登录。"
                        }
                    case .credential(let credential):
                        await MainActor.run {
                            isWorking = true
                            webCookie = credential.secret
                            statusMessage = "扫码已确认，正在验证 115 账户..."
                            DiagnosticLog.write("[P115_AUTH] cookie_candidate_captured source=qrcode_api")
                        }
                        await complete(credential)
                        return
                    }
                } catch {
                    await MainActor.run {
                        isWorking = false
                        statusMessage = error.localizedDescription
                        DiagnosticLog.write("[P115_AUTH] qrcode_poll_failed")
                    }
                    return
                }
            }
        }
    }

    private var qrTokenDescription: String {
        switch request.provider {
        case .uc:
            return "可选的 UCTV Token 只用于补充 OpenAPI 原码候选；UC 分享播放仍以 Cookie 为主，不要求第二次扫码。"
        case .quark:
            return "这会保存 QuarkTV 的 refresh/access token；Wogg 夸克分享直链仍需要 Cookie。"
        case .baidu:
            return "扫码确认后保存百度网盘登录 Cookie，用于临时转存并获取原画直链。"
        default:
            return "这会保存 \(request.provider.displayName) TV 的 refresh/access token；分享链接仍会优先使用 Cookie。"
        }
    }

    private func refreshUCWebLogin() {
        guard request.provider == .uc else { return }
        ucWebLoginPollTask?.cancel()
        ucWebLoginServiceTicket = nil
        ucWebQRImage = nil
        webCookie = ""
        lastUCWebCookieCandidate = ""
        webLoginReloadID = UUID()
        isWorking = true
        statusMessage = "正在生成 UC 网盘登录二维码..."

        Task {
            do {
                let session = try await CloudAuthUCWebLoginClient().beginSession()
                await MainActor.run {
                    ucWebQRImage = NSImage(data: session.qrImageData)
                    isWorking = false
                    statusMessage = "请使用手机 UC 浏览器扫描二维码并确认登录。"
                    startUCWebLoginPolling(session)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func startUCWebLoginPolling(_ session: CloudAuthUCWebLoginSession) {
        ucWebLoginPollTask?.cancel()
        ucWebLoginPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }

                do {
                    if let ticket = try await CloudAuthUCWebLoginClient().pollServiceTicket(token: session.token) {
                        await MainActor.run {
                            ucWebLoginServiceTicket = ticket
                            statusMessage = "扫码已确认，正在登录 UC 网盘并验证个人盘账户..."
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        statusMessage = error.localizedDescription
                    }
                    return
                }
            }
        }
    }

    private func refreshQRCode() {
        pollingTask?.cancel()
        qrSession = nil
        baiduQRSession = nil
        isWorking = true
        statusMessage = request.provider == .quark ? "正在获取 Token 二维码..." : "正在获取扫码二维码..."

        Task {
            do {
                if request.provider == .baidu {
                    let session = try await BaiduQRLoginClient().beginSession()
                    guard CloudAuthBaiduQRCodePresentation.image(from: session) != nil else {
                        await MainActor.run {
                            isWorking = false
                            statusMessage = "百度返回的二维码图片无法识别，请刷新重试。"
                        }
                        return
                    }
                    await MainActor.run {
                        baiduQRSession = session
                        isWorking = false
                        statusMessage = "二维码已生成，请用百度网盘 App 扫码并确认登录。"
                        startBaiduPolling(session)
                    }
                    return
                }
                let session = try await QuarkTVDriver(provider: request.provider).beginQRCodeSession()
                await MainActor.run {
                    qrSession = session
                    isWorking = false
                    statusMessage = request.provider == .quark ? "Token 二维码已生成，请用夸克 App 扫码确认。" : "二维码已生成，请用\(request.provider.displayName) App 扫码确认。"
                    startPolling(session)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func startBaiduPolling(_ session: BaiduQRCodeSession) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                do {
                    if let credential = try await BaiduQRLoginClient().poll(session) {
                        await MainActor.run {
                            isWorking = true
                            statusMessage = "扫码已确认，正在验证百度网盘账户..."
                        }
                        await complete(credential)
                        return
                    }
                } catch {
                    await MainActor.run {
                        statusMessage = error.localizedDescription
                    }
                    return
                }
            }
        }
    }

    private func startPolling(_ session: QuarkTVQRCodeSession) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }

                do {
                    if let credential = try await QuarkTVDriver(provider: request.provider).pollQRCodeSession(session) {
                        await MainActor.run {
                            isWorking = true
                            statusMessage = request.provider == .quark ? "Token 扫码已确认，正在验证..." : "扫码已确认，正在验证 Token..."
                        }
                        await complete(credential)
                        return
                    }
                } catch {
                    await MainActor.run {
                        statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func refreshQuarkWebQRCode() {
        quarkWebLoginPollTask?.cancel()
        quarkWebQRImage = nil
        webCookie = ""
        quarkWebCookieValidationStarted = false
        quarkWebLoginTicketURL = nil
        quarkWebQRReloadID = UUID()
        isWorking = true
        statusMessage = "正在生成夸克登录二维码..."

        Task {
            do {
                let session = try await CloudAuthQuarkWebLoginClient().beginSession()
                await MainActor.run {
                    quarkWebQRImage = NSImage(data: session.qrImageData)
                    isWorking = false
                    statusMessage = "二维码已生成，请用夸克 App 扫码确认。"
                    startQuarkWebLoginPolling(session)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    statusMessage = "夸克登录二维码生成失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func showQuarkTokenAuthorization() {
        pollingTask?.cancel()
        qrSession = nil
        quarkStep = .tvToken
        statusMessage = "QuarkTV Token 是可选能力，不影响夸克分享播放。"
    }

    private func showQuarkCookieQRCode() {
        quarkStep = .webCookie
        refreshQuarkWebQRCode()
    }

    private func startQuarkWebLoginPolling(_ session: CloudAuthQuarkWebLoginSession) {
        quarkWebLoginPollTask?.cancel()
        quarkWebLoginPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }

                do {
                    if let ticket = try await CloudAuthQuarkWebLoginClient().pollServiceTicket(token: session.token) {
                        await MainActor.run {
                            quarkWebLoginTicketURL = CloudAuthQuarkWebLoginClient.ticketLoginURL(serviceTicket: ticket)
                            quarkWebQRReloadID = UUID()
                            statusMessage = "扫码已确认，正在读取夸克 Cookie..."
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func saveCookie() {
        let cookie = manualCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else { return }
        isWorking = true
        statusMessage = request.provider == .ali ? "正在保存 Token..." : "正在验证 Cookie..."

        Task {
            if request.provider == .ali {
                await complete(CloudAuthAliCredentialParser.credential(from: cookie))
            } else if request.provider == .p115 {
                await complete(Self.p115Credential(from: cookie))
            } else if request.provider == .pikpak {
                await complete(Self.pikpakCredential(from: cookie))
            } else {
                await complete(.cookie(provider: request.provider, value: cookie))
            }
        }
    }

    private var manualAuthTitle: String {
        switch request.provider {
        case .ali:
            return "粘贴阿里云盘 Token"
        case .pikpak:
            return "粘贴 PikPak Token"
        case .baidu:
            return "粘贴百度网盘 Cookie"
        default:
            return "粘贴 \(request.provider.displayName) Cookie"
        }
    }

    private var manualAuthDescription: String {
        switch request.provider {
        case .ali:
            return "可粘贴 refresh_token，或 access_token/open_token/default_drive_id；保存后在播放时由阿里接口校验。"
        case .p115:
            return "115 分享播放使用 Cookie；Open API access_token 可选，用于转存后的个人文件转码。"
        case .pikpak:
            return "可粘贴 access_token，或包含 access_token/refresh_token/device_id 的 JSON；保存后在播放时校验。"
        case .baidu:
            return "推荐使用扫码登录；手动粘贴时至少需要有效的 BDUSS，保存前会验证个人盘账户。"
        default:
            return "\(request.provider.displayName) 分享播放优先使用 Cookie。保存前会调用网盘接口验证，验证失败不会写入。"
        }
    }

    private var manualAuthButtonTitle: String {
        request.provider == .ali || request.provider == .pikpak ? "保存" : "验证并保存"
    }

    private static func p115Credential(from value: String) -> CloudCredential {
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let cookie = object["cookie"] ?? object["Cookie"] ?? object["p115Cookie"] ?? value
            var metadata: [String: String] = [:]
            if let accessToken = object["access_token"] ?? object["accessToken"], !accessToken.isEmpty {
                metadata["access_token"] = accessToken
            }
            return CloudCredential(provider: .p115, kind: .cookie, secret: cookie, metadata: metadata)
        }
        return .cookie(provider: .p115, value: value)
    }

    private static func pikpakCredential(from value: String) -> CloudCredential {
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let accessToken = object["access_token"] ?? object["accessToken"] ?? ""
            let refreshToken = object["refresh_token"] ?? object["refreshToken"] ?? ""
            let deviceID = object["device_id"] ?? object["deviceID"] ?? ""
            var metadata: [String: String] = [:]
            if !accessToken.isEmpty { metadata["access_token"] = accessToken }
            if !refreshToken.isEmpty { metadata["refresh_token"] = refreshToken }
            if !deviceID.isEmpty { metadata["device_id"] = deviceID }
            return CloudCredential(
                provider: .pikpak,
                kind: accessToken.isEmpty ? .refreshToken : .accessToken,
                secret: accessToken,
                refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                accessToken: accessToken.isEmpty ? nil : accessToken,
                deviceID: deviceID.isEmpty ? nil : deviceID,
                metadata: metadata
            )
        }
        return CloudCredential(provider: .pikpak, kind: .accessToken, secret: value, accessToken: value)
    }

    private func validateUCWebCookieCandidate(_ cookie: String) {
        let normalized = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.provider == .uc,
              CloudAuthCookieFormatter.containsLikelyAuthCookie(normalized, provider: .uc),
              normalized != lastUCWebCookieCandidate,
              !isWorking else { return }

        lastUCWebCookieCandidate = normalized
        isWorking = true
        statusMessage = "检测到 UC 登录信息，正在验证个人盘账户..."

        Task {
            do {
                let result = try await onComplete(.cookie(provider: .uc, value: normalized))
                await MainActor.run {
                    isWorking = false
                    webCookie = normalized
                    statusMessage = result.message
                    if result.shouldDismiss {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    webCookie = ""
                    if CloudAuthCookieValidationPolicy.isGuestLoginError(error.localizedDescription) {
                        statusMessage = "当前仍是 UC 访客状态，请扫描二维码并在手机上确认登录。"
                    } else {
                        statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func validateAliWebTokenCandidate(_ token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.provider == .ali,
              !normalized.isEmpty,
              normalized != lastAliWebTokenCandidate,
              !isWorking else { return }

        let credential = CloudAuthAliCredentialParser.credential(from: normalized)
        guard credential.refreshToken?.isEmpty == false || credential.accessToken?.isEmpty == false else {
            statusMessage = "阿里云盘登录成功，但未读取到可用 Token，请刷新二维码重试。"
            return
        }

        lastAliWebTokenCandidate = normalized
        isWorking = true
        statusMessage = "扫码已确认，正在保存阿里云盘 Token..."

        Task {
            await complete(credential)
        }
    }

    private func handleQuarkWebCookieSnapshot(_ cookie: String) {
        let normalized = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isWorking, !quarkCookieCompleted, !quarkWebCookieValidationStarted else { return }
        guard CloudAuthCookieFormatter.containsLikelyAuthCookie(normalized, provider: .quark) else { return }
        webCookie = normalized
        quarkWebCookieValidationStarted = true
        isWorking = true
        statusMessage = "已读取到夸克 Cookie，正在验证..."

        Task {
            await complete(.cookie(provider: .quark, value: normalized))
        }
    }

    private func complete(_ credential: CloudCredential) async {
        do {
            let result = try await onComplete(credential)
            await MainActor.run {
                isWorking = false
                statusMessage = result.message
                if request.provider == .quark {
                    if credential.kind == .cookie {
                        quarkCookieCompleted = true
                        quarkWebLoginPollTask?.cancel()
                    }
                    if let nextStep = CloudAuthStepPolicy.nextStep(
                        provider: credential.provider,
                        completedCredentialKind: credential.kind,
                        shouldDismiss: result.shouldDismiss
                    ) {
                        quarkStep = nextStep
                        if nextStep == .webCookie {
                            refreshQuarkWebQRCode()
                        }
                    } else if !result.shouldDismiss {
                        quarkStep = .manualCookie
                    }
                } else if let nextStep = CloudAuthStepPolicy.nextStep(
                    provider: credential.provider,
                    completedCredentialKind: credential.kind,
                    shouldDismiss: result.shouldDismiss
                ) {
                    mode = nextStep == .webCookie ? .web : .cookie
                } else if !result.shouldDismiss {
                    mode = .cookie
                }
            }
            if result.shouldDismiss {
                await MainActor.run {
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                isWorking = false
                statusMessage = error.localizedDescription
                if request.provider == .quark {
                    if credential.kind != .cookie {
                        quarkStep = .tvToken
                    } else {
                        quarkWebCookieValidationStarted = false
                        quarkStep = quarkStep == .manualCookie ? .manualCookie : .webCookie
                    }
                } else if credential.kind != .cookie {
                    mode = request.provider == .uc ? .web : .cookie
                }
            }
        }
    }
}

enum CloudAuthAliCredentialParser {
    static func credential(from value: String) -> CloudCredential {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CloudCredential(provider: .ali, kind: .accessToken, secret: normalized, accessToken: normalized)
        }

        let refreshToken = stringValue(in: object, keys: ["refresh_token", "refreshToken"])
        let accessToken = stringValue(in: object, keys: ["access_token", "accessToken"])
        let openToken = stringValue(in: object, keys: ["open_token", "openToken"])
        let defaultDriveID = stringValue(in: object, keys: ["default_drive_id", "defaultDriveId", "drive_id", "driveId"])

        var metadata: [String: String] = [:]
        if !openToken.isEmpty { metadata["open_token"] = openToken }
        if !defaultDriveID.isEmpty { metadata["default_drive_id"] = defaultDriveID }
        if !refreshToken.isEmpty { metadata["refresh_token"] = refreshToken }
        if !accessToken.isEmpty { metadata["access_token"] = accessToken }

        let secret = [accessToken, openToken, refreshToken].first { !$0.isEmpty } ?? normalized
        return CloudCredential(
            provider: .ali,
            kind: refreshToken.isEmpty ? .accessToken : .refreshToken,
            secret: secret,
            refreshToken: refreshToken.isEmpty ? nil : refreshToken,
            accessToken: accessToken.isEmpty ? nil : accessToken,
            metadata: metadata
        )
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { return normalized }
            }
        }
        return ""
    }
}

enum CloudAuthAliWebLoginPolicy {
    static let loginURL = URL(string: "https://www.alipan.com/sign/in")!

    static func acceptsCredentialMessage(frameURL: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame,
              frameURL?.scheme?.lowercased() == "https",
              let host = frameURL?.host?.lowercased() else { return false }
        return host == "alipan.com"
            || host.hasSuffix(".alipan.com")
            || host == "aliyundrive.com"
            || host.hasSuffix(".aliyundrive.com")
    }
}

private struct CloudCookieQRLoginView: NSViewRepresentable {
    @Environment(\.appThemePalette) private var palette
    let url: URL
    let provider: DriveProvider
    let reloadID: UUID
    let serviceTicket: String?
    let onQRCode: (NSImage) -> Void
    let onCookieSnapshot: (String) -> Void
    let onCredentialSnapshot: (String) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> QRWebContainerView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = provider == .ali ? .nonPersistent() : .default()
        let userScript = WKUserScript(
            source: Self.qrObserverScript(provider: provider),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.addUserScript(
            AppWebScrollbarStyle.userScript(for: .standard, palette: palette)
        )
        configuration.userContentController.add(context.coordinator, name: "qrObserver")

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 520), configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

        let container = QRWebContainerView(webView: webView)
        context.coordinator.webView = webView
        context.coordinator.load(url: url)
        return container
    }

    func updateNSView(_ nsView: QRWebContainerView, context: Context) {
        AppWebScrollbarStyle.apply(theme: .standard, palette: palette, to: nsView.webView)
        if context.coordinator.reloadID != reloadID {
            context.coordinator.reloadID = reloadID
            context.coordinator.load(url: url)
        }
        if let serviceTicket {
            context.coordinator.deliverServiceTicket(serviceTicket)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            provider: provider,
            reloadID: reloadID,
            serviceTicket: serviceTicket,
            onQRCode: onQRCode,
            onCookieSnapshot: onCookieSnapshot,
            onCredentialSnapshot: onCredentialSnapshot,
            onError: onError
        )
    }

    static func dismantleNSView(_ nsView: QRWebContainerView, coordinator: Coordinator) {
        nsView.webView.configuration.userContentController.removeScriptMessageHandler(forName: "qrObserver")
        coordinator.cookieObserver = nil
        nsView.webView.navigationDelegate = nil
    }

    final class QRWebContainerView: NSView {
        let webView: WKWebView

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            addSubview(webView)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func layout() {
            super.layout()
            webView.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 420), height: max(bounds.height, 520))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
        let provider: DriveProvider
        var reloadID: UUID
        weak var webView: WKWebView?
        private let onQRCode: (NSImage) -> Void
        private let onCookieSnapshot: (String) -> Void
        private let onCredentialSnapshot: (String) -> Void
        private let onError: (String) -> Void
        private var lastQRSignature = ""
        private var isSnapshottingQRCode = false
        private var pendingServiceTicket: String?
        private var deliveredServiceTicket: String?
        fileprivate var cookieObserver: Coordinator?

        init(
            provider: DriveProvider,
            reloadID: UUID,
            serviceTicket: String?,
            onQRCode: @escaping (NSImage) -> Void,
            onCookieSnapshot: @escaping (String) -> Void,
            onCredentialSnapshot: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.provider = provider
            self.reloadID = reloadID
            self.pendingServiceTicket = serviceTicket
            self.onQRCode = onQRCode
            self.onCookieSnapshot = onCookieSnapshot
            self.onCredentialSnapshot = onCredentialSnapshot
            self.onError = onError
            super.init()
            self.cookieObserver = self
        }

        func load(url: URL) {
            lastQRSignature = ""
            isSnapshottingQRCode = false
            deliveredServiceTicket = nil
            webView?.configuration.websiteDataStore.httpCookieStore.add(self)
            guard let webView else { return }
            guard provider == .uc || provider == .p115 else {
                webView.load(URLRequest(url: url))
                return
            }

            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            cookieStore.getAllCookies { cookies in
                let providerCookies = cookies.filter { cookie in
                    CloudAuthCookieFormatter.cookieBelongsToProvider(cookie, provider: self.provider)
                }
                let group = DispatchGroup()
                for cookie in providerCookies {
                    group.enter()
                    cookieStore.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    webView.load(URLRequest(url: url))
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            captureCookies(from: webView)
            requestQRCodeExtraction(from: webView)
            scheduleAliQRCodeSnapshots(from: webView)
            if let pendingServiceTicket {
                deliverServiceTicket(pendingServiceTicket)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            captureCookies(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError("\(provider.displayName) 登录页加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError("\(provider.displayName) 登录页加载失败：\(error.localizedDescription)")
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard let webView else { return }
            captureCookies(from: webView)
        }

        func deliverServiceTicket(_ ticket: String) {
            pendingServiceTicket = ticket
            guard deliveredServiceTicket != ticket,
                  let webView,
                  webView.url?.host?.lowercased() == "drive.uc.cn",
                  let data = try? JSONEncoder().encode(ticket),
                  let literal = String(data: data, encoding: .utf8) else { return }
            deliveredServiceTicket = ticket
            let script = """
            (function() {
              var frame = document.querySelector('iframe[src*="broccoli.uc.cn"]');
              if (!frame || !frame.contentWindow) return false;
              frame.contentWindow.postMessage({ __netvplayerServiceTicket: \(literal) }, 'https://broccoli.uc.cn');
              return true;
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error {
                    self?.deliveredServiceTicket = nil
                    self?.onError("UC 登录确认失败：\(error.localizedDescription)")
                } else if (result as? Bool) != true {
                    self?.deliveredServiceTicket = nil
                    self?.onError("UC 登录确认失败：登录页面尚未准备好，请刷新二维码重试。")
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "qrObserver" else { return }
            let dict = message.body as? [String: Any]
            if let credential = dict?["credential"] as? String, !credential.isEmpty {
                guard provider == .ali,
                      CloudAuthAliWebLoginPolicy.acceptsCredentialMessage(
                        frameURL: message.frameInfo.request.url,
                        isMainFrame: message.frameInfo.isMainFrame
                      ) else { return }
                DispatchQueue.main.async { [onCredentialSnapshot] in
                    onCredentialSnapshot(credential)
                }
                return
            }
            let relaySourceHost = dict?["sourceHost"] as? String
            let isTrustedRelay = CloudAuthQRCodeChannelPolicy.acceptsQRCodeRelay(
                provider: provider,
                frameURL: message.frameInfo.request.url,
                sourceHost: relaySourceHost,
                isMainFrame: message.frameInfo.isMainFrame
            )
            guard CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
                provider: provider,
                url: message.frameInfo.request.url
            ) || isTrustedRelay else { return }
            if let string = message.body as? String {
                handleQRPayload(string)
            } else if let dict {
                if let dataURL = dict["dataURL"] as? String, !dataURL.isEmpty {
                    handleQRPayload(dataURL)
                } else if let imageURL = dict["imageURL"] as? String, !imageURL.isEmpty {
                    loadQRCodeImage(from: imageURL)
                } else if let rect = dict["rect"] as? [String: Any] {
                    guard CloudAuthQRCodeChannelPolicy.acceptsRectangleSnapshot(
                        provider: provider,
                        isTrustedRelay: isTrustedRelay
                    ) else { return }
                    snapshotQRCode(rect: rect)
                }
            }
        }

        private func requestQRCodeExtraction(from webView: WKWebView) {
            guard provider != .uc else { return }
            webView.evaluateJavaScript("window.__netvplayerExtractQRCode && window.__netvplayerExtractQRCode();") { [weak self] result, error in
                if let string = result as? String {
                    self?.handleQRPayload(string)
                } else if let error {
                    self?.onError("暂未提取到登录二维码：\(error.localizedDescription)")
                }
            }
        }

        private func scheduleAliQRCodeSnapshots(from webView: WKWebView) {
            guard provider == .ali else { return }
            let expectedReloadID = reloadID
            for delay in [0.35, 0.8, 1.5, 2.5, 4.0, 6.0, 10.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView,
                          self.reloadID == expectedReloadID,
                          self.lastQRSignature.isEmpty else { return }
                    self.snapshotVisibleQRCode(from: webView)
                }
            }
        }

        private func snapshotVisibleQRCode(from webView: WKWebView) {
            guard !isSnapshottingQRCode, !webView.bounds.isEmpty else { return }
            isSnapshottingQRCode = true
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self else { return }
                self.isSnapshottingQRCode = false
                guard self.lastQRSignature.isEmpty,
                      let image,
                      let qrImage = CloudAuthQRCodeSnapshotExtractor.qrCode(from: image) else { return }
                self.lastQRSignature = "visible-webview-snapshot"
                DispatchQueue.main.async { [onQRCode = self.onQRCode] in
                    onQRCode(qrImage)
                }
            }
        }

        private func handleQRPayload(_ payload: String) {
            guard let image = CloudAuthQRCodeImageDecoder.image(from: payload) else { return }
            guard CloudAuthQRCodeImageInspector.looksLikeQRCode(image) else { return }
            let signature = CloudAuthQRCodePayloadSignature.make(payload)
            guard signature != lastQRSignature else { return }
            lastQRSignature = signature
            DispatchQueue.main.async { [onQRCode] in
                onQRCode(image)
            }
        }

        private func loadQRCodeImage(from urlString: String) {
            guard let url = URL(string: urlString), url.scheme?.lowercased() == "https", let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                let headers = HTTPCookie.requestHeaderFields(with: cookies)
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.setValue(webView.customUserAgent, forHTTPHeaderField: "User-Agent")
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    guard let data, let image = NSImage(data: data),
                          CloudAuthQRCodeImageInspector.looksLikeQRCode(image) else { return }
                    DispatchQueue.main.async {
                        self?.onQRCode(image)
                    }
                }.resume()
            }
        }

        private func snapshotQRCode(rect: [String: Any]) {
            guard let webView else { return }
            let x = CGFloat((rect["x"] as? Double) ?? 0)
            let y = CGFloat((rect["y"] as? Double) ?? 0)
            let width = CGFloat((rect["width"] as? Double) ?? 0)
            let height = CGFloat((rect["height"] as? Double) ?? 0)
            let shorterSide = min(width, height)
            let longerSide = max(width, height)
            guard shorterSide >= 96,
                  longerSide <= 360,
                  shorterSide / max(longerSide, 1) >= 0.72 else { return }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -8, dy: -8)
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let image,
                      CloudAuthQRCodeImageInspector.looksLikeQRCode(image) else { return }
                DispatchQueue.main.async {
                    self?.onQRCode(image)
                }
            }
        }

        private func captureCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [provider, onCookieSnapshot] cookies in
                let cookieString = CloudAuthCookieFormatter.cookieString(from: cookies, provider: provider)
                guard CloudAuthCookieFormatter.containsLikelyAuthCookie(cookieString, provider: provider) else { return }
                DispatchQueue.main.async {
                    onCookieSnapshot(cookieString)
                }
            }
        }
    }

    private static func qrObserverScript(provider: DriveProvider) -> String {
        let preferredPattern = CloudAuthQRCodeChannelPolicy.preferredScanPattern(for: provider)
            .map { "/\($0)/i" } ?? "null"
        let ignoredFrameGuard = CloudAuthQRCodeChannelPolicy.ignoredFramePathFragment(for: provider)
            .map { "if (window.location.pathname.toLowerCase().indexOf('\($0)') >= 0) { return; }" } ?? ""
        let preferredFrameHost = CloudAuthQRCodeChannelPolicy.preferredQRCodeFrameHost(for: provider)
            .map { "'\($0)'" } ?? "null"
        let preferredQRCodeSelector = CloudAuthQRCodeChannelPolicy.preferredQRCodeSelector(for: provider)
            .map { "'\($0)'" } ?? "null"
        let allowsAutomaticLoginSurfaceActivation = CloudAuthQRCodeChannelPolicy
            .allowsAutomaticLoginSurfaceActivation(for: provider) ? "true" : "false"
        let observesAliCredential = provider == .ali ? "true" : "false"

        return """
    (function() {
      \(ignoredFrameGuard)
      var clickedControls = {};
      var preferredScanPattern = \(preferredPattern);
      var preferredFrameHost = \(preferredFrameHost);
      var preferredQRCodeSelector = \(preferredQRCodeSelector);
      var allowsAutomaticLoginSurfaceActivation = \(allowsAutomaticLoginSurfaceActivation);
      var observesAliCredential = \(observesAliCredential);
      var lastCredential = '';

      function reportAliCredential() {
        if (!observesAliCredential || window.top !== window) return;
        var value = '';
        try { value = window.localStorage.getItem('token') || ''; } catch (e) {}
        if (!value) {
          try { value = window.sessionStorage.getItem('token') || ''; } catch (e) {}
        }
        if (!value || value === '{}' || value === lastCredential) return;
        lastCredential = value;
        window.webkit.messageHandlers.qrObserver.postMessage({ credential: value });
      }

      if (window.location.hostname.toLowerCase() === preferredFrameHost) {
        window.addEventListener('message', function(event) {
          if (event.origin !== 'https://drive.uc.cn') return;
          var ticket = event.data && event.data.__netvplayerServiceTicket;
          if (typeof ticket !== 'string' || !ticket) return;
          window.top.postMessage(ticket, 'https://drive.uc.cn');
        });
      }

      if (window.top === window && preferredFrameHost) {
        window.addEventListener('message', function(event) {
          if (event.origin !== 'https://' + preferredFrameHost) return;
          var payload = event.data && event.data.__netvplayerQRCodeRect;
          if (!payload) return;
          var frames = Array.prototype.slice.call(document.querySelectorAll('iframe'));
          var sourceFrame = null;
          for (var frameIndex = 0; frameIndex < frames.length; frameIndex++) {
            try {
              if (frames[frameIndex].contentWindow === event.source) {
                sourceFrame = frames[frameIndex];
                break;
              }
            } catch (e) {}
          }
          if (!sourceFrame) return;
          sourceFrame.scrollIntoView({ behavior: 'auto', block: 'center', inline: 'center' });
          setTimeout(function() {
            var frameRect = sourceFrame.getBoundingClientRect();
            var scaleX = frameRect.width / Math.max(sourceFrame.clientWidth || frameRect.width, 1);
            var scaleY = frameRect.height / Math.max(sourceFrame.clientHeight || frameRect.height, 1);
            window.webkit.messageHandlers.qrObserver.postMessage({
              sourceHost: preferredFrameHost,
              rect: {
                x: frameRect.x + payload.x * scaleX,
                y: frameRect.y + payload.y * scaleY,
                width: payload.width * scaleX,
                height: payload.height * scaleY
              }
            });
          }, 80);
        });
      }

      function focusPreferredFrame() {
        if (!preferredFrameHost || window.location.hostname.toLowerCase() === preferredFrameHost) return false;
        return !!document.querySelector('iframe[src*="' + preferredFrameHost + '"]');
      }

      function textFor(node) {
        var className = '';
        try {
          className = (node.className && node.className.baseVal) || node.className || '';
        } catch (e) {}
        return [
          node.innerText || '',
          node.textContent || '',
          node.alt || '',
          node.title || '',
          node.getAttribute && node.getAttribute('aria-label') || '',
          node.id || '',
          className,
          node.src || ''
        ].join(' ').toLowerCase();
      }

      function isVisible(node) {
        if (!node || !node.getBoundingClientRect) return false;
        var rect = node.getBoundingClientRect();
        if (rect.width < 1 || rect.height < 1) return false;
        var style = window.getComputedStyle ? window.getComputedStyle(node) : null;
        return !style || (style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity || '1') > 0);
      }

      function activateLoginSurface() {
        var nodes = Array.prototype.slice.call(document.querySelectorAll(
          'button,a,[role="button"],[class*="login"],[id*="login"],[class*="qr"],[id*="qr"],[class*="code"],[id*="code"]'
        ));
        if (preferredScanPattern) {
          var preferredNodes = Array.prototype.slice.call(document.querySelectorAll(
            'button,a,[role="button"],div,span,li'
          )).filter(function(node) {
            return isVisible(node) && preferredScanPattern.test(textFor(node));
          }).sort(function(lhs, rhs) {
            return textFor(lhs).length - textFor(rhs).length;
          });
          for (var preferredIndex = 0; preferredIndex < preferredNodes.length; preferredIndex++) {
            var preferredNode = preferredNodes[preferredIndex];
            try {
              preferredNode.click();
              return true;
            } catch (e) {}
          }
        }
        var patterns = [/扫码|二维码|扫一扫|qr|qrcode/, /登录|登陆|login|sign in/];
        for (var p = 0; p < patterns.length; p++) {
          for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            var label = textFor(node);
            if (!patterns[p].test(label) || !isVisible(node)) continue;
            var key = p + ':' + label.slice(0, 80);
            if (clickedControls[key]) continue;
            clickedControls[key] = true;
            try {
              node.click();
              return true;
            } catch (e) {}
          }
        }
        return false;
      }

      function rectPayload(node) {
        var rect = node.getBoundingClientRect();
        return { rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
      }

      function isQRCodeRect(rect) {
        var shorter = Math.min(rect.width || 0, rect.height || 0);
        var longer = Math.max(rect.width || 0, rect.height || 0);
        return shorter >= 96 && longer <= 360 && shorter / Math.max(longer, 1) >= 0.72;
      }

      function candidateElements() {
        if (preferredQRCodeSelector) {
          var preferredNodes = Array.prototype.slice.call(document.querySelectorAll(preferredQRCodeSelector)).filter(function(node) {
            return isVisible(node) && isQRCodeRect(node.getBoundingClientRect());
          });
          if (preferredNodes.length) return preferredNodes;
        }
        var nodes = Array.prototype.slice.call(document.querySelectorAll(
          'canvas,img,svg,[style*="background"],[class*="qr"],[id*="qr"],[class*="code"],[id*="code"]'
        ));
        return nodes.filter(function(node) {
          var rect = node.getBoundingClientRect();
          var text = textFor(node);
          return isVisible(node) && (isQRCodeRect(rect) || text.indexOf('qr') >= 0 || text.indexOf('qrcode') >= 0 || text.indexOf('code') >= 0);
        });
      }

      window.__netvplayerExtractQRCode = function() {
        var hasPreferredFrame = focusPreferredFrame();
        var nodes = candidateElements();
        if (!nodes.length && !hasPreferredFrame && allowsAutomaticLoginSurfaceActivation && activateLoginSurface()) {
          setTimeout(function() {
            try { window.__netvplayerExtractQRCode(); } catch (e) {}
          }, 500);
          return '';
        }
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          try {
            var rect = node.getBoundingClientRect();
            if (node.tagName && node.tagName.toLowerCase() === 'canvas') {
              try {
                var canvasData = node.toDataURL('image/png');
                if (canvasData && canvasData.length > 100) {
                  window.webkit.messageHandlers.qrObserver.postMessage(canvasData);
                }
              } catch (canvasError) {}
              if (isQRCodeRect(rect) && window.parent !== window) {
                window.parent.postMessage({
                  __netvplayerQRCodeRect: {
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: rect.height
                  }
                }, '*');
                return '';
              }
            }
            if (node.tagName && node.tagName.toLowerCase() === 'img') {
              var src = node.currentSrc || node.src || '';
              if (src.indexOf('data:image') === 0) {
                window.webkit.messageHandlers.qrObserver.postMessage(src);
                return src;
              }
              try {
                var canvas = document.createElement('canvas');
                canvas.width = Math.max(1, Math.floor(rect.width || node.naturalWidth || node.width || 0));
                canvas.height = Math.max(1, Math.floor(rect.height || node.naturalHeight || node.height || 0));
                var ctx = canvas.getContext('2d');
                ctx.drawImage(node, 0, 0, canvas.width, canvas.height);
                var data = canvas.toDataURL('image/png');
                if (data && data.length > 100) {
                  window.webkit.messageHandlers.qrObserver.postMessage(data);
                  return data;
                }
              } catch (e) {
                if (src.indexOf('https://') === 0) {
                  window.webkit.messageHandlers.qrObserver.postMessage({ imageURL: src });
                  return '';
                }
                window.webkit.messageHandlers.qrObserver.postMessage(rectPayload(node));
              }
            }
            if (node.tagName && node.tagName.toLowerCase() === 'svg') {
              window.webkit.messageHandlers.qrObserver.postMessage(rectPayload(node));
              return '';
            }
            var style = window.getComputedStyle ? window.getComputedStyle(node) : null;
            var background = style && style.backgroundImage || '';
            var match = background.match(/url\\(["']?([^"')]+)["']?\\)/);
            if (match && match[1]) {
              if (match[1].indexOf('data:image') === 0) {
                window.webkit.messageHandlers.qrObserver.postMessage(match[1]);
                return match[1];
              }
              if (match[1].indexOf('https://') === 0) {
                window.webkit.messageHandlers.qrObserver.postMessage({ imageURL: match[1] });
                return '';
              }
            }
            if (isQRCodeRect(rect)) {
              window.webkit.messageHandlers.qrObserver.postMessage(rectPayload(node));
              return '';
            }
          } catch (e) {}
        }
        return '';
      };

      var timer = setInterval(function() {
        try { window.__netvplayerExtractQRCode(); } catch (e) {}
        try { reportAliCredential(); } catch (e) {}
      }, 800);
      setTimeout(function() { clearInterval(timer); }, 120000);
      new MutationObserver(function() {
        try { window.__netvplayerExtractQRCode(); } catch (e) {}
        try { reportAliCredential(); } catch (e) {}
      }).observe(document.documentElement || document.body, { childList: true, subtree: true, attributes: true });
      window.addEventListener('storage', function() {
        try { reportAliCredential(); } catch (e) {}
      });
      try { reportAliCredential(); } catch (e) {}
    })();
    """
    }
}

struct CloudAuthQuarkWebLoginSession: Equatable, Sendable {
    let token: String
    let qrURL: URL
    let qrImageData: Data
}

enum CloudAuthQuarkWebLoginError: LocalizedError {
    case invalidResponse
    case missingToken
    case missingQRCode

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "夸克网页登录接口返回异常。"
        case .missingToken:
            return "夸克网页登录接口未返回扫码 Token。"
        case .missingQRCode:
            return "无法生成夸克网页登录二维码。"
        }
    }
}

struct CloudAuthQuarkWebLoginClient {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func beginSession() async throws -> CloudAuthQuarkWebLoginSession {
        let requestID = UUID().uuidString
        let response = try await httpClient.get(
            url: Self.tokenAPIURL(requestID: requestID).absoluteString,
            headers: Self.webLoginHeaders,
            timeout: 12,
            allowsProxyFallback: false
        )
        guard response.statusCode == 200,
              let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let status = payload["status"] as? Int,
              status == 2_000_000 else {
            throw CloudAuthQuarkWebLoginError.invalidResponse
        }

        let data = payload["data"] as? [String: Any]
        let members = data?["members"] as? [String: Any]
        guard let token = members?["token"] as? String, !token.isEmpty else {
            throw CloudAuthQuarkWebLoginError.missingToken
        }

        let qrURL = Self.qrLoginURL(token: token)
        guard let qrImageData = CloudAuthQRCodeImageFactory.imageData(from: qrURL.absoluteString) else {
            throw CloudAuthQuarkWebLoginError.missingQRCode
        }

        return CloudAuthQuarkWebLoginSession(token: token, qrURL: qrURL, qrImageData: qrImageData)
    }

    func pollServiceTicket(token: String) async throws -> String? {
        let requestID = UUID().uuidString
        let response = try await httpClient.get(
            url: Self.serviceTicketAPIURL(token: token, requestID: requestID).absoluteString,
            headers: Self.webLoginHeaders,
            timeout: 12,
            allowsProxyFallback: false
        )
        guard response.statusCode == 200,
              let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw CloudAuthQuarkWebLoginError.invalidResponse
        }

        let status = payload["status"] as? Int
        guard status == 2_000_000 else { return nil }
        let data = payload["data"] as? [String: Any]
        let members = data?["members"] as? [String: Any]
        return members?["service_ticket"] as? String
    }

    static func tokenAPIURL(requestID: String) -> URL {
        apiURL(
            path: "getTokenForQrcodeLogin",
            queryItems: [URLQueryItem(name: "request_id", value: requestID)]
        )
    }

    static func serviceTicketAPIURL(token: String, requestID: String) -> URL {
        apiURL(
            path: "getServiceTicketByQrcodeToken",
            queryItems: [
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "request_id", value: requestID)
            ]
        )
    }

    static func qrLoginURL(token: String) -> URL {
        var components = URLComponents(string: "https://su.quark.cn/4_eMHBJ")!
        components.percentEncodedQuery = [
            ("token", token),
            ("client_id", "532"),
            ("ssb", "weblogin"),
            ("uc_param_str", ""),
            ("uc_biz_str", "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0")
        ]
        .map { name, value in
            "\(Self.percentEncodeQueryValue(name))=\(Self.percentEncodeQueryValue(value))"
        }
        .joined(separator: "&")
        return components.url!
    }

    static let webLoginHeaders: [String: String] = [
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        "Referer": "https://pan.quark.cn/"
    ]

    private static func apiURL(path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://uop.quark.cn/cas/ajax/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "532"),
            URLQueryItem(name: "v", value: "1.2")
        ] + queryItems
        return components.url!
    }

    static func ticketLoginURL(serviceTicket: String) -> URL {
        var components = URLComponents(string: "https://pan.quark.cn/account/info")!
        components.queryItems = [URLQueryItem(name: "st", value: serviceTicket)]
        return components.url!
    }

    private static func percentEncodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .quarkWebLoginQueryAllowed) ?? value
    }
}

struct CloudAuthUCWebLoginSession: Equatable, Sendable {
    let token: String
    let qrURL: URL
    let qrImageData: Data
}

enum CloudAuthUCWebLoginError: LocalizedError {
    case invalidResponse
    case missingToken
    case missingQRCode

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "UC 网页登录接口返回异常。"
        case .missingToken:
            return "UC 网页登录接口未返回扫码 Token。"
        case .missingQRCode:
            return "无法生成 UC 网盘登录二维码。"
        }
    }
}

struct CloudAuthUCWebLoginClient {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func beginSession() async throws -> CloudAuthUCWebLoginSession {
        let response = try await postForm(
            path: "getTokenForQrcodeLogin",
            fields: [:]
        )
        guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              payload["status"] as? Int == 2_000_000 else {
            throw CloudAuthUCWebLoginError.invalidResponse
        }
        let data = payload["data"] as? [String: Any]
        let members = data?["members"] as? [String: Any]
        guard let token = members?["token"] as? String, !token.isEmpty else {
            throw CloudAuthUCWebLoginError.missingToken
        }
        let qrURL = Self.qrLoginURL(token: token)
        guard let qrImageData = CloudAuthQRCodeImageFactory.imageData(from: qrURL.absoluteString) else {
            throw CloudAuthUCWebLoginError.missingQRCode
        }
        return CloudAuthUCWebLoginSession(token: token, qrURL: qrURL, qrImageData: qrImageData)
    }

    func pollServiceTicket(token: String) async throws -> String? {
        let response = try await postForm(
            path: "getServiceTicketByQrcodeToken",
            fields: ["token": token]
        )
        guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let status = payload["status"] as? Int else {
            throw CloudAuthUCWebLoginError.invalidResponse
        }
        if status == 50_004_001 { return nil }
        guard status == 2_000_000 else {
            throw CloudAuthUCWebLoginError.invalidResponse
        }
        let data = payload["data"] as? [String: Any]
        let members = data?["members"] as? [String: Any]
        return members?["service_ticket"] as? String
    }

    static func qrLoginURL(token: String) -> URL {
        var components = URLComponents(string: "https://su.uc.cn/1_n0ZCv")!
        components.percentEncodedQuery = [
            ("uc_param_str", "dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt"),
            ("token", token),
            ("client_id", "381"),
            ("uc_biz_str", "S:custom|C:titlebar_fix")
        ]
        .map { name, value in
            "\(percentEncodeQueryValue(name))=\(percentEncodeQueryValue(value))"
        }
        .joined(separator: "&")
        return components.url!
    }

    private static func percentEncodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .quarkWebLoginQueryAllowed) ?? value
    }

    private func postForm(path: String, fields: [String: String]) async throws -> HTTPResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: "381"),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: String(Int(Date().timeIntervalSince1970 * 1_000)))
        ] + fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = components.percentEncodedQuery?.data(using: .utf8)
        let response = try await httpClient.post(
            url: "https://api.open.uc.cn/cas/ajax/\(path)",
            headers: Self.webLoginHeaders,
            body: body,
            timeout: 12
        )
        guard response.statusCode == 200 else {
            throw CloudAuthUCWebLoginError.invalidResponse
        }
        return response
    }

    static let webLoginHeaders: [String: String] = [
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": "https://broccoli.uc.cn",
        "Referer": "https://broccoli.uc.cn/",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    ]
}

private extension CharacterSet {
    static let quarkWebLoginQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=|")
        return allowed
    }()
}

enum CloudAuthQRCodeImageFactory {
    static func imageData(from string: String) -> Data? {
        image(from: string)?.tiffRepresentation
    }

    static func image(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }

        let scale = 12.0
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = renderedCGImage(transformed, from: transformed.extent) else { return nil }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    static func renderedCGImage(_ image: CIImage, from extent: CGRect) -> CGImage? {
        for useSoftwareRenderer in [false, true] {
            let context = CIContext(options: [.useSoftwareRenderer: useSoftwareRenderer])
            if let rendered = context.createCGImage(image, from: extent) {
                return rendered
            }
        }
        return nil
    }
}

enum CloudAuthQRCodeImageDecoder {
    static func image(from payload: String) -> NSImage? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base64: String
        if let comma = trimmed.firstIndex(of: ",") {
            base64 = String(trimmed[trimmed.index(after: comma)...])
        } else {
            base64 = trimmed
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}

enum CloudAuthQRCodeImageInspector {
    static func looksLikeQRCode(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 80, height >= 80 else { return false }

        let sampleSize = 48
        let bytesPerPixel = 4
        let bytesPerRow = sampleSize * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var darkCount = 0
        var lightCount = 0
        var transitionCount = 0
        var previousRowIsDark: Bool?
        var previousColumnDark = [Bool?](repeating: nil, count: sampleSize)

        for y in 0..<sampleSize {
            previousRowIsDark = nil
            for x in 0..<sampleSize {
                let index = (y * sampleSize + x) * bytesPerPixel
                let red = Int(pixels[index])
                let green = Int(pixels[index + 1])
                let blue = Int(pixels[index + 2])
                let luminance = (red * 299 + green * 587 + blue * 114) / 1000
                let isDark = luminance < 96
                let isLight = luminance > 184
                if isDark { darkCount += 1 }
                if isLight { lightCount += 1 }
                if let previousRowIsDark, previousRowIsDark != isDark {
                    transitionCount += 1
                }
                previousRowIsDark = isDark
                if let previousColumnIsDark = previousColumnDark[x], previousColumnIsDark != isDark {
                    transitionCount += 1
                }
                previousColumnDark[x] = isDark
            }
        }

        let sampleCount = sampleSize * sampleSize
        let darkRatio = Double(darkCount) / Double(sampleCount)
        let lightRatio = Double(lightCount) / Double(sampleCount)
        let transitionRatio = Double(transitionCount) / Double(sampleCount * 2)

        return darkRatio >= 0.08 &&
            darkRatio <= 0.70 &&
            lightRatio >= 0.18 &&
            transitionRatio >= 0.08
    }
}

enum CloudAuthQRCodeSnapshotExtractor {
    static func qrCode(from image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?
                .filter({ $0.symbology == .qr })
                .max(by: { lhs, rhs in
                    lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
                }) else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let bounds = CGRect(
            x: observation.boundingBox.minX * width,
            y: observation.boundingBox.minY * height,
            width: observation.boundingBox.width * width,
            height: observation.boundingBox.height * height
        )
        let padding = max(8, min(bounds.width, bounds.height) * 0.08)
        let cropRect = bounds
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            .integral
        guard cropRect.width > 0, cropRect.height > 0 else { return nil }

        let source = CIImage(cgImage: cgImage)
        let cropped = source.cropped(to: cropRect)
        guard let croppedImage = CloudAuthQRCodeImageFactory.renderedCGImage(
            cropped,
            from: cropRect
        ) else { return nil }
        let scaleX = width / max(image.size.width, 1)
        let scaleY = height / max(image.size.height, 1)
        return NSImage(
            cgImage: croppedImage,
            size: NSSize(
                width: CGFloat(croppedImage.width) / max(scaleX, 1),
                height: CGFloat(croppedImage.height) / max(scaleY, 1)
            )
        )
    }
}

enum CloudAuthCookieFormatter {
    static func cookieString(from cookies: [HTTPCookie], provider: DriveProvider) -> String {
        return cookies
            .filter { cookieBelongsToProvider($0, provider: provider) }
            .sorted { lhs, rhs in
                if lhs.domain == rhs.domain { return lhs.name < rhs.name }
                return lhs.domain < rhs.domain
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func cookieBelongsToProvider(_ cookie: HTTPCookie, provider: DriveProvider) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return cookieDomainTokens(for: provider).contains { domain == $0 || domain.hasSuffix(".\($0)") }
    }

    static func containsLikelyAuthCookie(_ cookieString: String, provider: DriveProvider) -> Bool {
        let cookieNames = Set(
            cookieString
                .split(separator: ";")
                .compactMap { pair in
                    pair
                        .split(separator: "=", maxSplits: 1)
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
        )

        if provider == .p115 {
            return ["uid", "cid", "seid"].allSatisfy(cookieNames.contains)
        }

        let authCookieNames: Set<String>
        switch provider {
        case .quark:
            authCookieNames = ["kps", "__puus", "puus", "__pus"]
        case .uc:
            authCookieNames = ["__puus", "puus", "__pus"]
        case .baidu:
            authCookieNames = ["bduss", "stoken", "ptoken"]
        default:
            authCookieNames = []
        }

        guard !authCookieNames.isEmpty else {
            return !cookieString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return !cookieNames.isDisjoint(with: authCookieNames)
    }

    private static func cookieDomainTokens(for provider: DriveProvider) -> [String] {
        switch provider {
        case .uc:
            return ["uc.cn", "ucweb.com"]
        case .quark:
            return ["quark.cn"]
        case .p115:
            return ["115.com"]
        default:
            return [provider.rawValue]
        }
    }
}

enum CloudAuthCookieValidationPolicy {
    static func isGuestLoginError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("require login") || lower.contains("[guest]") || lower.contains("31001")
    }
}

enum CloudAuthQRCodeChannelPolicy {
    static func preferredScanPattern(for provider: DriveProvider) -> String? {
        switch provider {
        case .uc:
            return "uc\\s*扫码|uc\\s*scan"
        case .ali:
            return "扫码登录|二维码登录|scan\\s*login|qr\\s*login"
        case .p115:
            return "115\\s*扫码|扫码登录|scan\\s*login"
        default:
            return nil
        }
    }

    static func ignoredFramePathFragment(for provider: DriveProvider) -> String? {
        provider == .uc ? "/account/wxlogin" : nil
    }

    static func preferredQRCodeFrameHost(for provider: DriveProvider) -> String? {
        provider == .uc ? "broccoli.uc.cn" : nil
    }

    static func preferredQRCodeSelector(for provider: DriveProvider) -> String? {
        provider == .p115
            ? "#js_login_qrcode_img, #js-code_login_img, .qrcode-login canvas, .login-qrcode canvas"
            : nil
    }

    static func allowsAutomaticLoginSurfaceActivation(for provider: DriveProvider) -> Bool {
        provider != .p115
    }

    static func acceptsQRCodeFrame(provider: DriveProvider, url: URL?) -> Bool {
        if provider == .uc {
            return url?.host?.lowercased() == preferredQRCodeFrameHost(for: provider)
        }
        if provider == .ali {
            guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
            let trustedDomains = ["alipan.com", "aliyundrive.com", "aliyun.com", "alibaba.com", "taobao.com"]
            return trustedDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
        if provider == .p115 {
            guard url?.scheme?.lowercased() == "https", let host = url?.host?.lowercased() else { return false }
            return host == "115.com" || host.hasSuffix(".115.com")
        }
        return true
    }

    static func acceptsQRCodeRelay(
        provider: DriveProvider,
        frameURL: URL?,
        sourceHost: String?,
        isMainFrame: Bool
    ) -> Bool {
        guard provider == .uc else { return false }
        return isMainFrame
            && frameURL?.host?.lowercased() == "drive.uc.cn"
            && sourceHost?.lowercased() == preferredQRCodeFrameHost(for: provider)
    }

    static func acceptsRectangleSnapshot(provider: DriveProvider, isTrustedRelay: Bool = false) -> Bool {
        provider != .uc || isTrustedRelay
    }
}
