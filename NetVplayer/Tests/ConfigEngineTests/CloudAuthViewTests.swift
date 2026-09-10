import AppKit
import Foundation
import Testing
import DriveEngine
import Models
import Networking
@testable import NetVplayerApp

private let qrCodeRenderingAvailable =
    CloudAuthQRCodeImageFactory.image(from: "https://example.com/qr-rendering-probe") != nil

@Test func testCloudAuthCookieFormatterFiltersQuarkCookies() throws {
    let cookies = [
        makeCookie(name: "kps", value: "kps-token", domain: ".pan.quark.cn"),
        makeCookie(name: "__puus", value: "puus-token", domain: ".drive.quark.cn"),
        makeCookie(name: "uc", value: "uc-token", domain: ".drive.uc.cn"),
        makeCookie(name: "other", value: "ignore", domain: ".example.com")
    ]

    let cookieString = CloudAuthCookieFormatter.cookieString(from: cookies, provider: .quark)

    #expect(cookieString.contains("kps=kps-token"))
    #expect(cookieString.contains("__puus=puus-token"))
    #expect(!cookieString.contains("uc=uc-token"))
    #expect(!cookieString.contains("other=ignore"))
}

@Test func testCloudAuthCookieFormatterRequiresLikelyQuarkAuthCookie() {
    #expect(!CloudAuthCookieFormatter.containsLikelyAuthCookie("csrf=token; locale=zh", provider: .quark))
    #expect(CloudAuthCookieFormatter.containsLikelyAuthCookie("csrf=token; kps=session-token", provider: .quark))
    #expect(CloudAuthCookieFormatter.containsLikelyAuthCookie("__puus=session-token", provider: .quark))
}

@Test func testCloudAuthCookieFormatterRequiresLikelyUCAuthCookie() {
    #expect(!CloudAuthCookieFormatter.containsLikelyAuthCookie("csrf=token; locale=zh", provider: .uc))
    #expect(CloudAuthCookieFormatter.containsLikelyAuthCookie("__puus=session-token", provider: .uc))
}

@Test func testCloudAuthCookieFormatterRequiresLikelyBaiduAuthCookie() {
    #expect(!CloudAuthCookieFormatter.containsLikelyAuthCookie("BAIDUID=fixture; locale=zh", provider: .baidu))
    #expect(CloudAuthCookieFormatter.containsLikelyAuthCookie("BDUSS=fixture-session", provider: .baidu))
    #expect(CloudAuthCookieFormatter.containsLikelyAuthCookie("STOKEN=fixture-token", provider: .baidu))
}

@Test func testBaiduQRCodeProviderIsPresentedAsSupported() {
    #expect(CloudAuthQRCodeProviderPolicy.supportsLogin(.baidu))
}

@Test func testSettingsUseQRCodeAsPrimaryAuthorizationWhenSupported() {
    for provider in [DriveProvider.quark, .uc, .ali, .p115, .baidu] {
        #expect(CloudAuthSettingsPolicy.supportsPrimaryQRCodeLogin(provider))
    }
    #expect(!CloudAuthSettingsPolicy.supportsPrimaryQRCodeLogin(.pikpak))
    #expect(!CloudAuthSettingsPolicy.supportsPrimaryQRCodeLogin(.unknown))
}

@Test(.enabled(if: qrCodeRenderingAvailable))
func testBaiduQRCodePresentationAcceptsQRCodeAndRejectsInvalidData() throws {
    let qrImage = try #require(CloudAuthQRCodeImageFactory.image(from: "https://passport.baidu.com/v2/api/qrcode?sign=fixture"))
    let representation = try #require(qrImage.tiffRepresentation)
    let validSession = BaiduQRCodeSession(sign: "valid", gid: "gid", callback: "callback", qrImageData: representation)
    let invalidSession = BaiduQRCodeSession(sign: "invalid", gid: "gid", callback: "callback", qrImageData: Data("not-an-image".utf8))

    #expect(CloudAuthBaiduQRCodePresentation.image(from: validSession) != nil)
    #expect(CloudAuthBaiduQRCodePresentation.image(from: invalidSession) == nil)
}

@Test func testCloudAuthCookieValidationPolicyRecognizesUCGuestState() {
    #expect(CloudAuthCookieValidationPolicy.isGuestLoginError("HTTP 401 / 31001: require login [guest]"))
    #expect(!CloudAuthCookieValidationPolicy.isGuestLoginError("网络连接超时"))
}

@Test func testUCQRCodeChannelPolicyPrefersUCScanAndRejectsWeChatFrame() {
    #expect(CloudAuthQRCodeChannelPolicy.preferredScanPattern(for: .uc)?.contains("uc") == true)
    #expect(CloudAuthQRCodeChannelPolicy.ignoredFramePathFragment(for: .uc) == "/account/wxlogin")
    #expect(CloudAuthQRCodeChannelPolicy.preferredQRCodeFrameHost(for: .uc) == "broccoli.uc.cn")
    #expect(CloudAuthQRCodeChannelPolicy.ignoredFramePathFragment(for: .quark) == nil)
    #expect(CloudAuthQRCodeChannelPolicy.preferredQRCodeFrameHost(for: .quark) == nil)
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .uc,
        url: URL(string: "https://broccoli.uc.cn/apps/login")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .uc,
        url: URL(string: "https://drive.uc.cn/account/wxlogin")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .uc,
        url: URL(string: "https://drive.uc.cn/")
    ))
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .quark,
        url: URL(string: "https://pan.quark.cn/")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsRectangleSnapshot(provider: .uc))
    #expect(CloudAuthQRCodeChannelPolicy.acceptsRectangleSnapshot(provider: .uc, isTrustedRelay: true))
    #expect(CloudAuthQRCodeChannelPolicy.acceptsRectangleSnapshot(provider: .quark))
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeRelay(
        provider: .uc,
        frameURL: URL(string: "https://drive.uc.cn/"),
        sourceHost: "broccoli.uc.cn",
        isMainFrame: true
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeRelay(
        provider: .uc,
        frameURL: URL(string: "https://drive.uc.cn/"),
        sourceHost: "drive.uc.cn",
        isMainFrame: true
    ))
}

@Test func testUCWebLoginQRCodeUsesOfficialUCClient() throws {
    let url = CloudAuthUCWebLoginClient.qrLoginURL(token: "sample-token")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })

    #expect(components.host == "su.uc.cn")
    #expect(components.path == "/1_n0ZCv")
    #expect(query["token"] == "sample-token")
    #expect(query["client_id"] == "381")
    #expect(query["uc_biz_str"] == "S:custom|C:titlebar_fix")
    #expect(url.absoluteString.contains("uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix"))
}

@Test func testQRCodeImageInspectorRejectsBlankImage() {
    let image = makeImage(width: 220, height: 220) { _, _ in
        (red: 255, green: 255, blue: 255, alpha: 255)
    }

    #expect(!CloudAuthQRCodeImageInspector.looksLikeQRCode(image))
}

@Test func testQRCodeImageInspectorAcceptsHighContrastQRLikeImage() {
    let image = makeImage(width: 220, height: 220) { x, y in
        let module = 10
        let isFinderTopLeft = x < 70 && y < 70 && (x < 10 || x >= 60 || y < 10 || y >= 60 || (x >= 25 && x < 45 && y >= 25 && y < 45))
        let isFinderTopRight = x >= 150 && y < 70 && (x < 160 || x >= 210 || y < 10 || y >= 60 || (x >= 175 && x < 195 && y >= 25 && y < 45))
        let isFinderBottomLeft = x < 70 && y >= 150 && (x < 10 || x >= 60 || y < 160 || y >= 210 || (x >= 25 && x < 45 && y >= 175 && y < 195))
        let isPattern = ((x / module) + (y / module)) % 3 == 0
        let isDark = isFinderTopLeft || isFinderTopRight || isFinderBottomLeft || isPattern
        return isDark ? (red: 0, green: 0, blue: 0, alpha: 255) : (red: 255, green: 255, blue: 255, alpha: 255)
    }

    #expect(CloudAuthQRCodeImageInspector.looksLikeQRCode(image))
}

@Test func testQuarkWebLoginQRCodeURLUsesOfficialScanParameters() throws {
    let url = CloudAuthQuarkWebLoginClient.qrLoginURL(token: "token value")
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let queryItems = Dictionary<String, String>(
        uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )

    #expect(url.absoluteString.hasPrefix("https://su.quark.cn/4_eMHBJ"))
    #expect(queryItems["token"] == "token value")
    #expect(queryItems["client_id"] == "532")
    #expect(queryItems["ssb"] == "weblogin")
}

@Test func testQuarkWebLoginQRCodeURLEncodesOfficialBusinessParameters() {
    let url = CloudAuthQuarkWebLoginClient.qrLoginURL(token: "token value")

    #expect(url.absoluteString.contains("token=token%20value"))
    #expect(url.absoluteString.contains("uc_param_str="))
    #expect(url.absoluteString.contains("uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"))
    #expect(!url.absoluteString.contains("uc_biz_str=S:custom"))
    #expect(!url.absoluteString.contains("SAREA@0"))
}

@Test func testQuarkWebLoginAPIURLUsesOfficialDefaultParameters() throws {
    let tokenURL = CloudAuthQuarkWebLoginClient.tokenAPIURL(requestID: "rid")
    let pollURL = CloudAuthQuarkWebLoginClient.serviceTicketAPIURL(token: "token value", requestID: "rid")
    let tokenItems = queryItems(tokenURL)
    let pollItems = queryItems(pollURL)

    #expect(tokenItems["client_id"] == "532")
    #expect(tokenItems["v"] == "1.2")
    #expect(tokenItems["request_id"] == "rid")
    #expect(pollItems["client_id"] == "532")
    #expect(pollItems["v"] == "1.2")
    #expect(pollItems["request_id"] == "rid")
    #expect(pollItems["token"] == "token value")
}

@Test func testQuarkWebLoginHeadersUseOfficialBrowserContext() {
    let headers = CloudAuthQuarkWebLoginClient.webLoginHeaders

    #expect(headers["Accept"] == "application/json, text/plain, */*")
    #expect(headers["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(headers["Referer"] == "https://pan.quark.cn/")
    #expect(headers["User-Agent"]?.contains("Mozilla/5.0") == true)
    #expect(headers["User-Agent"]?.contains("Chrome/126") == true)
}

@Test(.enabled(if: qrCodeRenderingAvailable))
func testQRCodeImageFactoryGeneratesNonBlankImage() throws {
    let image = try #require(CloudAuthQRCodeImageFactory.image(from: "https://su.quark.cn/4_eMHBJ?token=test"))

    #expect(CloudAuthQRCodeImageInspector.looksLikeQRCode(image))
}

@Test(.enabled(if: qrCodeRenderingAvailable))
func testQRCodeSnapshotExtractorCropsQRCodeFromWebViewLikeImage() throws {
    let qrCode = try #require(CloudAuthQRCodeImageFactory.image(from: "https://www.alipan.com/sign/in?token=test"))
    let screenshot = NSImage(size: NSSize(width: 520, height: 360))
    screenshot.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 520, height: 360)).fill()
    NSGraphicsContext.current?.imageInterpolation = .none
    qrCode.draw(in: NSRect(x: 170, y: 70, width: 220, height: 220))
    screenshot.unlockFocus()

    let extracted = try #require(CloudAuthQRCodeSnapshotExtractor.qrCode(from: screenshot))

    #expect(extracted.size.width < screenshot.size.width)
    #expect(extracted.size.height < screenshot.size.height)
    #expect(CloudAuthQRCodeImageInspector.looksLikeQRCode(extracted))
}

@Test func testQuarkAuthStartsWithSingleCookieQRCodeStep() {
    #expect(CloudAuthStepPolicy.initialStep(provider: .quark) == .webCookie)
}

@Test func testUCAuthStartsWithSingleCookieQRCodeStep() {
    #expect(CloudAuthStepPolicy.initialStep(provider: .uc) == .webCookie)
}

@Test func testAliAuthStartsWithWebQRCodeStep() {
    #expect(CloudAuthStepPolicy.initialStep(provider: .ali) == .webCookie)
}

@Test func testP115AuthStartsWithWebQRCodeStep() {
    #expect(CloudAuthStepPolicy.initialStep(provider: .p115) == .webCookie)
}

@Test func testP115WebLoginUsesOfficialQRCodeAPI() {
    let url = CloudAuthP115WebLoginPolicy.loginURL

    #expect(url.scheme == "https")
    #expect(url.host == "qrcodeapi.115.com")
    #expect(url.path == "/api/1.0/web/1.0/token")
}

@Test(.enabled(if: qrCodeRenderingAvailable))
func testP115QRCodeLoginBuildsDedicatedAppScanPayload() throws {
    let qrURL = CloudAuthP115QRCodeLoginClient.qrURL(uid: "fixture-uid")
    let image = try #require(CloudAuthQRCodeImageFactory.image(from: qrURL.absoluteString))

    #expect(qrURL.absoluteString == "https://115.com/scan/dg-fixture-uid")
    #expect(CloudAuthQRCodeImageInspector.looksLikeQRCode(image))
}

@Test(.enabled(if: qrCodeRenderingAvailable))
func testP115QRCodeLoginStatusURLContainsOnlySessionFields() throws {
    let image = try #require(CloudAuthQRCodeImageFactory.image(from: "https://115.com/scan/dg-fixture"))
    let session = CloudAuthP115QRCodeSession(
        uid: "fixture-uid",
        time: "123456",
        sign: "fixture-sign",
        qrURL: CloudAuthP115QRCodeLoginClient.qrURL(uid: "fixture-uid"),
        qrImageData: try #require(image.tiffRepresentation)
    )
    let url = CloudAuthP115QRCodeLoginClient.statusURL(for: session)
    let query = queryItems(url)

    #expect(url.scheme == "https")
    #expect(url.host == "qrcodeapi.115.com")
    #expect(url.path == "/get/status")
    #expect(query == ["uid": "fixture-uid", "time": "123456", "sign": "fixture-sign"])
}

@Test func testP115QRCodeCookieRequiresCompleteLoginFields() {
    let complete = CloudAuthP115QRCodeLoginClient.cookieString(from: [
        "SEID": "seid-value",
        "UID": "uid-value",
        "CID": "cid-value",
        "KID": "kid-value"
    ])
    let partial = CloudAuthP115QRCodeLoginClient.cookieString(from: [
        "UID": "uid-value",
        "CID": "cid-value"
    ])

    #expect(complete == "UID=uid-value; CID=cid-value; SEID=seid-value; KID=kid-value")
    #expect(partial == nil)
}

@Test(.enabled(if: qrCodeRenderingAvailable))
func testP115QRCodeLoginExchangesConfirmedSessionForCookie() async throws {
    P115AuthMockURLProtocol.reset()
    defer { P115AuthMockURLProtocol.reset() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [P115AuthMockURLProtocol.self]
    let client = CloudAuthP115QRCodeLoginClient(
        httpClient: HTTPClient(session: URLSession(configuration: configuration))
    )

    let session = try await client.beginSession()
    let firstPoll = try await client.poll(session)
    let secondPoll = try await client.poll(session)

    guard case .scanned = firstPoll else {
        Issue.record("第一次轮询应返回已扫描状态")
        return
    }
    guard case .credential(let credential) = secondPoll else {
        Issue.record("确认后应换取 115 Cookie")
        return
    }
    #expect(session.qrURL.absoluteString == "https://115.com/scan/dg-fixture-uid")
    #expect(credential.provider == .p115)
    #expect(credential.kind == .cookie)
    #expect(credential.secret == "UID=uid-value; CID=cid-value; SEID=seid-value")
    #expect(P115AuthMockURLProtocol.requestedPaths == [
        "/api/1.0/web/1.0/token",
        "/get/status",
        "/get/status",
        "/app/1.0/alipaymini/1.0/login/qrcode"
    ])
    #expect(P115AuthMockURLProtocol.resultRequestBody == "account=fixture-uid")
}

@Test func testP115QRCodeChannelOnlyAcceptsOfficialHTTPSDomains() {
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .p115,
        url: URL(string: "https://115.com/")
    ))
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .p115,
        url: URL(string: "https://q.115.com/scan")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .p115,
        url: URL(string: "http://115.com/scan")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .p115,
        url: URL(string: "https://evil115.com/scan")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .p115,
        url: URL(string: "https://example.com/scan")
    ))
}

@Test func testP115QRCodeExtractionTargetsLoginImageWithoutClickingGenericScanControls() {
    let selector = CloudAuthQRCodeChannelPolicy.preferredQRCodeSelector(for: .p115)

    #expect(selector?.contains("#js_login_qrcode_img") == true)
    #expect(selector?.contains(".qrcode-login canvas") == true)
    #expect(!CloudAuthQRCodeChannelPolicy.allowsAutomaticLoginSurfaceActivation(for: .p115))
    #expect(CloudAuthQRCodeChannelPolicy.allowsAutomaticLoginSurfaceActivation(for: .ali))
}

@Test func testQRCodePayloadSignatureDistinguishesSamePrefixImages() {
    let sharedPrefix = "data:image/gif;base64,R0lGODdhTgFOAYAAAAAAAP///"
    let loginPayload = sharedPrefix + String(repeating: "A", count: 160) + "login"
    let publicAccountPayload = sharedPrefix + String(repeating: "A", count: 160) + "public-account"

    #expect(CloudAuthQRCodePayloadSignature.make(loginPayload) == CloudAuthQRCodePayloadSignature.make(loginPayload))
    #expect(CloudAuthQRCodePayloadSignature.make(loginPayload) != CloudAuthQRCodePayloadSignature.make(publicAccountPayload))
}

@Test func testP115CookieFormatterOnlyIncludesOfficialDomainCookies() {
    let cookies = [
        makeCookie(name: "UID", value: "uid-token", domain: ".115.com"),
        makeCookie(name: "CID", value: "cid-token", domain: ".q.115.com"),
        makeCookie(name: "SEID", value: "seid-token", domain: "115.com"),
        makeCookie(name: "UID", value: "evil-token", domain: ".evil115.com"),
        makeCookie(name: "other", value: "ignore", domain: ".example.com")
    ]

    let cookieString = CloudAuthCookieFormatter.cookieString(from: cookies, provider: .p115)

    #expect(cookieString.contains("UID=uid-token"))
    #expect(cookieString.contains("CID=cid-token"))
    #expect(cookieString.contains("SEID=seid-token"))
    #expect(!cookieString.contains("evil-token"))
    #expect(!cookieString.contains("other=ignore"))
}

@Test func testAliWebLoginUsesOfficialSignInPage() {
    let url = CloudAuthAliWebLoginPolicy.loginURL

    #expect(url.scheme == "https")
    #expect(url.host == "www.alipan.com")
    #expect(url.path == "/sign/in")
}

@Test func testAliCredentialMessagesOnlyComeFromOfficialMainFrame() {
    #expect(CloudAuthAliWebLoginPolicy.acceptsCredentialMessage(
        frameURL: URL(string: "https://www.alipan.com/sign/in"),
        isMainFrame: true
    ))
    #expect(!CloudAuthAliWebLoginPolicy.acceptsCredentialMessage(
        frameURL: URL(string: "https://www.alipan.com/sign/in"),
        isMainFrame: false
    ))
    #expect(!CloudAuthAliWebLoginPolicy.acceptsCredentialMessage(
        frameURL: URL(string: "https://example.com/sign/in"),
        isMainFrame: true
    ))
}

@Test func testAliQRCodeChannelOnlyAcceptsOfficialLoginDomains() {
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .ali,
        url: URL(string: "https://passport.aliyundrive.com/login")
    ))
    #expect(CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .ali,
        url: URL(string: "https://qrlogin.taobao.com/login")
    ))
    #expect(!CloudAuthQRCodeChannelPolicy.acceptsQRCodeFrame(
        provider: .ali,
        url: URL(string: "https://example.com/login")
    ))
}

@Test func testAliCredentialParserAcceptsMixedTypeWebTokenJSON() throws {
    let token = """
    {
      "access_token": "ali-access",
      "refresh_token": "ali-refresh",
      "default_drive_id": "drive-1",
      "expires_in": 7200,
      "user_data": {"name": "tester"}
    }
    """

    let credential = CloudAuthAliCredentialParser.credential(from: token)

    #expect(credential.provider == .ali)
    #expect(credential.kind == .refreshToken)
    #expect(credential.secret == "ali-access")
    #expect(credential.accessToken == "ali-access")
    #expect(credential.refreshToken == "ali-refresh")
    #expect(credential.metadata["default_drive_id"] == "drive-1")
}

@Test func testQuarkCookieCompletionEndsSingleScanFlow() {
    let nextStep = CloudAuthStepPolicy.nextStep(
        provider: .quark,
        completedCredentialKind: .cookie,
        shouldDismiss: true
    )

    #expect(nextStep == nil)
}

@Test func testQuarkTokenCompletionContinuesToCookieStep() {
    let nextStep = CloudAuthStepPolicy.nextStep(
        provider: .quark,
        completedCredentialKind: .refreshToken,
        shouldDismiss: false
    )

    #expect(nextStep == .webCookie)
}

@Test func testUCTokenCompletionContinuesToCookieStep() {
    let nextStep = CloudAuthStepPolicy.nextStep(
        provider: .uc,
        completedCredentialKind: .refreshToken,
        shouldDismiss: false
    )

    #expect(nextStep == .webCookie)
}

@Test func testUCCookieCompletionEndsSingleScanFlow() {
    let nextStep = CloudAuthStepPolicy.nextStep(
        provider: .uc,
        completedCredentialKind: .cookie,
        shouldDismiss: true
    )

    #expect(nextStep == nil)
}

@Test func testCompletedUCTokenAuthorizationDoesNotRequestAnotherScan() {
    let nextStep = CloudAuthStepPolicy.nextStep(
        provider: .uc,
        completedCredentialKind: .refreshToken,
        shouldDismiss: true
    )

    #expect(nextStep == nil)
}

private func makeImage(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
) -> NSImage {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    for y in 0..<height {
        for x in 0..<width {
            let value = pixel(x, y)
            representation.setColor(
                NSColor(
                    calibratedRed: CGFloat(value.red) / 255,
                    green: CGFloat(value.green) / 255,
                    blue: CGFloat(value.blue) / 255,
                    alpha: CGFloat(value.alpha) / 255
                ),
                atX: x,
                y: y
            )
        }
    }

    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(representation)
    return image
}

private func makeCookie(name: String, value: String, domain: String) -> HTTPCookie {
    let properties: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: domain,
        .path: "/"
    ]
    return HTTPCookie(properties: properties)!
}

private func queryItems(_ url: URL) -> [String: String] {
    Dictionary<String, String>(
        uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }
    )
}

private final class P115AuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestedPaths: [String] = []
    nonisolated(unsafe) private static var storedResultRequestBody: String?
    nonisolated(unsafe) private static var statusPollCount = 0

    static var requestedPaths: [String] {
        lock.withLock { storedRequestedPaths }
    }

    static var resultRequestBody: String? {
        lock.withLock { storedResultRequestBody }
    }

    static func reset() {
        lock.withLock {
            storedRequestedPaths = []
            storedResultRequestBody = nil
            statusPollCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "qrcodeapi.115.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let requestBody = Self.requestBodyText(request)

        let body: String = Self.lock.withLock {
            Self.storedRequestedPaths.append(url.path)
            switch url.path {
            case "/api/1.0/web/1.0/token":
                return #"{"state":true,"data":{"uid":"fixture-uid","time":123456,"sign":"fixture-sign"}}"#
            case "/get/status":
                Self.statusPollCount += 1
                let status = Self.statusPollCount == 1 ? 1 : 2
                return "{\"state\":true,\"data\":{\"status\":\(status)}}"
            case "/app/1.0/alipaymini/1.0/login/qrcode":
                Self.storedResultRequestBody = requestBody
                return #"{"state":true,"data":{"cookie":{"UID":"uid-value","CID":"cid-value","SEID":"seid-value"}}}"#
            default:
                return #"{"state":false,"message":"unexpected path"}"#
            }
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBodyText(_ request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
