import Foundation
import ProxyServer

public enum RemoteProviderProxyBridge {
    public static func install(on server: ProxyServer = .shared) {
        server.rawProxyHandler = { parameters in
            try await SpiderReplacementRegistry.shared.remoteProxyResponse(parameters: parameters)
        }
    }
}
