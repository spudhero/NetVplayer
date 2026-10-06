// DriveEngine/DriveMediaClassifier.swift
// Shared media/subtitle file filtering for native drive share clients.

import Foundation

public enum DriveMediaClassifier {
    private static let videoExtensions: Set<String> = [
        ".mp4", ".m4v", ".mov", ".m3u8", ".mkv", ".ts", ".flv", ".webm",
        ".avi", ".wmv", ".mpg", ".mpeg", ".m2ts", ".mts", ".3gp", ".3g2",
        ".rm", ".rmvb", ".vob", ".ogv", ".mxf"
    ]

    private static let audioExtensions: Set<String> = [
        ".mp3", ".flac", ".wav", ".m4a", ".aac", ".ogg", ".oga", ".opus",
        ".wma", ".ape", ".alac", ".aiff", ".aif", ".aifc", ".amr", ".mka",
        ".ac3", ".eac3", ".dts", ".dsf", ".dff", ".caf"
    ]

    private static let subtitleExtensions: Set<String> = [
        ".srt", ".ass", ".ssa", ".vtt", ".sub", ".idx", ".sup"
    ]

    private static let nonVideoExtensions: Set<String> = Set([
        ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".avif", ".heic", ".heif",
        ".txt", ".nfo", ".json", ".xml", ".pdf", ".doc", ".docx", ".lrc", ".cue",
        ".zip", ".rar", ".7z", ".tar", ".gz", ".iso"
    ]).union(subtitleExtensions)

    private static let videoFormatTokens = [
        "video", "mpegurl", "m3u8", "mp4", "matroska", "quicktime", "webm", "x-flv", "x-msvideo"
    ]

    /// Share listings and saved-file lookups accept both video and audio files.
    public static func isPlayableMedia(name: String, formatType: String = "", isDirectory: Bool, isFile: Bool) -> Bool {
        isPlayableVideo(name: name, formatType: formatType, isDirectory: isDirectory, isFile: isFile)
            || isPlayableAudio(name: name, formatType: formatType, isDirectory: isDirectory, isFile: isFile)
    }

    public static func isPlayableAudio(name: String, formatType: String = "", isDirectory: Bool, isFile: Bool) -> Bool {
        if isDirectory || !isFile { return false }
        if isKnownNonVideoAsset(name: name) { return false }
        if audioExtensions.contains(normalizedExtension(for: name)) { return true }

        let lowerFormat = formatType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowerFormat == "audio" || lowerFormat.hasPrefix("audio/")
    }

    public static func isPlayableVideo(name: String, formatType: String = "", isDirectory: Bool, isFile: Bool) -> Bool {
        if isDirectory || !isFile { return false }
        if isKnownNonVideoAsset(name: name) { return false }
        if videoExtensions.contains(normalizedExtension(for: name)) { return true }

        let lowerFormat = formatType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerFormat.isEmpty else { return false }
        return videoFormatTokens.contains { lowerFormat.contains($0) }
    }

    public static func isKnownNonVideoAsset(name: String) -> Bool {
        nonVideoExtensions.contains(normalizedExtension(for: name))
    }

    private static func normalizedExtension(for name: String) -> String {
        let ext = (name.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "" : ".\(ext)"
    }
}
