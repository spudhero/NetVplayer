import Foundation
import Testing
import DriveEngine
import Storage
import Models

/// Opt-in account verification. The private fixture stays outside the repository;
/// credentials come from the app vault, and no personal files are deleted.
@Test func baiduFileIdentityLiveVerificationWhenEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let fixturePath = environment["NETVPLAYER_BAIDU_IDENTITY_LIVE_FIXTURE"], !fixturePath.isEmpty else { return }
    let fixture = try JSONDecoder().decode(BaiduIdentityLiveFixture.self,
        from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
    guard let parsed = DriveFileReference.parse(fixture.referenceURL) else { throw BaiduIdentityLiveError.invalidFixture }
    let reference = DriveFileReference(provider: .baidu, shareURL: parsed.shareURL, pwdID: parsed.pwdID,
        passcode: parsed.passcode, fid: parsed.fid, fidToken: fixture.legacyRecord.fidToken,
        fileName: parsed.fileName, collectionName: parsed.collectionName, size: parsed.size,
        formatType: parsed.formatType, filePath: parsed.filePath)
    let savedCookie = try LocalCredentialStore().read("baiduCookie")
    let cookie = try #require(savedCookie, "Baidu account must already be authorized")
    let output = URL(fileURLWithPath: fixture.outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let store = DriveSavedFileStore(fileURL: output.appendingPathComponent("private-saved-record.json"))
    if fixture.repairLegacyCache { try await store.save(fixture.legacyRecord) }
    let link = try await BaiduDriveClient(savedFileStore: store).link(reference: reference,
        credential: .cookie(provider: .baidu, value: cookie))
    #expect(link.metadata[DrivePlaybackMetadataKey.fid] != reference.fid)
    #expect(link.metadata[DrivePlaybackMetadataKey.size] == String(fixture.expectedSize))
    #expect(link.headers["Cookie"] == nil)

    var request = URLRequest(url: try #require(URL(string: link.url)))
    request.httpMethod = "HEAD"
    request.timeoutInterval = 25
    for (key, value) in link.headers { request.setValue(value, forHTTPHeaderField: key) }
    let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.expectedContentLength == fixture.expectedSize)
    #expect(http.value(forHTTPHeaderField: "Content-MD5") == fixture.expectedContentMD5)

    let frame = output.appendingPathComponent("frame.png")
    let decoder = Process()
    decoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    decoder.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-rw_timeout", "15000000",
        "-user_agent", BaiduDriveClient.playbackUserAgent, "-ss", "90", "-i", link.url,
        "-an", "-frames:v", "1", "-vf", "scale=960:-2", "-threads", "2", "-y", frame.path]
    decoder.standardOutput = FileHandle.nullDevice
    decoder.standardError = FileHandle.nullDevice
    try decoder.run()
    let deadline = Date().addingTimeInterval(60)
    while decoder.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
    if decoder.isRunning { decoder.terminate() }
    decoder.waitUntilExit()
    guard decoder.terminationStatus == 0, FileManager.default.fileExists(atPath: frame.path) else {
        throw BaiduIdentityLiveError.frameDecodeFailed
    }
    let summary: [String: Any] = [
        "mode": fixture.repairLegacyCache ? "legacy-cache-repair" : "new-transfer",
        "savedFileName": link.metadata[DrivePlaybackMetadataKey.fileName] ?? "",
        "sourceIDWasReused": link.metadata[DrivePlaybackMetadataKey.fid] == reference.fid,
        "expectedBytes": fixture.expectedSize,
        "actualBytes": http.expectedContentLength,
        "contentFingerprintMatches": http.value(forHTTPHeaderField: "Content-MD5") == fixture.expectedContentMD5,
        "decodedFrameAtSeconds": 90
    ]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("result.json"))
    print("[BAIDU_IDENTITY_LIVE] mode=\(fixture.repairLegacyCache ? "repair" : "transfer") bytes=\(http.expectedContentLength) decodedFrame=true")
}

private struct BaiduIdentityLiveFixture: Decodable {
    let referenceURL: String
    let legacyRecord: DriveSavedFileRecord
    let expectedSize: Int64
    let expectedContentMD5: String
    let outputDirectory: String
    let repairLegacyCache: Bool
}

private enum BaiduIdentityLiveError: Error {
    case invalidFixture
    case frameDecodeFailed
}
