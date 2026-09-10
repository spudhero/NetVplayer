import Foundation
import CryptoKit

/// Compiled with the actual ProviderSDK wire types in both public and private CI.
@main
struct VerifyProviderManifestWire {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2,
              let keyData = Data(base64Encoded: arguments[1]), keyData.count == 32 else {
            throw NSError(domain: "ManifestWire", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "usage: verify-manifest-wire SIGNED_MANIFEST PUBLIC_KEY_BASE64"])
        }
        let document = try JSONDecoder().decode(
            SignedProviderManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[0]))
        )
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        let payload = try JSONEncoder.providerCanonical.encode(document.manifest)
        guard let signature = Data(base64Encoded: document.signature),
              key.isValidSignature(signature, for: payload) else {
            throw NSError(domain: "ManifestWire", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "manifest signature rejected by Swift wire encoding"])
        }
        print("Swift manifest wire signature verified")
    }
}
