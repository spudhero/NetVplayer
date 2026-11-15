import DriveEngine
import Models
import Testing
@testable import SpiderEngine

@Test func aiDjNativeAuthorizationRequiresARealHostAccount() async throws {
    let authorization = HostDriveAccountAuthorization(credentialProvider: { _ in nil }, drives: [.quark, .uc, .baidu], validator: { _ in
        Issue.record("Empty accounts must not contact the drive API")
        throw CancellationError()
    })
    do {
        try await authorization.validate()
        Issue.record("Missing accounts must not authorize playback")
    } catch DriveEngineError.loginRequired(let provider) { #expect(provider == .quark) }
}

@Test func aiDjNativeAuthorizationTriesAnotherSavedAccountAfterValidationFails() async throws {
    let calls = AiDjAccountCalls()
    let authorization = HostDriveAccountAuthorization(credentialProvider: { drive in
        drive == .quark || drive == .uc ? "local-test-cookie" : nil
    }, drives: [.quark, .uc, .baidu], validator: { credential in
        await calls.append(credential.provider)
        if credential.provider == .quark { throw DriveEngineError.loginRequired(.quark) }
        return credential
    })
    try await authorization.validate()
    #expect(await calls.values == [.quark, .uc])
}

@Test func aiDjNativeAuthorizationDoesNotUseAnAccountChangedDuringValidation() async throws {
    let account = AiDjChangingAccount()
    let authorization = HostDriveAccountAuthorization(credentialProvider: { _ in await account.cookie }, drives: [.quark, .uc, .baidu], validator: { credential in
        await account.replace()
        return credential
    })
    await #expect(throws: CancellationError.self) { try await authorization.validate() }
}

private actor AiDjAccountCalls {
    var values: [DriveProvider] = []
    func append(_ value: DriveProvider) { values.append(value) }
}

private actor AiDjChangingAccount {
    var cookie = "original-test-cookie"
    func replace() { cookie = "changed-test-cookie" }
}
