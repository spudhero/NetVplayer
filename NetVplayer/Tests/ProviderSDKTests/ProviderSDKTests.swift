import Foundation
import Testing
@testable import ProviderSDK

@Test func providerManifestDefaultsOptionalHostCapabilitiesToEmpty() throws {
    let json = """
    {
      "provider_id": "fixture.no-host-capabilities",
      "version": "1.0.0",
      "protocol": 1,
      "shell_min_version": "1.0.0",
      "macos_min_version": "14.0",
      "architectures": ["arm64"],
      "runtime": "java",
      "entrypoint": "provider.jar",
      "runner": "runner.jar",
      "capabilities": ["home"],
      "assets": [],
      "license": "MIT",
      "status": "compatible",
      "revoked": false
    }
    """

    let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(json.utf8))

    #expect(manifest.hostCapabilities == [])
    #expect(manifest.sourceBindings == nil)
}

@Test func providerRequestUsesStableWireKeysAndIgnoresUnknownFields() throws {
    let json = """
    {
      "protocol": 1,
      "request_id": "request-1",
      "provider_id": "example.provider",
      "operation": "search",
      "arguments": {"keyword": "test"},
      "future_field": true
    }
    """

    let request = try JSONDecoder().decode(ProviderRequest.self, from: Data(json.utf8))
    #expect(request.protocolVersion == 1)
    #expect(request.requestID == "request-1")
    #expect(request.operation == .search)
    #expect(request.arguments["keyword"] == .string("test"))

    let encoded = try JSONEncoder.providerCanonical.encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["request_id"] as? String == "request-1")
    #expect(object["provider_id"] as? String == "example.provider")
    #expect(object["protocol"] as? Int == 1)
}

@Test func providerManifestDecodesStableSourceBindingKeys() throws {
    let json = """
    {
      "provider_id": "fixture.quickjs",
      "version": "1.0.0",
      "protocol": 1,
      "shell_min_version": "1.0.0",
      "shell_max_version": null,
      "macos_min_version": "14.0",
      "architectures": ["arm64"],
      "runtime": "quickjs",
      "entrypoint": "provider.mjs",
      "runner": "provider_runner.mjs",
      "runtime_executable": "qjs",
      "provider_class": "Spider",
      "capabilities": ["home"],
      "host_capabilities": ["http"],
      "source_bindings": [{
        "original_keys": ["csp_Fixture"],
        "original_apis": ["https://example.invalid/provider.js"]
      }],
      "assets": [],
      "license": "MIT",
      "status": "compatible",
      "revoked": false
    }
    """

    let manifest = try JSONDecoder().decode(ProviderManifest.self, from: Data(json.utf8))
    #expect(manifest.sourceBindings == [ProviderSourceBinding(
        originalKeys: ["csp_Fixture"],
        originalAPIs: ["https://example.invalid/provider.js"]
    )])
    let encoded = try JSONEncoder.providerCanonical.encode(manifest)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let bindings = try #require(object["source_bindings"] as? [[String: Any]])
    #expect(bindings.first?["original_keys"] as? [String] == ["csp_Fixture"])
    #expect(bindings.first?["original_apis"] as? [String] == ["https://example.invalid/provider.js"])
}

@Test func providerResponseDecodesTypedResultAndProxyBytes() throws {
    struct Payload: Codable, Equatable { let value: String }
    let value = try ProviderJSONValue.encode(Payload(value: "ok"))
    let response = ProviderResponse(
        requestID: "request-2",
        ok: true,
        result: value,
        proxy: ProviderProxyPayload(
            statusCode: 206,
            contentType: "video/mp2t",
            bodyBase64: Data([0, 1, 2]).base64EncodedString(),
            headers: ["Accept-Ranges": "bytes"]
        )
    )

    #expect(try response.decodedResult(Payload.self) == Payload(value: "ok"))
    #expect(response.proxy?.statusCode == 206)
    #expect(Data(base64Encoded: response.proxy?.bodyBase64 ?? "") == Data([0, 1, 2]))
}

@Test func providerDiagnosticsRedactsURLsAndSensitiveHeaders() {
    let value = ProviderDiagnostics.redact(
        "url=https://example.invalid/video.m3u8?token=secret\nCookie: session=secret\nAuthorization: Bearer secret"
    )

    #expect(!value.contains("example.invalid"))
    #expect(!value.contains("secret"))
    #expect(value.contains("<redacted-url>"))
    #expect(value.contains("Cookie: <redacted>"))
    #expect(value.contains("Authorization: <redacted>"))
}

@Test func providerDiagnosticEventUsesStructuredRedactedJSONL() throws {
    let event = ProviderDiagnosticEvent(
        timestamp: Date(timeIntervalSince1970: 0),
        level: .error,
        category: .request,
        code: .requestFailed,
        providerID: "fixture.provider",
        requestID: "request-1",
        processID: 42,
        statusCode: 502,
        contentType: "text/html",
        message: "GET https://example.invalid/play?token=secret Cookie: session=secret"
    )

    let line = try ProviderDiagnostics.jsonLine(for: event)
    let text = try #require(String(data: line, encoding: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])

    #expect(text.hasSuffix("\n"))
    #expect(!text.contains("example.invalid"))
    #expect(!text.contains("session=secret"))
    #expect(object["category"] as? String == "request")
    #expect(object["code"] as? String == "request.failed")
    #expect(object["provider_id"] as? String == "fixture.provider")
    #expect(object["request_id"] as? String == "request-1")
    #expect(object["process_id"] as? Int == 42)
    #expect(object["status_code"] as? Int == 502)
    #expect(object["content_type"] as? String == "text/html")
}

@Test func sourceDescriptorUsesStableKeysAndValidatesUserOwnedBackend() throws {
    let descriptor = try ProviderSourceDescriptor(
        providerID: "nas.movies",
        name: "家庭 NAS",
        integrationMode: .userOwnedBackend,
        backendKind: .openList,
        endpointReference: "http://nas.local:5244",
        credentialReference: "keychain:nas.movies",
        backendPermissions: ProviderBackendPermissions(
            allowsInsecureHTTP: true,
            allowsLocalNetwork: true,
            allowsCredentialForwarding: true
        ),
        capabilities: [.vod, .search, .player]
    ).validated()

    let encoded = try JSONEncoder.providerCanonical.encode(descriptor)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["integration_mode"] as? String == "user-owned-backend")
    #expect(object["backend_kind"] as? String == "openlist")
    #expect(object["endpoint_ref"] as? String == "http://nas.local:5244")
    #expect(object["credential_ref"] as? String == "keychain:nas.movies")
    let permissions = try #require(object["backend_permissions"] as? [String: Any])
    #expect(permissions["allow_insecure_http"] as? Bool == true)
    #expect(permissions["allow_local_network"] as? Bool == true)
    #expect(permissions["allow_credential_forwarding"] as? Bool == true)
    #expect(permissions["redirect_policy"] as? String == "same-origin-only")
    #expect(descriptor.endpointScope == .localNetwork)

    let decoded = try JSONDecoder().decode(ProviderSourceDescriptor.self, from: encoded)
    #expect(decoded == descriptor)
}

@Test func sourceDescriptorDefaultsUserOwnedBackendPermissionsToDeny() throws {
    let descriptor = ProviderSourceDescriptor(
        providerID: "nas.movies",
        name: "NAS",
        integrationMode: .userOwnedBackend,
        backendKind: .webdav,
        endpointReference: "https://192.168.1.10"
    )

    #expect(descriptor.endpointScope == .localNetwork)
    #expect(descriptor.effectiveBackendPermissions == .secureDefault)
    #expect(descriptor.effectiveBackendPermissions.redirectPolicy == .sameOriginOnly)
}

@Test func sourceDescriptorClassifiesLiteralAddressesWithoutTreatingDomainPrefixesAsIPv6() {
    func scope(_ endpoint: String) -> ProviderEndpointScope? {
        ProviderSourceDescriptor(
            providerID: "scope.fixture",
            name: "Scope Fixture",
            integrationMode: .userOwnedBackend,
            backendKind: .webdav,
            endpointReference: endpoint
        ).endpointScope
    }

    #expect(scope("https://fcast.example") == .publicInternet)
    #expect(scope("https://[fc00::1]") == .localNetwork)
    #expect(scope("https://[fe80::1]") == .localNetwork)
    #expect(scope("https://[2001:db8::1]") == .publicInternet)
}

@Test func sourceDescriptorRejectsInvalidBackendEndpoints() {
    #expect(throws: ProviderSourceDescriptorValidationError.endpointContainsCredentials) {
        try ProviderSourceDescriptor(
            providerID: "nas.movies",
            name: "NAS",
            integrationMode: .userOwnedBackend,
            backendKind: .webdav,
            endpointReference: "https://user:password@example.invalid/dav"
        ).validate()
    }

    #expect(throws: ProviderSourceDescriptorValidationError.endpointSchemeNotAllowed("file")) {
        try ProviderSourceDescriptor(
            providerID: "nas.movies",
            name: "NAS",
            integrationMode: .userOwnedBackend,
            backendKind: .webdav,
            endpointReference: "file:///Users/example/Movies"
        ).validate()
    }

    #expect(throws: ProviderSourceDescriptorValidationError.backendKindRequired) {
        try ProviderSourceDescriptor(
            providerID: "nas.movies",
            name: "NAS",
            integrationMode: .userOwnedBackend,
            endpointReference: "https://example.invalid"
        ).validate()
    }

    #expect(throws: ProviderSourceDescriptorValidationError.invalidCredentialReference) {
        try ProviderSourceDescriptor(
            providerID: "nas.movies",
            name: "NAS",
            integrationMode: .userOwnedBackend,
            backendKind: .webdav,
            endpointReference: "https://example.invalid",
            credentialReference: "username:password",
            backendPermissions: ProviderBackendPermissions(allowsCredentialForwarding: true)
        ).validate()
    }

    #expect(throws: ProviderSourceDescriptorValidationError.credentialPermissionMismatch) {
        try ProviderSourceDescriptor(
            providerID: "nas.movies",
            name: "NAS",
            integrationMode: .userOwnedBackend,
            backendKind: .webdav,
            endpointReference: "https://example.invalid",
            credentialReference: "keychain:nas.movies"
        ).validate()
    }

    #expect(throws: ProviderSourceDescriptorValidationError.backendPermissionsNotAllowed) {
        try ProviderSourceDescriptor(
            providerID: "fixture.provider",
            name: "Fixture",
            integrationMode: .provider,
            backendPermissions: ProviderBackendPermissions(allowsLocalNetwork: true)
        ).validate()
    }
}

@Test func configOnlyValidationRejectsExecutableFieldsButAllowsDataAPI() throws {
    try ProviderSourceDescriptor.validateConfiguration(.object([
        "sites": .array([
            .object([
                "api": .string("https://example.invalid/api"),
                "name": .string("catalog")
            ])
        ])
    ]))

    #expect(throws: ProviderSourceDescriptorValidationError.forbiddenConfigurationField("sites[0].api")) {
        try ProviderSourceDescriptor.validateConfiguration(.object([
            "sites": .array([
                .object(["api": .string("https://example.invalid/drpy.min.js")])
            ])
        ]))
    }

    #expect(throws: ProviderSourceDescriptorValidationError.forbiddenConfigurationField("sites[0].spider")) {
        try ProviderSourceDescriptor.validateConfiguration(.object([
            "sites": .array([
                .object(["spider": .string("remote-provider")])
            ])
        ]))
    }

    #expect(throws: ProviderSourceDescriptorValidationError.forbiddenConfigurationField("sites[0].ext")) {
        try ProviderSourceDescriptor.validateConfiguration(.object([
            "sites": .array([
                .object(["ext": .string("base64(dynamic-loader)")])
            ])
        ]))
    }
}

@Test func providerCatalogKeepsRuntimePackagingSeparateFromDistributionReadiness() throws {
    let legacyJSON = Data(#"{"provider_id":"fixture","name":"Fixture","runtime":"js","capabilities":[],"dependencies":[],"compatibility":"compatible","network":"untested","playback_verified":false}"#.utf8)
    let legacy = try JSONDecoder().decode(ProviderCatalogRecord.self, from: legacyJSON)
    #expect(legacy.runtimePackaging == .untested)
    #expect(legacy.distributionReady == false)

    let current = ProviderCatalogRecord(
        providerID: "fixture",
        name: "Fixture",
        runtime: .javaScript,
        compatibility: .compatible,
        runnerVerified: true,
        parserVerified: true,
        runtimePackaging: .hostDependent,
        distributionReady: false
    )
    let encoded = try JSONEncoder.providerCanonical.encode(current)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["runtime_packaging"] as? String == "host-dependent")
    #expect(object["distribution_ready"] as? Bool == false)
}
