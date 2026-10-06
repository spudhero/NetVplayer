import CommonCrypto
import Foundation
import ProviderSDK
import Security

struct QuickJSCryptoHost: @unchecked Sendable {
    func handle(_ request: QuickJSHostControl) async -> QuickJSHostResponse {
        guard request.capability == "crypto" else {
            return failure(
                requestID: request.requestID,
                code: "unsupported_host_request",
                message: "Unsupported QuickJS crypto request"
            )
        }

        do {
            let options = request.options ?? [:]
            let value: String
            switch request.operation {
            case "aes":
                value = try aes(options)
            case "rsa":
                value = try rsa(options)
            default:
                throw QuickJSCryptoHostError(code: "unsupported_operation", message: "QuickJS crypto operation is unsupported")
            }
            return QuickJSHostResponse(
                requestID: request.requestID,
                ok: true,
                result: .object(["value": .string(value)])
            )
        } catch let error as QuickJSCryptoHostError {
            if error.code != "unsupported_operation" {
                return QuickJSHostResponse(
                    requestID: request.requestID,
                    ok: true,
                    result: .object(["value": .string("")])
                )
            }
            return failure(requestID: request.requestID, code: error.code, message: error.message)
        } catch {
            return failure(requestID: request.requestID, code: "crypto_failed", message: "QuickJS crypto operation failed")
        }
    }

    private func aes(_ options: [String: ProviderJSONValue]) throws -> String {
        let mode = try requiredString(options["mode"], name: "mode")
        let encrypt = bool(options["encrypt"])
        let input = try requiredString(options["input"], name: "input")
        let inBase64 = bool(options["in_base64"])
        let key = try requiredString(options["key"], name: "key")
        let iv = optionalString(options["iv"])
        let outBase64 = bool(options["out_base64"])

        let normalizedMode = mode.uppercased()
        let ecb = normalizedMode.contains("/ECB/")
        let cbc = normalizedMode.contains("/CBC/")
        guard normalizedMode.hasPrefix("AES/"), (ecb || cbc),
              normalizedMode.contains("PKCS5") || normalizedMode.contains("PKCS7") else {
            throw QuickJSCryptoHostError(code: "unsupported_mode", message: "AES mode is unsupported")
        }
        if cbc, iv == nil {
            throw QuickJSCryptoHostError(code: "invalid_iv", message: "AES CBC requires an IV")
        }

        var keyData = Data(key.utf8)
        if keyData.count < kCCKeySizeAES128 {
            keyData.append(Data(repeating: 0, count: kCCKeySizeAES128 - keyData.count))
        }
        guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(keyData.count) else {
            throw QuickJSCryptoHostError(code: "invalid_key", message: "AES key length is invalid")
        }

        var ivData: Data?
        if let iv {
            ivData = Data(iv.utf8)
            if ivData!.count < kCCBlockSizeAES128 {
                ivData!.append(Data(repeating: 0, count: kCCBlockSizeAES128 - ivData!.count))
            }
            guard ivData!.count == kCCBlockSizeAES128 else {
                throw QuickJSCryptoHostError(code: "invalid_iv", message: "AES IV length is invalid")
            }
        }

        let inputData = try decodeBase64(input, enabled: inBase64)
        var output = Data(count: inputData.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        var cryptOptions = CCOptions(kCCOptionPKCS7Padding)
        if ecb { cryptOptions |= CCOptions(kCCOptionECBMode) }
        let status = output.withUnsafeMutableBytes { outputBytes in
            inputData.withUnsafeBytes { inputBytes in
                keyData.withUnsafeBytes { keyBytes in
                    if let ivData {
                        return ivData.withUnsafeBytes { ivBytes in
                            CCCrypt(
                                encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                cryptOptions,
                                keyBytes.baseAddress,
                                keyData.count,
                                ivBytes.baseAddress,
                                inputBytes.baseAddress,
                                inputData.count,
                                outputBytes.baseAddress,
                                outputCapacity,
                                &outputLength
                            )
                        }
                    }
                    return CCCrypt(
                        encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        cryptOptions,
                        keyBytes.baseAddress,
                        keyData.count,
                        nil,
                        inputBytes.baseAddress,
                        inputData.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw QuickJSCryptoHostError(code: "crypto_failed", message: "AES operation failed")
        }
        output.removeSubrange(outputLength..<output.count)
        return outBase64 ? output.base64EncodedString() : String(decoding: output, as: UTF8.self)
    }

    private func rsa(_ options: [String: ProviderJSONValue]) throws -> String {
        let mode = try requiredString(options["mode"], name: "mode")
        let isPublic = bool(options["pub"])
        let encrypt = bool(options["encrypt"])
        let input = try requiredString(options["input"], name: "input")
        let inBase64 = bool(options["in_base64"])
        let key = try requiredString(options["key"], name: "key")
        let outBase64 = bool(options["out_base64"])
        let padding: SecKeyAlgorithm
        switch mode.uppercased() {
        case "RSA/NONE/NOPADDING", "RSA/ECB/NOPADDING":
            padding = .rsaEncryptionRaw
        default:
            // Android Crypto defaults every mode except RSA/None/NoPadding to PKCS#1.
            padding = .rsaEncryptionPKCS1
        }

        let keyData = try decodeBase64(key
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: ""), enabled: true)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
        ]
        let candidates: [Data]
        if isPublic {
            candidates = [keyData, unwrapX509PublicKey(keyData)].compactMap { $0 }
        } else {
            candidates = [keyData, unwrapPKCS8(keyData)].reduce(into: []) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        }
        var secKey: SecKey?
        for candidate in candidates {
            if let value = SecKeyCreateWithData(candidate as CFData, attributes as CFDictionary, nil) {
                secKey = value
                break
            }
        }
        guard let secKey else {
            throw QuickJSCryptoHostError(code: "invalid_key", message: "RSA key is invalid")
        }
        let inputData = try decodeBase64(input, enabled: inBase64)
        let output: Data?
        if encrypt, !isPublic, padding == .rsaEncryptionPKCS1 {
            output = try rsaPrivateEncryptPKCS1(secKey, input: inputData)
        } else if !encrypt, isPublic, padding == .rsaEncryptionPKCS1 {
            output = try rsaPublicDecryptPKCS1(secKey, input: inputData)
        } else {
            var transformError: Unmanaged<CFError>?
            if encrypt {
                output = SecKeyCreateEncryptedData(secKey, padding, inputData as CFData, &transformError) as Data?
            } else {
                output = SecKeyCreateDecryptedData(secKey, padding, inputData as CFData, &transformError) as Data?
            }
        }
        guard let output else {
            throw QuickJSCryptoHostError(code: "crypto_failed", message: "RSA operation failed")
        }
        return outBase64 ? output.base64EncodedString() : String(decoding: output, as: UTF8.self)
    }

    private func rsaPrivateEncryptPKCS1(_ key: SecKey, input: Data) throws -> Data {
        let blockSize = SecKeyGetBlockSize(key)
        guard blockSize > 11, input.count <= blockSize - 11 else {
            throw QuickJSCryptoHostError(code: "crypto_failed", message: "RSA input is too large")
        }
        var block = Data([0x00, 0x01])
        block.append(Data(repeating: 0xff, count: blockSize - input.count - 3))
        block.append(0x00)
        block.append(input)
        var error: Unmanaged<CFError>?
        guard let output = SecKeyCreateDecryptedData(key, .rsaEncryptionRaw, block as CFData, &error) as Data? else {
            throw QuickJSCryptoHostError(code: "crypto_failed", message: "RSA private-key operation failed")
        }
        return output
    }

    private func rsaPublicDecryptPKCS1(_ key: SecKey, input: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let block = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, input as CFData, &error) as Data?,
              block.count >= 3, block[block.startIndex] == 0, block[block.startIndex + 1] == 1 else {
            throw QuickJSCryptoHostError(code: "crypto_failed", message: "RSA public-key operation failed")
        }
        guard let separator = block.dropFirst(2).firstIndex(of: 0),
              separator >= block.startIndex + 10 else {
            throw QuickJSCryptoHostError(code: "crypto_failed", message: "RSA PKCS#1 block is invalid")
        }
        return Data(block[(separator + 1)...])
    }

    private func decodeBase64(_ value: String, enabled: Bool) throws -> Data {
        guard enabled else { return Data(value.utf8) }
        let normalized = value
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        guard let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) else {
            throw QuickJSCryptoHostError(code: "invalid_base64", message: "Crypto input base64 is invalid")
        }
        return data
    }

    private func unwrapPKCS8(_ data: Data) -> Data {
        var cursor = 0
        guard let outer = derElement(data, cursor: &cursor, expectedTag: 0x30) else { return data }
        cursor = 0
        _ = derElement(outer, cursor: &cursor, expectedTag: 0x02)
        _ = derElement(outer, cursor: &cursor, expectedTag: 0x30)
        return derElement(outer, cursor: &cursor, expectedTag: 0x04) ?? data
    }

    private func unwrapX509PublicKey(_ data: Data) -> Data? {
        var cursor = 0
        guard let outer = derElement(data, cursor: &cursor, expectedTag: 0x30) else { return nil }
        cursor = 0
        guard derElement(outer, cursor: &cursor, expectedTag: 0x30) != nil,
              let bitString = derElement(outer, cursor: &cursor, expectedTag: 0x03),
              bitString.first == 0 else {
            return nil
        }
        var rsaCursor = 0
        let rsaKey = Data(bitString.dropFirst())
        guard derElement(rsaKey, cursor: &rsaCursor, expectedTag: 0x30) != nil else { return nil }
        return rsaKey
    }

    private func derElement(_ data: Data, cursor: inout Int, expectedTag: UInt8) -> Data? {
        guard cursor < data.count, data[cursor] == expectedTag else { return nil }
        cursor += 1
        guard cursor < data.count else { return nil }
        let firstLength = Int(data[cursor])
        cursor += 1
        let length: Int
        if firstLength & 0x80 == 0 {
            length = firstLength
        } else {
            let byteCount = firstLength & 0x7f
            guard byteCount > 0, byteCount <= 4, cursor + byteCount <= data.count else { return nil }
            var value = 0
            for _ in 0..<byteCount {
                value = (value << 8) | Int(data[cursor])
                cursor += 1
            }
            length = value
        }
        guard cursor + length <= data.count else { return nil }
        let value = data.subdata(in: cursor..<(cursor + length))
        cursor += length
        return value
    }

    private func requiredString(_ value: ProviderJSONValue?, name: String) throws -> String {
        guard let value = optionalString(value) else {
            throw QuickJSCryptoHostError(code: "invalid_\(name)", message: "Crypto \(name) is invalid")
        }
        return value
    }

    private func optionalString(_ value: ProviderJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func bool(_ value: ProviderJSONValue?) -> Bool {
        guard case .bool(let value) = value else { return false }
        return value
    }

    private func failure(requestID: String, code: String, message: String) -> QuickJSHostResponse {
        QuickJSHostResponse(
            requestID: requestID,
            ok: false,
            error: ProviderErrorPayload(code: code, message: message)
        )
    }
}

private struct QuickJSCryptoHostError: Error {
    let code: String
    let message: String
}
