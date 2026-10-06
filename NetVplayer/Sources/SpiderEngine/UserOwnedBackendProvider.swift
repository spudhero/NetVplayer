import Foundation
import Models
import Networking
import ProviderSDK

public enum UserOwnedBackendProviderError: Error, Equatable, Sendable {
    case invalidIntegrationMode
    case unsupportedBackend(ProviderBackendKind)
    case insecureHTTPNotAllowed
    case localNetworkNotAllowed
    case credentialForwardingNotAllowed
}

/// Adapter for explicitly configured, user-owned data backends.
///
/// The legacy provider implementations remain private to SpiderEngine. This adapter
/// only projects a validated descriptor into a `Site` with no executable fields.
public struct UserOwnedBackendProvider: SiteContentProvider, Sendable {
    public let descriptor: ProviderSourceDescriptor

    private let backendKind: ProviderBackendKind
    private let alist: AListNativeProvider?
    private let webDAV: WebDAVNativeProvider?
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
    private let cms: JsonCmsNativeProvider?
#endif
    private let credentialHeaders: [String: String]

    public init(
        descriptor: ProviderSourceDescriptor,
        httpClient: HTTPClient = .shared,
        webDAVSession: URLSession = .shared,
        credentialHeaders: [String: String] = [:]
    ) throws {
        try descriptor.validate()
        guard descriptor.integrationMode == .userOwnedBackend else {
            throw UserOwnedBackendProviderError.invalidIntegrationMode
        }
        guard let backendKind = descriptor.backendKind else {
            throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
        }
        guard backendKind == .webdav || backendKind == .alist || backendKind == .openList || backendKind == .tvboxCompatible else {
            throw UserOwnedBackendProviderError.unsupportedBackend(descriptor.backendKind ?? .tvboxCompatible)
        }
        let permissions = descriptor.effectiveBackendPermissions
        if descriptor.endpointReference?.lowercased().hasPrefix("http://") == true,
           !permissions.allowsInsecureHTTP {
            throw UserOwnedBackendProviderError.insecureHTTPNotAllowed
        }
        if descriptor.endpointScope == .localNetwork, !permissions.allowsLocalNetwork {
            throw UserOwnedBackendProviderError.localNetworkNotAllowed
        }
        if !credentialHeaders.isEmpty,
           (!permissions.allowsCredentialForwarding || descriptor.credentialReference == nil) {
            throw UserOwnedBackendProviderError.credentialForwardingNotAllowed
        }
        guard let endpointURL = URL(string: descriptor.endpointReference ?? "") else {
            throw UserOwnedBackendProviderError.invalidIntegrationMode
        }

        self.descriptor = descriptor
        self.backendKind = backendKind
        self.credentialHeaders = credentialHeaders
        switch backendKind {
        case .webdav:
            self.webDAV = WebDAVNativeProvider(
                session: webDAVSession,
                defaultHeaders: credentialHeaders,
                allowedOrigin: endpointURL
            )
            self.alist = nil
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
            self.cms = nil
#endif
        case .alist, .openList:
            self.alist = AListNativeProvider(
                httpClient: httpClient.constrained(to: endpointURL),
                defaultHeaders: credentialHeaders
            )
            self.webDAV = nil
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
            self.cms = nil
#endif
        case .tvboxCompatible:
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
            self.alist = nil
            self.webDAV = nil
            self.cms = JsonCmsNativeProvider(
                baseURL: descriptor.endpointReference ?? "",
                siteName: descriptor.name,
                httpClient: httpClient.constrained(to: endpointURL)
            )
#else
            throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
#endif
        }
    }

    public func homeContent(site: Site) async throws -> Result {
        try await withBackend(site: site) { providerSite in
            switch backendKind {
            case .webdav:
                return try await webDAV!.homeContent(site: providerSite)
            case .alist, .openList:
                return try await alist!.homeContent(site: providerSite)
            case .tvboxCompatible:
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
                return try await cms!.homeContent(site: providerSite)
#else
                throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
#endif
            }
        }
    }

    public func homeVideoContent(site: Site) async throws -> Result? {
        nil
    }

    public func categoryContent(
        site: Site,
        tid: String,
        page: String,
        filter: Bool,
        extend: [String: String]
    ) async throws -> Result {
        try await withBackend(site: site) { providerSite in
            switch backendKind {
            case .webdav:
                return try await webDAV!.categoryContent(
                    site: providerSite,
                    tid: tid,
                    page: page,
                    filter: filter,
                    extend: extend
                )
            case .alist, .openList:
                return try await alist!.categoryContent(
                    site: providerSite,
                    tid: tid,
                    page: page,
                    filter: filter,
                    extend: extend
                )
            case .tvboxCompatible:
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
                return try await cms!.categoryContent(
                    site: providerSite,
                    tid: tid,
                    page: page,
                    filter: filter,
                    extend: extend
                )
#else
                throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
#endif
            }
        }
    }

    public func detailContent(site: Site, id: String) async throws -> Result {
        try await withBackend(site: site) { providerSite in
            switch backendKind {
            case .webdav:
                return try await webDAV!.detailContent(site: providerSite, id: id)
            case .alist, .openList:
                return try await alist!.detailContent(site: providerSite, id: id)
            case .tvboxCompatible:
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
                return try await cms!.detailContent(site: providerSite, id: id)
#else
                throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
#endif
            }
        }
    }

    public func playerContent(site: Site, flag: String, id: String) async throws -> Result {
        try await withBackend(site: site) { providerSite in
            switch backendKind {
            case .webdav:
                return try await webDAV!.playerContent(site: providerSite, flag: flag, id: id)
            case .alist, .openList:
                return try await alist!.playerContent(site: providerSite, flag: flag, id: id)
            case .tvboxCompatible:
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
                return try await cms!.playerContent(site: providerSite, flag: flag, id: id)
#else
                throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
#endif
            }
        }
    }

    public func searchContent(site: Site, keyword: String, quick: Bool, page: String) async throws -> Result {
        try await withBackend(site: site) { providerSite in
            switch backendKind {
            case .webdav:
                return try await webDAV!.searchContent(
                    site: providerSite,
                    keyword: keyword,
                    quick: quick,
                    page: page
                )
            case .alist, .openList:
                return try await alist!.searchContent(
                    site: providerSite,
                    keyword: keyword,
                    quick: quick,
                    page: page
                )
            case .tvboxCompatible:
#if NETVPLAYER_INCLUDE_PRIVATE_PROVIDERS
                return try await cms!.searchContent(
                    site: providerSite,
                    keyword: keyword,
                    quick: quick,
                    page: page
                )
#else
                throw UserOwnedBackendProviderError.unsupportedBackend(.tvboxCompatible)
#endif
            }
        }
    }

    private func withBackend<T: Sendable>(
        site: Site,
        _ operation: (Site) async throws -> T
    ) async throws -> T {
        try await operation(projectedSite(from: site))
    }

    private func projectedSite(from source: Site) -> Site {
        var projected = source
        projected.api = descriptor.endpointReference ?? ""
        projected.ext = ""
        projected.jar = ""
        projected.click = ""
        projected.playUrl = ""
        projected.header.merge(credentialHeaders) { _, new in new }
        if projected.name.isEmpty {
            projected.name = descriptor.name
        }
        return projected
    }
}
