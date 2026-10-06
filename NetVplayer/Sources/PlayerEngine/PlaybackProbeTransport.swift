import Foundation
import Models
import Networking

enum PlaybackProbeTransport {
    static func client(for spec: PlaySpec, using client: HTTPClient) -> HTTPClient {
        let options = PlaybackTransportOptions.resolved(spec.mpvOptions, url: spec.url,
                                                        direct: spec.metadata["network.explicitDirect"] == "true")
        guard let proxy = options["http-proxy"] else { return client }
        return client.withExplicitProxy(proxy.isEmpty ? nil : URL(string: proxy))
    }
}
