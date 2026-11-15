import Foundation

/// A torrent file, independent of ephemeral loopback ports, names and SDK sessions.
public struct MagnetFileIdentity: Codable, Equatable, Sendable {
    public let infoHash: String
    public let fileIndex: Int
    public let length: Int64

    public init?(infoHash: String, fileIndex: Int, length: Int64) {
        let hash = infoHash.lowercased()
        guard hash.utf8.count == 40,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              fileIndex >= 0, length > 0 else { return nil }
        self.infoHash = hash
        self.fileIndex = fileIndex
        self.length = length
    }

    public var candidateID: String { "torrent:\(infoHash):\(fileIndex):\(length)" }
    public var mediaIdentity: PlaybackMediaIdentity {
        PlaybackMediaIdentity(source: "torrent", account: "", item: candidateID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = MagnetFileIdentity(
            infoHash: try container.decode(String.self, forKey: .infoHash),
            fileIndex: try container.decode(Int.self, forKey: .fileIndex),
            length: try container.decode(Int64.self, forKey: .length)
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid torrent file identity"))
        }
        self = value
    }
}

public struct HostMagnetFile: Sendable {
    public let identity: MagnetFileIdentity
    public let name: String
    public let url: URL

    public init(identity: MagnetFileIdentity, name: String, url: URL) {
        self.identity = identity
        self.name = name
        self.url = url
    }
}

/// Trusted, in-process host output. Provider JSON cannot populate or persist it.
public struct HostMagnetPlayback: Sendable {
    public let leaseID: UUID
    public let files: [HostMagnetFile]
    public let resumeFile: MagnetFileIdentity?
    public var selectedFile: HostMagnetFile?

    public init(leaseID: UUID, files: [HostMagnetFile], resumeFile: MagnetFileIdentity? = nil) {
        self.leaseID = leaseID
        self.files = files
        self.resumeFile = resumeFile
    }

    public func selecting(_ candidate: PlaybackCandidate) -> HostMagnetPlayback? {
        guard let file = files.first(where: {
            $0.identity.candidateID == candidate.id && $0.url.absoluteString == candidate.url
        }) else { return nil }
        var value = self
        value.selectedFile = file
        return value
    }

    public var canResumeSelectedFile: Bool {
        guard let resumeFile, let selectedFile else { return false }
        return resumeFile == selectedFile.identity
    }
}

/// Decode BTIH only. The original magnet string is passed to the host unchanged.
public enum MagnetURI {
    public static func infoHash(in value: String) -> String? {
        guard value.utf8.count <= 64 * 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "magnet",
              components.host == nil, components.fragment == nil, components.path.isEmpty else { return nil }
        let topics = (components.queryItems ?? []).filter { $0.name.lowercased() == "xt" && $0.value?.lowercased().hasPrefix("urn:btih:") == true }
        let hashes = topics.compactMap { item -> String? in
            guard let topic = item.value?.lowercased(), topic.hasPrefix("urn:btih:") else { return nil }
            let raw = String(topic.dropFirst(9))
            if raw.utf8.count == 40,
               raw.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return raw }
            guard raw.utf8.count == 32 else { return nil }
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
            var buffer: UInt32 = 0
            var bitCount = 0
            var bytes: [UInt8] = []
            for character in raw.utf8 {
                guard let digit = alphabet.firstIndex(of: character) else { return nil }
                buffer = (buffer << 5) | UInt32(digit)
                bitCount += 5
                if bitCount >= 8 {
                    bitCount -= 8
                    bytes.append(UInt8((buffer >> bitCount) & 255))
                    buffer &= (1 << bitCount) - 1
                }
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        guard hashes.count == topics.count, let hash = hashes.first, hashes.allSatisfy({ $0 == hash }) else { return nil }
        return hash
    }
}
