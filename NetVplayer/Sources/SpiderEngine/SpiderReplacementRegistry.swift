// SpiderEngine/SpiderReplacementRegistry.swift
// Runtime-neutral Provider replacement and registration table.

import Foundation
import Models
import ProviderRuntime
import ProviderSDK

public actor SpiderReplacementRegistry {
    public static let shared = SpiderReplacementRegistry()

    private var replacements: [String: Site] = [:]
    private var publicUtilityProviders: [String: any SiteContentProvider] = [:]
    private var nativeProviders: [String: any SiteContentProvider] = [:]
    private var nativeKeyedProviders: [String: any SiteContentProvider] = [:]
    private var remoteProviders: [String: any SiteContentProvider] = [:]
    private var remoteBindingKeys: [String: Set<String>] = [:]
    private var remoteBindingOwners: [String: String] = [:]
    private var remoteProxyProviderIDs: Set<String> = []
    private var remoteProxyRoutes: [String: RemoteProxyRoute] = [:]

    public init() {}

    public func register(originalAPI: String, replacement: Site) {
        guard !originalAPI.isEmpty else { return }
        replacements[normalize(originalAPI)] = replacement
    }

    public func register(originalKey: String, provider: any SiteContentProvider) {
        guard !originalKey.isEmpty else { return }
        nativeProviders[normalize(originalKey)] = provider
    }

    public func register(originalAPI: String, provider: any SiteContentProvider) {
        guard !originalAPI.isEmpty else { return }
        nativeProviders[normalize(originalAPI)] = provider
    }

    public func register(originalKey: String, originalAPI: String, provider: any SiteContentProvider) {
        guard !originalKey.isEmpty, !originalAPI.isEmpty else { return }
        nativeKeyedProviders[normalizeKeyed(originalKey, originalAPI)] = provider
    }

    /// Registers utility providers that are present in both the public shell and
    /// the private legacy build. Their aliases remain shell-owned even when a
    /// signed site package declares the same binding.
    public func registerPublicUtilityProviders(
        myDrive: any SiteContentProvider,
        configurationCenter: any SiteContentProvider
    ) {
        for key in ["MDrive", "MyDrive", "我的网盘", "我的云盘"] {
            publicUtilityProviders[normalize(key)] = myDrive
        }
        for api in ["csp_MyDrive", "csp_MyDriveGuard", "MyDrive", "MyDriveGuard"] {
            publicUtilityProviders[normalize(api)] = myDrive
        }

        for key in ["Config", "配置中心"] {
            publicUtilityProviders[normalize(key)] = configurationCenter
        }
        for api in ["csp_Config", "csp_ConfigGuard", "Config", "ConfigGuard"] {
            publicUtilityProviders[normalize(api)] = configurationCenter
        }
    }

    public func registerRemote(
        originalAPI: String,
        providerID: String,
        manager: ProviderManager
    ) {
        let normalized = normalize(originalAPI)
        guard !normalized.isEmpty else { return }
        remoteProviders[normalized] = RemoteSiteContentProvider(providerID: providerID, manager: manager)
        remoteBindingOwners[normalized] = providerID
        remoteBindingKeys[providerID, default: []].insert(normalized)
    }

    /// Registers only the exact source identities authorized by a signed manifest.
    public func registerRemote(
        manifest: ProviderManifest,
        manager: ProviderManager
    ) {
        removeRemoteBindings(providerID: manifest.providerID)
        if manifest.capabilities.contains(.proxy) {
            remoteProxyProviderIDs.insert(manifest.providerID)
        }
        let provider = RemoteSiteContentProvider(providerID: manifest.providerID, manager: manager)
        var bindings = Set<String>()
        for binding in manifest.sourceBindings ?? [] {
            for key in binding.originalKeys {
                let normalized = normalize(key)
                guard !normalized.isEmpty else { continue }
                remoteProviders[normalized] = provider
                remoteBindingOwners[normalized] = manifest.providerID
                bindings.insert(normalized)
            }
            for api in binding.originalAPIs {
                let normalized = normalize(api)
                guard !normalized.isEmpty else { continue }
                remoteProviders[normalized] = provider
                remoteBindingOwners[normalized] = manifest.providerID
                bindings.insert(normalized)
            }
        }
        remoteBindingKeys[manifest.providerID] = bindings
    }

    public func replacement(for site: Site) -> Site? {
        lookupKeys(for: site).compactMap { replacements[$0] }.first
    }

    public func nativeProvider(for site: Site) -> (any SiteContentProvider)? {
        if let provider = nativeKeyedProviders[normalizeKeyed(site.key, site.api)] {
            return provider
        }
        for key in lookupKeys(for: site) {
            if let provider = publicUtilityProviders[key] { return provider }
        }
        for key in lookupKeys(for: site) {
            if let provider = remoteProviders[key] { return provider }
        }
        for key in lookupKeys(for: site) {
            if let provider = nativeProviders[key] { return provider }
        }
        return nil
    }

    public func hasReplacement(for site: Site) -> Bool {
        replacement(for: site) != nil || nativeProvider(for: site) != nil
    }

    func registerRemoteProxyRoute(site: Site, providerID: String, manager: ProviderManager) {
        guard remoteProxyProviderIDs.contains(providerID),
              lookupKeys(for: site).contains(where: { remoteBindingOwners[$0] == providerID }) else {
            return
        }
        let route = RemoteProxyRoute(providerID: providerID, manager: manager, site: site)
        for key in lookupKeys(for: site) where !key.isEmpty {
            remoteProxyRoutes[key] = route
        }
    }

    public func remoteProxyResponse(parameters: [String: String]) async throws -> ProxyResponse? {
        guard parameters["from"]?.lowercased() == "catvod",
              let siteKey = parameters["siteKey"],
              let route = remoteProxyRoutes[normalize(siteKey)] else {
            return nil
        }
        return try await route.manager.proxy(
            providerID: route.providerID,
            site: route.site,
            parameters: parameters
        )
    }

    public func clear() {
        replacements.removeAll()
        publicUtilityProviders.removeAll()
        nativeProviders.removeAll()
        nativeKeyedProviders.removeAll()
        remoteProviders.removeAll()
        remoteBindingKeys.removeAll()
        remoteBindingOwners.removeAll()
        remoteProxyProviderIDs.removeAll()
        remoteProxyRoutes.removeAll()
    }

    private func removeRemoteBindings(providerID: String) {
        remoteProxyProviderIDs.remove(providerID)
        remoteProxyRoutes = remoteProxyRoutes.filter { $0.value.providerID != providerID }
        for key in remoteBindingKeys.removeValue(forKey: providerID) ?? [] {
            guard remoteBindingOwners[key] == providerID else { continue }
            remoteProviders.removeValue(forKey: key)
            remoteBindingOwners.removeValue(forKey: key)
        }
    }

    private func lookupKeys(for site: Site) -> [String] {
        [
            site.key,
            site.api,
            site.api.replacingOccurrences(of: "csp_", with: "")
        ].map(normalize)
    }

    private func normalize(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix("()") {
            normalized.removeLast(2)
        }
        return normalized
    }

    private func normalizeKeyed(_ key: String, _ api: String) -> String {
        "\(normalize(key))::\(normalize(api.replacingOccurrences(of: "csp_", with: "")))"
    }
}

private struct RemoteProxyRoute: Sendable {
    let providerID: String
    let manager: ProviderManager
    let site: Site
}
