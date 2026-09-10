import Foundation
import ProviderSDK
import QuickJSRuntime

public struct ProviderCommand: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var currentDirectoryURL: URL
    public var stateDirectoryURL: URL
    public var environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        stateDirectoryURL: URL,
        environment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.stateDirectoryURL = stateDirectoryURL
        self.environment = environment
    }
}

public enum ProviderCommandError: LocalizedError, Equatable, Sendable {
    case androidDexNeedsPort
    case runtimeMissing

    public var errorDescription: String? {
        switch self {
        case .androidDexNeedsPort: return "Android Dex Provider requires a compatibility port"
        case .runtimeMissing: return "Provider runtime executable is missing"
        }
    }
}

public enum ProviderCommandBuilder {
    public static func command(
        manifest: ProviderManifest,
        packageRoot: URL,
        stateDirectoryURL: URL
    ) throws -> ProviderCommand {
        let runner = try ProviderManifestVerifier.resolve(relativePath: manifest.runner, inside: packageRoot)
        let entrypoint = try ProviderManifestVerifier.resolve(relativePath: manifest.entrypoint, inside: packageRoot)
        var arguments: [String]
        var executable: URL

        switch manifest.runtime {
        case .java:
            guard let runtimePath = manifest.runtimeExecutable else { throw ProviderCommandError.runtimeMissing }
            executable = try ProviderManifestVerifier.resolve(relativePath: runtimePath, inside: packageRoot)
            arguments = ["-jar", runner.path, "--provider", entrypoint.path]
            if let providerClass = manifest.providerClass, !providerClass.isEmpty {
                arguments += ["--class", providerClass]
            }
        case .python:
            guard let runtimePath = manifest.runtimeExecutable else { throw ProviderCommandError.runtimeMissing }
            executable = try ProviderManifestVerifier.resolve(relativePath: runtimePath, inside: packageRoot)
            arguments = ["-I", "-S", runner.path, "--provider", entrypoint.path]
            if let providerClass = manifest.providerClass, !providerClass.isEmpty {
                arguments += ["--class", providerClass]
            }
        case .javaScript:
            if let runtimePath = manifest.runtimeExecutable {
                executable = try ProviderManifestVerifier.resolve(relativePath: runtimePath, inside: packageRoot)
                arguments = [runner.path, "--provider", entrypoint.path]
            } else {
                executable = runner
                arguments = ["--provider", entrypoint.path]
            }
            if let providerClass = manifest.providerClass, !providerClass.isEmpty {
                arguments += ["--class", providerClass]
            }
        case .quickJS:
            guard let runtimePath = manifest.runtimeExecutable else { throw ProviderCommandError.runtimeMissing }
            let runtimeURL = try ProviderManifestVerifier.resolve(relativePath: runtimePath, inside: packageRoot)
            guard let location = QuickJSRuntimeLocator.locate(
                runtimeURL: runtimeURL,
                source: .providerPackage
            ) else {
                throw ProviderCommandError.runtimeMissing
            }
            executable = location.executableURL
            arguments = location.commandArguments([runner.path, "--provider", entrypoint.path])
            if let providerClass = manifest.providerClass, !providerClass.isEmpty {
                arguments += ["--class", providerClass]
            }
        case .androidDex:
            throw ProviderCommandError.androidDexNeedsPort
        }

        if let sandbox = manifest.sandbox {
            let runtimeExecutable = executable
            let runtimeArguments = arguments
            executable = try ProviderSandboxVerifier.verify(
                sandbox,
                providerID: manifest.providerID,
                packageRoot: packageRoot,
                stateDirectory: stateDirectoryURL
            )
            arguments = ["--", runtimeExecutable.path] + runtimeArguments
        }

        var environment = [
            "NETVPLAYER_PROVIDER_ID": manifest.providerID,
            "NETVPLAYER_PROVIDER_ROOT": packageRoot.path,
            "NETVPLAYER_PROVIDER_STATE": stateDirectoryURL.path,
            "NETVPLAYER_PROVIDER_PROTOCOL": String(manifest.protocolVersion),
            "NETVPLAYER_PROVIDER_HOST_CAPABILITIES": manifest.hostCapabilities.map(\.rawValue).joined(separator: ","),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1"
        ]
        if manifest.sandbox != nil {
            environment["NETVPLAYER_PROVIDER_SANDBOX"] = "app-sandbox-v2"
        }
        return ProviderCommand(
            executableURL: executable,
            arguments: arguments,
            currentDirectoryURL: packageRoot,
            stateDirectoryURL: stateDirectoryURL,
            environment: environment
        )
    }
}
