// Models/MacCMSPayloadDecoder.swift
// Shared MacCMS JSON/XML response decoding.

import Foundation

public enum MacCMSPayloadFormat: String, Sendable, Equatable {
    case json
    case xml
}

public struct DecodedMacCMSPayload: Sendable {
    public let format: MacCMSPayloadFormat
    public var result: Result

    public init(format: MacCMSPayloadFormat, result: Result) {
        self.format = format
        self.result = result
    }
}

public enum MacCMSPayloadError: Error, LocalizedError, Sendable {
    case emptyPayload
    case invalidJSON
    case invalidXML(String)
    case apiError(String)
    case unrecognizedPayload

    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "MacCMS 返回内容为空"
        case .invalidJSON:
            return "MacCMS JSON 响应解析失败"
        case .invalidXML(let message):
            return message.isEmpty ? "MacCMS XML 响应解析失败" : "MacCMS XML 响应解析失败: \(message)"
        case .apiError(let message):
            return message
        case .unrecognizedPayload:
            return "返回内容不是可识别的 MacCMS JSON/XML 接口"
        }
    }
}

public enum MacCMSPayloadDecoder {
    public static func decode(_ payload: String) throws -> DecodedMacCMSPayload {
        if let decoded = try decodeIfPresent(payload) {
            return decoded
        }
        throw MacCMSPayloadError.unrecognizedPayload
    }

    /// Returns nil for valid non-MacCMS content, while malformed JSON/XML still throws.
    public static func decodeIfPresent(_ payload: String) throws -> DecodedMacCMSPayload? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacCMSPayloadError.emptyPayload }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8) else {
                throw MacCMSPayloadError.invalidJSON
            }
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw MacCMSPayloadError.invalidJSON
            }
            guard let object = value as? [String: Any], isMacCMSJSONObject(object) else {
                return nil
            }
            do {
                let result = try JSONDecoder().decode(Result.self, from: data)
                if result.code <= 0, !result.msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw MacCMSPayloadError.apiError(result.msg)
                }
                return DecodedMacCMSPayload(format: .json, result: result)
            } catch let error as MacCMSPayloadError {
                throw error
            } catch {
                throw MacCMSPayloadError.invalidJSON
            }
        }

        guard trimmed.hasPrefix("<") else { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            throw MacCMSPayloadError.invalidXML("")
        }

        let delegate = MacCMSXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw MacCMSPayloadError.invalidXML(parser.parserError?.localizedDescription ?? "")
        }
        guard delegate.isMacCMSPayload else { return nil }
        return DecodedMacCMSPayload(format: .xml, result: delegate.result)
    }

    private static func isMacCMSJSONObject(_ object: [String: Any]) -> Bool {
        let hasClasses = object["class"] is [Any] || object["types"] is [Any]
        guard let list = object["list"] as? [Any] else {
            return hasClasses || (object["code"] != nil && object["msg"] != nil)
        }
        if hasClasses || object["page"] != nil || object["pagecount"] != nil || object["total"] != nil {
            return true
        }
        guard let first = list.first as? [String: Any] else {
            return list.isEmpty && object["code"] != nil
        }
        return first["vod_id"] != nil || first["vod_name"] != nil
    }
}

private final class MacCMSXMLDelegate: NSObject, XMLParserDelegate {
    private struct Video {
        var vodId = ""
        var vodName = ""
        var vodPic = ""
        var vodYear = ""
        var vodArea = ""
        var vodContent = ""
        var vodActor = ""
        var vodDirector = ""
        var vodRemarks = ""
        var typeName = ""
        var playFlags: [String] = []
        var playURLs: [String] = []

        var vod: Vod {
            Vod(
                vodId: vodId,
                vodName: vodName,
                vodPic: vodPic,
                vodYear: vodYear,
                vodArea: vodArea,
                vodContent: vodContent,
                vodActor: vodActor,
                vodDirector: vodDirector,
                vodRemarks: vodRemarks,
                typeName: typeName,
                vodPlayFrom: playFlags.joined(separator: "$$$"),
                vodPlayUrl: playURLs.joined(separator: "$$$")
            )
        }
    }

    private(set) var result = Result(code: 1)
    private(set) var isMacCMSPayload = false

    private var rootElement = ""
    private var buffer = ""
    private var currentVideo: Video?
    private var currentTypeID = ""
    private var currentPlayFlag = ""
    private var sawList = false
    private var sawClass = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if rootElement.isEmpty {
            rootElement = name
        }
        buffer = ""

        switch name {
        case "list":
            sawList = true
            result.page = Self.int(attributeDict["page"], fallback: 1)
            result.pagecount = Self.int(attributeDict["pagecount"], fallback: 1)
            result.total = Self.int(attributeDict["recordcount"] ?? attributeDict["total"], fallback: 0)
        case "class":
            sawClass = true
        case "ty":
            currentTypeID = attributeDict["id"] ?? attributeDict["type_id"] ?? ""
        case "video":
            currentVideo = Video()
        case "dd":
            currentPlayFlag = attributeDict["flag"] ?? ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) {
            buffer += value
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentVideo != nil {
            switch name {
            case "id", "vod_id": currentVideo?.vodId = value
            case "name", "vod_name": currentVideo?.vodName = value
            case "pic", "vod_pic": currentVideo?.vodPic = value
            case "year", "vod_year": currentVideo?.vodYear = value
            case "area", "vod_area": currentVideo?.vodArea = value
            case "des", "vod_content": currentVideo?.vodContent = value
            case "actor", "vod_actor": currentVideo?.vodActor = value
            case "director", "vod_director": currentVideo?.vodDirector = value
            case "note", "vod_remarks": currentVideo?.vodRemarks = value
            case "type", "type_name": currentVideo?.typeName = value
            case "dd":
                currentVideo?.playFlags.append(currentPlayFlag.isEmpty ? "default" : currentPlayFlag)
                currentVideo?.playURLs.append(value)
                currentPlayFlag = ""
            case "video":
                if let video = currentVideo {
                    result.list.append(video.vod)
                }
                currentVideo = nil
            default:
                break
            }
        } else if name == "ty" {
            result.types.append(VodClass(typeId: currentTypeID, typeName: value))
            currentTypeID = ""
        }

        buffer = ""
        if name == rootElement {
            isMacCMSPayload = rootElement == "rss" && (sawList || sawClass)
        }
    }

    private static func int(_ value: String?, fallback: Int) -> Int {
        guard let value, let parsed = Int(value) else { return fallback }
        return parsed
    }
}
