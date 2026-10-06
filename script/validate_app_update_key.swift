import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let privateKeyText = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
      let seed = Data(base64Encoded: privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32 else {
    fputs("error: Sparkle private key is missing or malformed\n", stderr)
    exit(1)
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    guard publicKey == CommandLine.arguments[1] else {
        fputs("error: Sparkle private key does not match the app public key\n", stderr)
        exit(1)
    }
} catch {
    fputs("error: Sparkle private key cannot be loaded\n", stderr)
    exit(1)
}
