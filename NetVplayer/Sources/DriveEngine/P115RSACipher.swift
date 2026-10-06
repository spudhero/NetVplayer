import Foundation
import Security

enum P115RSACipher {
    private static let rsaKey: [UInt8] = [0x8d, 0xa5, 0xa5, 0x8d]
    private static let longXORKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46
    ]
    private static let keyTable: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]
    private static let publicKeyDERBase64 = "MIGJAoGBAIaGmAwPWiTEudQwIM0sInA/8/RQdWUpBYsc+I8JuGAhNkdxmKbiaDFJZZvRIsM1kv21rUeUStHqTTbGsXKq1jOMO7asYidQLQEJk6yWfRrvAPDI4DjeLk07wuw2ivLp8QpvHtpPcmLxNkIMB8MxuHG/E5908wEOPE/lffOvtxaDAgMBAAE="

    static func encrypt(_ data: Data) throws -> String {
        let firstPass = xor([UInt8](data), key: rsaKey).reversed()
        var wrapped = [UInt8](repeating: 0, count: 16)
        wrapped.append(contentsOf: xor(Array(firstPass), key: longXORKey))

        let key = try publicKey()
        var encrypted = Data()
        for offset in stride(from: 0, to: wrapped.count, by: 117) {
            let end = min(offset + 117, wrapped.count)
            let message = Array(wrapped[offset..<end])
            var padded = [UInt8](repeating: 0x02, count: 127 - message.count)
            padded[0] = 0
            padded.append(0)
            padded.append(contentsOf: message)
            var error: Unmanaged<CFError>?
            guard let block = SecKeyCreateEncryptedData(
                key,
                .rsaEncryptionRaw,
                Data(padded) as CFData,
                &error
            ) as Data? else {
                throw cipherError("115 RSA 请求加密失败", underlying: error?.takeRetainedValue())
            }
            encrypted.append(block)
        }
        return encrypted.base64EncodedString()
    }

    static func decrypt(_ value: String) throws -> Data {
        try decrypt(value, rsaTransform: rawPublicTransform)
    }

    static func decrypt(
        _ value: String,
        rsaTransform: (Data) throws -> Data
    ) throws -> Data {
        guard let encrypted = Data(base64Encoded: value),
              !encrypted.isEmpty,
              encrypted.count.isMultiple(of: 128) else {
            throw cipherError("115 RSA 响应格式无效")
        }

        var wrapped = [UInt8]()
        for offset in stride(from: 0, to: encrypted.count, by: 128) {
            let block = encrypted.subdata(in: offset..<(offset + 128))
            let transformed = [UInt8](try rsaTransform(block))
            guard let separator = transformed.dropFirst().firstIndex(of: 0),
                  separator + 1 < transformed.endIndex else {
                throw cipherError("115 RSA 响应填充无效")
            }
            wrapped.append(contentsOf: transformed[(separator + 1)...])
        }

        guard wrapped.count > 16 else {
            throw cipherError("115 RSA 响应内容为空")
        }
        let randomKey = Array(wrapped.prefix(16))
        let responseKey = generatedKey(from: randomKey, length: 12)
        let secondPass = xor(Array(wrapped.dropFirst(16)), key: responseKey).reversed()
        return Data(xor(Array(secondPass), key: rsaKey))
    }

    private static func rawPublicTransform(_ data: Data) throws -> Data {
        let key = try publicKey()
        var error: Unmanaged<CFError>?
        guard let transformed = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionRaw,
            data as CFData,
            &error
        ) as Data? else {
            throw cipherError("115 RSA 响应解密失败", underlying: error?.takeRetainedValue())
        }
        return transformed
    }

    private static func publicKey() throws -> SecKey {
        guard let keyData = Data(base64Encoded: publicKeyDERBase64) else {
            throw cipherError("115 RSA 公钥无效")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw cipherError("115 RSA 公钥加载失败", underlying: error?.takeRetainedValue())
        }
        return key
    }

    private static func xor(_ source: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !source.isEmpty, !key.isEmpty else { return source }
        let prefixLength = source.count & 3
        return source.indices.map { index in
            let keyIndex = index < prefixLength
                ? index
                : (index - prefixLength) % key.count
            return source[index] ^ key[keyIndex]
        }
    }

    private static func generatedKey(from randomKey: [UInt8], length: Int) -> [UInt8] {
        guard randomKey.count >= length, keyTable.count >= length * length else { return [] }
        var result = [UInt8](repeating: 0, count: length)
        var tailIndex = length * (length - 1)
        var headIndex = 0
        for index in 0..<length {
            let mixed = randomKey[index] &+ keyTable[headIndex]
            result[index] = keyTable[tailIndex] ^ mixed
            tailIndex -= length
            headIndex += length
        }
        return result
    }

    private static func cipherError(_ message: String, underlying: CFError? = nil) -> Error {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying
        }
        return NSError(domain: "P115RSACipher", code: 1, userInfo: userInfo)
    }
}
