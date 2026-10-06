#!/usr/bin/env swift
import Foundation
import Security

// This helper communicates secrets only through its stdin/stdout pipes. Callers
// must capture stdout and print status metadata, never the returned payload.
let service = "com.netvplayer.app.xunlei-open-platform.v1"
let account = "NetVplayer"
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecAttrSynchronizable as String: false,
]

enum HelperFailure: Error { case invalidInput, keychain(OSStatus) }

func credentialData(_ data: Data) throws -> Data {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: String],
          let appID = value["app_id"], !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let apiKey = value["api_key"], apiKey.count >= 12,
          !apiKey.contains("*"), !apiKey.contains("•"), !apiKey.contains("●") else {
        throw HelperFailure.invalidInput
    }
    return try JSONSerialization.data(withJSONObject: ["app_id": appID, "api_key": apiKey])
}

func writeCredential(_ data: Data) throws {
    let validated = try credentialData(data)
    var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: validated] as CFDictionary)
    if status == errSecItemNotFound {
        var addition = query
        addition[kSecValueData as String] = validated
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        status = SecItemAdd(addition as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw HelperFailure.keychain(status) }
}

func readCredential() throws -> Data {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw HelperFailure.keychain(status)
    }
    return try credentialData(data)
}


do {
    switch CommandLine.arguments.dropFirst().first {
    case "write":
        try writeCredential(FileHandle.standardInput.readDataToEndOfFile())
        print("{\"saved\":true}")
    case "read":
        FileHandle.standardOutput.write(try readCredential())
    default:
        throw HelperFailure.invalidInput
    }
} catch {
    let kind: String
    if case HelperFailure.keychain(let status) = error { kind = "keychain-\(status)" }
    else { kind = "invalid-input" }
    FileHandle.standardError.write(Data("Xunlei credential operation failed: \(kind)\n".utf8))
    exit(1)
}
