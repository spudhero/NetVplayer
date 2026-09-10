// DriveEngine/DriveFileReference.swift
// 网盘分享中的具体文件引用，用于在详情集数和播放提取器之间传递精确文件身份。

import Foundation
import Models

public struct DriveFileReference: Equatable, Sendable {
    public let provider: DriveProvider
    public let shareURL: String
    public let pwdID: String
    public let passcode: String
    public let fid: String
    public let fidToken: String
    public let fileName: String
    public let collectionName: String
    public let personalDriveID: String
    public let personalFileID: String
    public let pickCode: String
    public let size: Int64

    public init(
        provider: DriveProvider,
        shareURL: String,
        pwdID: String,
        passcode: String = "",
        fid: String,
        fidToken: String,
        fileName: String,
        collectionName: String = "",
        personalDriveID: String = "",
        personalFileID: String = "",
        pickCode: String = "",
        size: Int64 = 0
    ) {
        self.provider = provider
        self.shareURL = shareURL
        self.pwdID = pwdID
        self.passcode = passcode
        self.fid = fid
        self.fidToken = fidToken
        self.fileName = fileName
        self.collectionName = collectionName
        self.personalDriveID = personalDriveID
        self.personalFileID = personalFileID
        self.pickCode = pickCode
        self.size = max(0, size)
    }

    public var encodedURL: String {
        var components = URLComponents()
        components.scheme = "netvplayer-drive"
        components.host = provider.rawValue
        components.path = "/file"
        components.queryItems = [
            URLQueryItem(name: "share", value: shareURL),
            URLQueryItem(name: "pwd_id", value: pwdID),
            URLQueryItem(name: "passcode", value: passcode),
            URLQueryItem(name: "fid", value: fid),
            URLQueryItem(name: "fid_token", value: fidToken),
            URLQueryItem(name: "file_name", value: fileName)
        ]
        if !collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems?.append(URLQueryItem(name: "collection", value: collectionName))
        }
        if !personalDriveID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems?.append(URLQueryItem(name: "personal_drive_id", value: personalDriveID))
        }
        if !personalFileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems?.append(URLQueryItem(name: "personal_file_id", value: personalFileID))
        }
        if !pickCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems?.append(URLQueryItem(name: "pick_code", value: pickCode))
        }
        if size > 0 {
            components.queryItems?.append(URLQueryItem(name: "size", value: String(size)))
        }
        return components.url?.absoluteString ?? shareURL
    }

    public static func parse(_ rawURL: String) -> DriveFileReference? {
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "netvplayer-drive",
              let providerValue = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let shareURL = query["share"],
              let pwdID = query["pwd_id"],
              let fid = query["fid"],
              let fidToken = query["fid_token"],
              let fileName = query["file_name"],
              !shareURL.isEmpty,
              !pwdID.isEmpty,
              !fid.isEmpty else {
            return nil
        }
        return DriveFileReference(
            provider: DriveProvider(rawValue: providerValue) ?? .unknown,
            shareURL: shareURL,
            pwdID: pwdID,
            passcode: query["passcode"] ?? "",
            fid: fid,
            fidToken: fidToken,
            fileName: fileName,
            collectionName: query["collection"] ?? "",
            personalDriveID: query["personal_drive_id"] ?? "",
            personalFileID: query["personal_file_id"] ?? "",
            pickCode: query["pick_code"] ?? "",
            size: Int64(query["size"] ?? "") ?? 0
        )
    }

    public static func provider(for rawURL: String) -> DriveProvider {
        if let reference = parse(rawURL) {
            return reference.provider
        }
        let lower = rawURL.lowercased()
        if lower.contains("pan.quark.cn") || lower.contains("v.quark.cn") || lower.hasPrefix("quark://") { return .quark }
        if lower.contains("drive.uc.cn") || lower.contains("uc.cn") || lower.hasPrefix("uc://") { return .uc }
        if lower.contains("aliyundrive.com") || lower.contains("alipan.com") || lower.hasPrefix("ali://") { return .ali }
        if lower.contains("115.com") || lower.contains("115cdn.com") || lower.hasPrefix("115://") || lower.hasPrefix("p115://") { return .p115 }
        if lower.contains("mypikpak.com") || lower.hasPrefix("pikpak://") { return .pikpak }
        if lower.contains("pan.baidu.com") || lower.hasPrefix("baidu://") { return .baidu }
        if lower.contains("123pan.com")
            || lower.contains("123pan.cn")
            || lower.contains("123684.com")
            || lower.contains("123865.com")
            || lower.contains("123952.com")
            || lower.contains("123912.com")
            || lower.hasPrefix("123://")
            || lower.hasPrefix("cloud123://") { return .cloud123 }
        if lower.contains("pan.xunlei.com") || lower.hasPrefix("xunlei://") || lower.hasPrefix("thunder://") { return .xunlei }
        if lower.contains("yun.139.com")
            || lower.contains("caiyun.139.com")
            || lower.contains("feixin.10086.cn")
            || lower.hasPrefix("139://")
            || lower.hasPrefix("mobile://") { return .mobile }
        if lower.contains("cloud.189.cn") || lower.hasPrefix("189://") || lower.hasPrefix("tianyi://") { return .tianyi }
        if lower.contains("alist") || lower.hasPrefix("alist://") { return .alist }
        if lower.hasPrefix("webdav://") || lower.hasPrefix("webdavs://") { return .webdav }
        if lower.contains("bilibili.com") || lower.hasPrefix("bilibili://") { return .bilibili }
        return .unknown
    }
}
