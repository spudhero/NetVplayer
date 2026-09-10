import Foundation

/// DNS-over-HTTPS configuration from FongMi config files.
public struct Doh: Codable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var ips: [String]

    public init(name: String = "", url: String = "", ips: [String] = []) {
        self.name = name
        self.url = url
        self.ips = ips
    }
}

/// Host-scoped response/request header injection rule.
public struct HeaderRule: Codable, Hashable, Sendable {
    public var host: String
    public var header: [String: String]

    public init(host: String = "", header: [String: String] = [:]) {
        self.host = host
        self.header = header
    }

    enum CodingKeys: String, CodingKey {
        case host, header
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""

        if let header = try? container.decodeIfPresent([String: String].self, forKey: .header) {
            self.header = header
        } else if let dynamic = try? container.decodeIfPresent(JSONDynamicValue.self, forKey: .header),
                  case .object(let object) = dynamic {
            self.header = object.mapValues(\.stringValue)
        } else {
            self.header = [:]
        }
    }
}

/// Proxy selection rule from FongMi config files.
public struct ProxyRule: Codable, Hashable, Sendable {
    public var name: String
    public var hosts: [String]
    public var urls: [String]

    public init(name: String = "", hosts: [String] = [], urls: [String] = []) {
        self.name = name
        self.hosts = hosts
        self.urls = urls
    }
}
