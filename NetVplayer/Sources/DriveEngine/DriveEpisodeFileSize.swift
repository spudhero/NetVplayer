import Foundation
import Models

/// Uses supplied directory metadata, without resolving URLs or contacting a drive.
public enum DriveEpisodeFileSize {
    public static func bytes(for episode: Episode) -> Int64? {
        if let reference = DriveFileReference.parse(episode.url), reference.size > 0 {
            return reference.size
        }
        return OriginalAndroidPlaybackIdentity.fileSizeBytes(for: episode.url)
    }

    public static func label(for episode: Episode) -> String? {
        guard let bytes = bytes(for: episode) else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
