import Darwin
import Foundation

enum LauncherError: LocalizedError {
    case missingCommand
    case relativeCommand(String)
    case embeddedNUL

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "usage: ProviderSandboxLauncher -- /absolute/path/to/runtime [arguments ...]"
        case .relativeCommand(let command):
            return "Provider runtime path must be absolute: \(command)"
        case .embeddedNUL:
            return "Provider runtime command contains an embedded NUL byte"
        }
    }
}

func launch() throws -> Never {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--" {
        arguments.removeFirst()
    }
    guard let executable = arguments.first else {
        throw LauncherError.missingCommand
    }
    guard executable.hasPrefix("/") else {
        throw LauncherError.relativeCommand(executable)
    }

    let cStrings = try arguments.map { argument -> UnsafeMutablePointer<CChar> in
        guard !argument.utf8.contains(0), let value = strdup(argument) else {
            throw LauncherError.embeddedNUL
        }
        return value
    }
    defer { cStrings.forEach { free($0) } }

    var argv: [UnsafeMutablePointer<CChar>?] = cStrings.map(Optional.some)
    argv.append(nil)
    execv(executable, &argv)
    let detail = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("Provider runtime exec failed: \(detail)\n".utf8))
    Darwin.exit(126)
}

do {
    try launch()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    Darwin.exit(64)
}
