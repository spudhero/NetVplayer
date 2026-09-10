import Foundation
import ProviderRuntime
import ProviderSDK

enum ToolError: LocalizedError {
    case usage
    case invalidPublicKey
    case probeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: ProviderPackageTool verify --package DIR --public-key RAW_OR_BASE64_FILE --shell-version VERSION | verify-index --index-url HTTPS_URL --index-public-key FILE [--expect-empty] | probe-distribution --index-url HTTPS_URL --index-public-key FILE --public-key FILE --shell-version VERSION --version VERSION --store DIR | verify-sandbox --manifest FILE --package DIR --state DIR | probe-quickjs --manifest FILE --package DIR --state DIR | probe-quickjs-bili --manifest FILE --package DIR --state DIR [--api-base URL]"
        case .invalidPublicKey:
            return "public key must contain 32 raw Ed25519 bytes or their Base64 encoding"
        case .probeMismatch(let detail):
            return "QuickJS sandbox probe mismatch: \(detail)"
        }
    }
}

func argument(_ name: String, in values: [String]) throws -> String {
    guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else {
        throw ToolError.usage
    }
    return values[index + 1]
}

func publicKey(at url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    if data.count == 32 { return data }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decoded = Data(base64Encoded: text), decoded.count == 32 else {
        throw ToolError.invalidPublicKey
    }
    return decoded
}

func printJSON(_ output: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
struct ProviderPackageToolMain {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("ProviderPackageTool: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        switch arguments.first {
        case "verify-index", "probe-distribution":
            try await probeDistribution(arguments: arguments)
        case "verify":
            let package = URL(fileURLWithPath: try argument("--package", in: arguments), isDirectory: true)
            let keyURL = URL(fileURLWithPath: try argument("--public-key", in: arguments))
            let shellVersion = try argument("--shell-version", in: arguments)
            let documentURL = package.appendingPathComponent("signed-manifest.json")
            let document = try JSONDecoder().decode(
                SignedProviderManifest.self,
                from: Data(contentsOf: documentURL)
            )
            let verifier = try ProviderManifestVerifier(
                publicKeyData: publicKey(at: keyURL),
                shellVersion: shellVersion
            )
            try verifier.verify(document, packageRoot: package)
            try printJSON([
                "ok": true,
                "provider_id": document.manifest.providerID,
                "version": document.manifest.version,
                "runtime": document.manifest.runtime.rawValue,
                "assets": document.manifest.assets.count
            ])
        case "verify-sandbox":
            let manifestURL = URL(fileURLWithPath: try argument("--manifest", in: arguments))
            let package = URL(fileURLWithPath: try argument("--package", in: arguments), isDirectory: true)
            let state = URL(fileURLWithPath: try argument("--state", in: arguments), isDirectory: true)
            let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
            let command = try ProviderCommandBuilder.command(
                manifest: manifest,
                packageRoot: package,
                stateDirectoryURL: state
            )
            try printJSON([
                "ok": true,
                "provider_id": manifest.providerID,
                "sandbox": command.environment["NETVPLAYER_PROVIDER_SANDBOX"] ?? "",
                "launcher": command.executableURL.path,
                "runtime": command.arguments.indices.contains(1) ? command.arguments[1] : ""
            ])
        case "probe-quickjs":
            try await probeQuickJS(arguments: arguments)
        case "probe-quickjs-bili":
            try await probeQuickJSBili(arguments: arguments)
        default:
            throw ToolError.usage
        }
    }

    private static func probeDistribution(arguments: [String]) async throws {
        guard let indexURL = URL(string: try argument("--index-url", in: arguments)) else {
            throw ToolError.usage
        }
        let indexVerifier = try ProviderDistributionIndexVerifier(publicKeyData: publicKey(
            at: URL(fileURLWithPath: try argument("--index-public-key", in: arguments))
        ))
        let distribution = ProviderDistributionClient()
        let releases = try await distribution.fetchIndex(from: indexURL, verifier: indexVerifier)
        if arguments.first == "verify-index" {
            if arguments.contains("--expect-empty"), !releases.isEmpty {
                throw ToolError.probeMismatch("stable index unexpectedly contains Providers")
            }
            try printJSON(["ok": true, "release_count": releases.count, "index_signature": "verified"])
            return
        }
#if arch(arm64)
        let architecture = "arm64"
#else
        let architecture = "x86_64"
#endif
        let version = try argument("--version", in: arguments)
        guard let release = releases.first(where: {
            $0.providerID == "netvplayer.diagnostics" && $0.version == version
                && ($0.architectures.contains(architecture) || $0.architectures == ["universal2"])
        }) else {
            throw ToolError.probeMismatch("no matching source-free diagnostic release")
        }
        let verifier = try ProviderManifestVerifier(
            publicKeyData: publicKey(at: URL(fileURLWithPath: try argument("--public-key", in: arguments))),
            shellVersion: try argument("--shell-version", in: arguments)
        )
        let store = ProviderPackageStore(
            rootURL: URL(fileURLWithPath: try argument("--store", in: arguments), isDirectory: true),
            verifier: verifier
        )
        let manager = ProviderManager(store: store)
        do {
            _ = try await manager.install(release: release, using: distribution)
            let initialized = try await manager.request(ProviderRequest(
                providerID: release.providerID, operation: .initialize, arguments: ["extend": .string("")]
            ))
            let response = try await manager.request(ProviderRequest(
                providerID: release.providerID, operation: .action, arguments: ["action": .string("probe")]
            ))
            guard initialized.ok, response.ok,
                  response.result == .object(["diagnostic": .string("ok"), "contains_sources": .bool(false)]) else {
                throw ToolError.probeMismatch("diagnostic returned unexpected content")
            }
            await manager.shutdownAll()
            try printJSON(["ok": true, "provider_id": release.providerID, "version": version,
                           "architecture": architecture, "contains_sources": false,
                           "download_install_handshake_action": "passed"])
        } catch {
            await manager.shutdownAll()
            throw error
        }
    }

    private static func probeQuickJS(arguments: [String]) async throws {
        let manifestURL = URL(fileURLWithPath: try argument("--manifest", in: arguments))
        let package = URL(fileURLWithPath: try argument("--package", in: arguments), isDirectory: true)
        let state = URL(fileURLWithPath: try argument("--state", in: arguments), isDirectory: true)
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        var command = try ProviderCommandBuilder.command(
            manifest: manifest,
            packageRoot: package,
            stateDirectoryURL: state
        )
        if let index = arguments.firstIndex(of: "--http-fixture-url"), arguments.indices.contains(index + 1) {
            command.environment["NETVPLAYER_PROVIDER_HTTP_FIXTURE_URL"] = arguments[index + 1]
        }
        let client = ProviderProcessClient(command: command)
        do {
            let handshake = try await client.request(
                ProviderRequest(
                    providerID: manifest.providerID,
                    operation: .handshake,
                    arguments: ["protocol": .number(Double(manifest.protocolVersion))]
                ),
                timeout: .seconds(10)
            )
            guard handshake.ok else {
                throw ToolError.probeMismatch("handshake returned an error")
            }
            let initialized = try await client.request(
                ProviderRequest(
                    providerID: manifest.providerID,
                    operation: .initialize,
                    arguments: ["extend": .string("")]
                ),
                timeout: .seconds(10)
            )
            let expected = ProviderJSONValue.object([
                "module": .object([
                    "asset": .bool(true),
                    "lib": .bool(true),
                    "missing": .bool(true),
                    "unsupported": .bool(true),
                    "http": .bool(true),
                ]),
                "local": .object([
                    "legacy": .string("from-android"),
                    "token": .string("persisted"),
                ]),
                "text": .object([
                    "s2t": .string("簡體中文"),
                    "t2s": .string("繁体中文"),
                ]),
            ])
            guard initialized.ok, initialized.result == expected else {
                let actual = initialized.result.flatMap { try? JSONEncoder.providerCanonical.encode($0) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? "null"
                throw ToolError.probeMismatch("init result did not match the Swift host contract: \(actual)")
            }
            let proxy = try await client.request(
                ProviderRequest(
                    providerID: manifest.providerID,
                    operation: .proxy,
                    arguments: ["parameters": .object(["mode": .string("bytes")])]
                ),
                timeout: .seconds(10)
            )
            guard proxy.ok, let payload = proxy.proxy else {
                throw ToolError.probeMismatch("proxy response was missing")
            }
            let adapted = try ProviderProxyResponseAdapter.response(from: payload)
            guard adapted.statusCode == 206,
                  adapted.contentType == "application/octet-stream",
                  adapted.headers["X-Sandbox-Proxy"] == "quickjs",
                  adapted.data == Data([0, 1, 2, 255]) else {
                throw ToolError.probeMismatch("proxy data plane did not match")
            }
            let shutdown = try await client.request(
                ProviderRequest(providerID: manifest.providerID, operation: .shutdown),
                timeout: .seconds(10)
            )
            guard shutdown.ok else {
                throw ToolError.probeMismatch("shutdown returned an error")
            }
            await client.stop(graceful: false)

            let stateFile = state.appendingPathComponent("quickjs-local.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: stateFile.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            guard mode == 0o600 else {
                throw ToolError.probeMismatch("persistence file mode was \(String(mode, radix: 8))")
            }
            try printJSON([
                "ok": true,
                "provider_id": manifest.providerID,
                "handshake": true,
                "init": true,
                "shutdown": true,
                "swift_persistence_backend": true,
                "module_http": true,
                "proxy_data_plane": true,
                "state_file_mode": mode,
            ])
        } catch {
            await client.stop(graceful: false)
            throw error
        }
    }

    private static func probeQuickJSBili(arguments: [String]) async throws {
        let manifestURL = URL(fileURLWithPath: try argument("--manifest", in: arguments))
        let package = URL(fileURLWithPath: try argument("--package", in: arguments), isDirectory: true)
        let state = URL(fileURLWithPath: try argument("--state", in: arguments), isDirectory: true)
        let apiBase = optionalArgument("--api-base", in: arguments) ?? ""
        let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(contentsOf: manifestURL))
        let command = try ProviderCommandBuilder.command(
            manifest: manifest,
            packageRoot: package,
            stateDirectoryURL: state
        )
        let client = ProviderProcessClient(command: command)
        do {
            let handshake = try await request(
                client: client,
                manifest: manifest,
                operation: .handshake,
                arguments: ["protocol": .number(Double(manifest.protocolVersion))],
                timeout: .seconds(10)
            )
            let handshakeObject = try object(handshake.result, name: "handshake")
            guard handshakeObject["runtime"] == .string("quickjs") else {
                throw ToolError.probeMismatch("Bilibili handshake did not use QuickJS")
            }
            _ = try await request(
                client: client,
                manifest: manifest,
                operation: .initialize,
                arguments: ["extend": .string(apiBase)],
                timeout: .seconds(10)
            )
            let home = try await request(
                client: client,
                manifest: manifest,
                operation: .home,
                arguments: ["filter": .bool(true)],
                timeout: .seconds(30)
            )
            let homeItems = try list(home.result, name: "home")
            guard let first = homeItems.first else {
                throw ToolError.probeMismatch("Bilibili home returned no items")
            }
            let firstID = try string(try object(first, name: "home item")["vod_id"], name: "vod_id")

            let category = try await request(
                client: client,
                manifest: manifest,
                operation: .category,
                arguments: [
                    "category_id": .string("documentary"),
                    "page": .string("1"),
                    "filter": .bool(true),
                    "extend": .object(["order": .string("totalrank"), "duration": .string("0")]),
                ],
                timeout: .seconds(30)
            )
            let categoryItems = try list(category.result, name: "category")
            guard !categoryItems.isEmpty else {
                throw ToolError.probeMismatch("Bilibili category returned no items")
            }
            let search = try await request(
                client: client,
                manifest: manifest,
                operation: .search,
                arguments: ["keyword": .string("公开课"), "page": .string("1")],
                timeout: .seconds(30)
            )
            let searchItems = try list(search.result, name: "search")
            guard !searchItems.isEmpty else {
                throw ToolError.probeMismatch("Bilibili search returned no items")
            }
            let detail = try await request(
                client: client,
                manifest: manifest,
                operation: .detail,
                arguments: ["ids": .array([.string(firstID)])],
                timeout: .seconds(30)
            )
            let detailItems = try list(detail.result, name: "detail")
            guard let detailItem = detailItems.first else {
                throw ToolError.probeMismatch("Bilibili detail returned no items")
            }
            let playURL = try string(
                try object(detailItem, name: "detail item")["vod_play_url"],
                name: "vod_play_url"
            )
            guard let episodeID = playURL.split(separator: "$", maxSplits: 1).last.map(String.init),
                  episodeID.hasPrefix("bilibili://") else {
                throw ToolError.probeMismatch("Bilibili detail returned an invalid playback ID")
            }
            let player = try await request(
                client: client,
                manifest: manifest,
                operation: .player,
                arguments: [
                    "flag": .string("Bilibili"),
                    "id": .string(episodeID),
                    "vip_flags": .array([]),
                ],
                timeout: .seconds(30)
            )
            let playerObject = try object(player.result, name: "player")
            let mediaURL = try string(playerObject["url"], name: "player url")
            let format = try string(playerObject["format"], name: "player format")
            guard mediaURL.hasPrefix("https://"), ["bili-mp4", "dash"].contains(format) else {
                throw ToolError.probeMismatch("Bilibili player returned an invalid media candidate")
            }
            _ = try await request(
                client: client,
                manifest: manifest,
                operation: .shutdown,
                timeout: .seconds(10)
            )
            await client.stop(graceful: false)
            try printJSON([
                "ok": true,
                "provider_id": manifest.providerID,
                "runtime": "quickjs",
                "swift_http_host": true,
                "home_count": homeItems.count,
                "category_count": categoryItems.count,
                "search_count": searchItems.count,
                "detail_count": detailItems.count,
                "player_format": format,
                "player_url_https": true,
                "shutdown": true,
            ])
        } catch {
            await client.stop(graceful: false)
            throw error
        }
    }

    private static func request(
        client: ProviderProcessClient,
        manifest: ProviderManifest,
        operation: ProviderOperation,
        arguments: [String: ProviderJSONValue] = [:],
        timeout: Duration
    ) async throws -> ProviderResponse {
        let response = try await client.request(
            ProviderRequest(providerID: manifest.providerID, operation: operation, arguments: arguments),
            timeout: timeout
        )
        guard response.ok else {
            throw ToolError.probeMismatch("Bilibili \(operation.rawValue) returned an error")
        }
        return response
    }

    private static func list(_ value: ProviderJSONValue?, name: String) throws -> [ProviderJSONValue] {
        let object = try object(value, name: name)
        guard case .array(let values) = object["list"] else {
            throw ToolError.probeMismatch("Bilibili \(name) result had no list")
        }
        return values
    }

    private static func object(_ value: ProviderJSONValue?, name: String) throws -> [String: ProviderJSONValue] {
        guard case .object(let values) = value else {
            throw ToolError.probeMismatch("Bilibili \(name) result was not an object")
        }
        return values
    }

    private static func string(_ value: ProviderJSONValue?, name: String) throws -> String {
        guard case .string(let value) = value, !value.isEmpty else {
            throw ToolError.probeMismatch("Bilibili \(name) was missing")
        }
        return value
    }

    private static func optionalArgument(_ name: String, in values: [String]) -> String? {
        guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
        return values[index + 1]
    }
}
