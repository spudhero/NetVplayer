import Foundation

public enum DriveProvider: String, Codable, Sendable {
    case quark
    case uc
    case ali
    case p115
    case pikpak
    case baidu
    case cloud123
    case xunlei
    case mobile
    case tianyi
    case alist
    case webdav
    case bilibili
    case unknown

    public var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC网盘"
        case .ali: return "阿里云盘"
        case .p115: return "115网盘"
        case .pikpak: return "PikPak"
        case .baidu: return "百度网盘"
        case .cloud123: return "123 网盘"
        case .xunlei: return "迅雷云盘"
        case .mobile: return "中国移动云盘"
        case .tianyi: return "天翼云盘"
        case .alist: return "AList"
        case .webdav: return "WebDAV"
        case .bilibili: return "Bilibili"
        case .unknown: return "网盘"
        }
    }

    public var authURL: URL? {
        switch self {
        case .quark: return URL(string: "https://pan.quark.cn/")
        case .uc: return URL(string: "https://drive.uc.cn/")
        case .ali: return URL(string: "https://www.alipan.com/")
        case .p115: return URL(string: "https://115.com/")
        case .pikpak: return URL(string: "https://mypikpak.com/")
        case .baidu: return URL(string: "https://pan.baidu.com/")
        case .cloud123: return URL(string: "https://www.123pan.com/")
        case .xunlei: return URL(string: "https://pan.xunlei.com/")
        case .mobile: return URL(string: "https://yun.139.com/")
        case .tianyi: return URL(string: "https://cloud.189.cn/")
        default: return nil
        }
    }

    public var cookieDomains: [String] {
        switch self {
        case .quark: return ["pan.quark.cn", "drive-m.quark.cn", ".quark.cn"]
        case .uc: return ["drive.uc.cn", ".uc.cn"]
        case .ali: return ["aliyundrive.com", "alipan.com", ".aliyundrive.com", ".alipan.com"]
        case .p115: return ["115.com", ".115.com"]
        case .pikpak: return ["mypikpak.com", ".mypikpak.com"]
        case .baidu: return ["pan.baidu.com", ".baidu.com"]
        case .cloud123: return [
            "123pan.com", "123pan.cn", "123684.com", "123865.com", "123952.com", "123912.com",
            ".123pan.com", ".123pan.cn"
        ]
        case .xunlei: return ["pan.xunlei.com", ".xunlei.com"]
        case .mobile: return ["yun.139.com", "caiyun.139.com", "feixin.10086.cn", ".139.com", ".10086.cn"]
        case .tianyi: return ["cloud.189.cn", ".189.cn"]
        default: return []
        }
    }
}
