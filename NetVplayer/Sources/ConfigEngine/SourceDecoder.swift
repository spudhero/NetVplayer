// ConfigEngine/SourceDecoder.swift
// 配置源多格式解密器，对应 FongMi: Decoder.java

import Foundation
import Networking
import CommonCrypto

/// 配置源解密错误
public enum DecoderError: Error, LocalizedError, Sendable {
    case emptyData
    case invalidFormat
    case invalidBase64
    case aesDecryptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyData: return "配置数据为空"
        case .invalidFormat: return "无法识别的配置格式"
        case .invalidBase64: return "Base64 解码失败"
        case .aesDecryptFailed(let msg): return "AES 解密失败: \(msg)"
        }
    }
}

/// 配置源解密器
/// 支持：纯 JSON / 8位标记+**+Base64 / AES-CBC(2423开头)
public struct SourceDecoder: Sendable {

    /// 从文本数据中解码出 JSON 配置
    public static func decode(_ data: String, url: String = "") throws -> String {
        let trimmed = trimEnvelope(data)
        guard !trimmed.isEmpty else { throw DecoderError.emptyData }

        // 1. 纯 JSON，或 JSON 正文前带注释说明
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") {
            let fixed = fix(url: url, data: trimmed)
            if let json = cleanJSONIfPresent(fixed) { return json }
        }

        var result = trimmed

        // 2. 包含 "**" 的 Base64 隐写
        if result.contains("**") {
            result = try extractBase64(from: result)
        } else if let decodedData = Data(base64Encoded: result, options: .ignoreUnknownCharacters),
                  let decodedText = String(data: decodedData, encoding: .utf8) {
            // 3. 兼容纯 Base64 配置（有些数据源为了隐秘，将整包直接进行 Base64 加码）
            let decodedTrimmed = trimEnvelope(decodedText)
            if decodedTrimmed.hasPrefix("{") || decodedTrimmed.hasPrefix("[") || decodedTrimmed.hasPrefix("2423") {
                result = decodedTrimmed
            }
        }

        // 4. AES-CBC 加密 (2423 开头的 Hex 串)
        if result.hasPrefix("2423") {
            result = try decryptAES(hex: result.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression))
        }

        let fixed = fix(url: url, data: trimEnvelope(result))
        if let json = cleanJSONIfPresent(fixed) { return json }
        return fixed
    }

    /// 从二进制数据中解密（图片隐写）
    public static func decodeFromImageData(_ data: Data, url: String = "") throws -> String {
        // 与 FongMi 的 ResponseBody.string() 行为保持一致：即使图片主体不是
        // 有效 UTF-8，也从完整响应里寻找 ASCII 的 8 位标记和 Base64 载荷。
        let lossyText = String(decoding: data, as: UTF8.self)
        if lossyText.range(of: "[A-Za-z0-9]{8}\\*\\*", options: .regularExpression) != nil {
            return try decode(lossyText, url: url)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw DecoderError.invalidFormat
        }
        return try decode(text, url: url)
    }

    // MARK: - Private

    private static func trimEnvelope(_ data: String) -> String {
        let envelopeCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}"))
        return data.trimmingCharacters(in: envelopeCharacters)
    }

    private static func cleanJSONIfPresent(_ data: String) -> String? {
        let trimmed = trimEnvelope(data)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") else {
            return nil
        }
        let cleaned = cleanComments(data)
        let cleanedTrimmed = trimEnvelope(cleaned)
        guard cleanedTrimmed.hasPrefix("{") || cleanedTrimmed.hasPrefix("[") else {
            return nil
        }
        return cleaned
    }

    /// 提取 "8位标记**" 之后的 Base64 数据并解码
    private static func extractBase64(from data: String) throws -> String {
        // FongMi 正则: [A-Za-z0-9]{8}\*\*
        let pattern = "[A-Za-z0-9]{8}\\*\\*"
        guard let range = data.range(of: pattern, options: .regularExpression) else {
            throw DecoderError.invalidBase64
        }

        let base64Payload = String(data[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: base64Payload, options: .ignoreUnknownCharacters),
              let text = String(data: decoded, encoding: .utf8) else {
            throw DecoderError.invalidBase64
        }

        return text
    }

    /// AES-CBC 解密，对应 FongMi: Decoder.cbc()
    private static func decryptAES(hex: String) throws -> String {
        // 1. Hex 解码为字节数据
        guard let dataBytes = Data(hexString: hex) else {
            throw DecoderError.aesDecryptFailed("无效的十六进制配置数据")
        }

        // 用字节流特征查找：$# 对应 [0x24, 0x23]，#$ 对应 [0x23, 0x24]
        let startPattern = Data([0x24, 0x23])
        let endPattern = Data([0x23, 0x24])

        guard let startRange = dataBytes.range(of: startPattern),
              let endRange = dataBytes.range(of: endPattern, options: [], in: startRange.upperBound..<dataBytes.count),
              startRange.upperBound < endRange.lowerBound else {
            throw DecoderError.aesDecryptFailed("配置文件中未包含秘钥特征符")
        }

        let keyData = dataBytes.subdata(in: startRange.upperBound..<endRange.lowerBound)
        guard let rawKey = String(data: keyData, encoding: .utf8)?.lowercased() else {
            throw DecoderError.aesDecryptFailed("无法将秘钥字节转换为 ASCII 字符串")
        }
        let key = padEnd(rawKey)

        guard dataBytes.count >= 13 else {
            throw DecoderError.aesDecryptFailed("数据太短无法提取 IV")
        }
        let ivData = dataBytes.suffix(13)
        guard let rawIv = String(data: ivData, encoding: .utf8)?.lowercased() else {
            throw DecoderError.aesDecryptFailed("无法将 IV 字节转换为 ASCII 字符串")
        }
        let iv = padEnd(rawIv)

        // 2. 截取密文 Hex 串并转为字节
        guard let cipherRangeStart = hex.range(of: "2324")?.upperBound else {
            throw DecoderError.aesDecryptFailed("无法定位密文数据段")
        }
        guard hex.count > 26 else {
            throw DecoderError.aesDecryptFailed("配置密文段长度不足")
        }
        let cipherHex = String(hex[cipherRangeStart...].dropLast(26))
        guard let cipherData = Data(hexString: cipherHex) else {
            throw DecoderError.aesDecryptFailed("密文 Hex 转换字节失败")
        }

        // 3. 使用 CommonCrypto 进行 AES-CBC 解密
        guard let decryptedData = decryptCBC(key: key, iv: iv, data: cipherData) else {
            throw DecoderError.aesDecryptFailed("AES 解密过程执行失败")
        }

        guard let result = String(data: decryptedData, encoding: .utf8) else {
            throw DecoderError.aesDecryptFailed("解密后数据无法转换为 UTF-8 字符串")
        }

        return result
    }

    private static func padEnd(_ text: String) -> String {
        let pad = "0000000000000000"
        if text.count >= 16 {
            return String(text.prefix(16))
        }
        return text + pad.prefix(16 - text.count)
    }

    private static func decryptCBC(key: String, iv: String, data: Data) -> Data? {
        guard let keyData = key.data(using: .utf8),
              let ivData = iv.data(using: .utf8) else { return nil }

        var decryptBuffer = Data(count: data.count + kCCBlockSizeAES128)
        let bufferCount = decryptBuffer.count
        var numBytesDecrypted: size_t = 0

        let cryptStatus = decryptBuffer.withUnsafeMutableBytes { decryptBytes in
            data.withUnsafeBytes { dataBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyData.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            decryptBytes.baseAddress, bufferCount,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        if cryptStatus == kCCSuccess {
            decryptBuffer.removeSubrange(numBytesDecrypted..<decryptBuffer.count)
            return decryptBuffer
        }
        return nil
    }

    /// 修复相对路径，对应 FongMi: Decoder.fix()
    private static func fix(url: String, data: String) -> String {
        guard !url.isEmpty else { return data }
        var result = data

        // 正则表达式: "(\.|\.\.)/(.?|.+?)\.js\?(.?|.+?)"
        let pattern = "\"(\\\\.|\\\\.\\\\.)/(.?|.+?)\\\\.js\\\\?(.?|.+?)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                let matchRange = match.range
                let ext = nsString.substring(with: matchRange)
                let t = replace(url: url, ext: ext)
                result = (result as NSString).replacingCharacters(in: matchRange, with: t)
            }
        }

        if result.contains("../") {
            let resolved = URLHelper.resolve(base: url, relative: "../")
            result = result.replacingOccurrences(of: "../", with: resolved)
        }
        if result.contains("./") {
            let resolved = URLHelper.resolve(base: url, relative: "./")
            result = result.replacingOccurrences(of: "./", with: resolved)
        }

        result = result.replacingOccurrences(of: "__JS1__", with: "./")
        result = result.replacingOccurrences(of: "__JS2__", with: "../")

        return result
    }

    private static func replace(url: String, ext: String) -> String {
        var t = ext.replacingOccurrences(of: "\"./", with: "\"" + URLHelper.resolve(base: url, relative: "./"))
        t = t.replacingOccurrences(of: "\"../", with: "\"" + URLHelper.resolve(base: url, relative: "../"))
        t = t.replacingOccurrences(of: "./", with: "__JS1__")
        t = t.replacingOccurrences(of: "../", with: "__JS2__")
        return t
    }

    /// 清理 JSON 文件中的单行及多行注释，保证原生的 JSONSerialization 能安全解析
    private static func cleanComments(_ json: String) -> String {
        let scalars = Array(removingDanglingWhitespaceStringLines(from: json).unicodeScalars)
        var cleaned = ""
        cleaned.reserveCapacity(json.utf8.count)
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < scalars.count {
            let scalar = scalars[index]

            if isInsideString {
                if !isEscaped,
                   scalar.value < 0x20 {
                    cleaned.append(String(format: "\\u%04X", scalar.value))
                    index += 1
                    continue
                }
                cleaned.unicodeScalars.append(scalar)
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                isInsideString = true
                cleaned.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            if scalar == "/", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "/" {
                    cleaned.append(" ")
                    index += 2
                    while index < scalars.count,
                          scalars[index] != "\n", scalars[index] != "\r" {
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    cleaned.append(" ")
                    index += 2
                    while index + 1 < scalars.count {
                        if scalars[index] == "*", scalars[index + 1] == "/" {
                            index += 2
                            break
                        }
                        if scalars[index] == "\n" || scalars[index] == "\r" {
                            cleaned.unicodeScalars.append(scalars[index])
                        }
                        index += 1
                    }
                    continue
                }
            }

            cleaned.unicodeScalars.append(scalar)
            index += 1
        }

        return removeTrailingCommas(repairUnquotedArrayStrings(cleaned))
    }

    private static func removeTrailingCommas(_ json: String) -> String {
        var scalars = Array(json.unicodeScalars)
        var isInsideString = false
        var isEscaped = false

        for (offset, scalar) in scalars.enumerated() {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                continue
            }
            if scalar == "\"" {
                isInsideString = true
                continue
            }
            guard scalar == "," else { continue }

            var lookahead = offset + 1
            while lookahead < scalars.count,
                  CharacterSet.whitespacesAndNewlines.contains(scalars[lookahead]) {
                lookahead += 1
            }
            if lookahead < scalars.count,
               scalars[lookahead] == "}" || scalars[lookahead] == "]" {
                scalars[offset] = Unicode.Scalar(0x20)!
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func removingDanglingWhitespaceStringLines(from json: String) -> String {
        let lines = json.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var repaired: [String] = []
        repaired.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "\"",
               lines.dropFirst(index + 1).lazy
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })?
                .first
                .map({ $0 == "}" || $0 == "]" }) == true {
                if let previousIndex = repaired.lastIndex(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }), hasUnterminatedString(in: repaired[previousIndex]) {
                    repaired[previousIndex].append("\"")
                }
                repaired.append("")
            } else {
                repaired.append(String(line))
            }
        }

        return repaired.joined(separator: "\n")
    }

    private static func hasUnterminatedString(in line: String) -> Bool {
        var isInsideString = false
        var isEscaped = false

        for scalar in line.unicodeScalars {
            if isEscaped {
                isEscaped = false
            } else if scalar == "\\" {
                isEscaped = true
            } else if scalar == "\"" {
                isInsideString.toggle()
            }
        }

        return isInsideString
    }

    private static func repairUnquotedArrayStrings(_ json: String) -> String {
        let scalars = Array(json.unicodeScalars)
        var repaired = ""
        repaired.reserveCapacity(json.utf8.count)
        var index = 0
        var isInsideString = false
        var isEscaped = false
        var containers: [Unicode.Scalar] = []
        var previousSignificant: Unicode.Scalar?

        while index < scalars.count {
            let scalar = scalars[index]

            if isInsideString {
                repaired.unicodeScalars.append(scalar)
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if containers.last == "[",
               previousSignificant == "[" || previousSignificant == ",",
               scalar.value > 0x7F,
               hasOrphanClosingQuote(in: scalars, from: index) {
                repaired.append("\"")
                isInsideString = true
                continue
            }

            if scalar == "\"" {
                isInsideString = true
            } else if scalar == "[" || scalar == "{" {
                containers.append(scalar)
            } else if scalar == "]" || scalar == "}" {
                if !containers.isEmpty { containers.removeLast() }
            }

            repaired.unicodeScalars.append(scalar)
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                previousSignificant = scalar
            }
            index += 1
        }

        return repaired
    }

    private static func hasOrphanClosingQuote(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> Bool {
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\"" {
                var next = index + 1
                while next < scalars.count,
                      CharacterSet.whitespacesAndNewlines.contains(scalars[next]) {
                    next += 1
                }
                return next < scalars.count && (scalars[next] == "," || scalars[next] == "]")
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar == "," || scalar == "]" || scalar == "["
                || scalar == "{" || scalar == "}" || scalar == ":" {
                return false
            }
            index += 1
        }
        return false
    }
}

// MARK: - Hex Helper Extension
extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        
        // 快速指针转换，或者是安全 Swift 字符遍历
        var i = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(i, offsetBy: 2)
            guard nextIndex <= hexString.endIndex else { return nil }
            if let b = UInt8(hexString[i..<nextIndex], radix: 16) {
                data.append(b)
            } else {
                return nil
            }
            i = nextIndex
        }
        self = data
    }

    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
