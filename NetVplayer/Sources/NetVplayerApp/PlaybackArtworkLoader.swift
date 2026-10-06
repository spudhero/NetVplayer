import AppKit
import Models

/// Decode with the same image request policy as posters, then give mpv a local PNG.
/// Media headers never enter the image request and artwork never delays audio startup.
@MainActor
enum PlaybackArtworkLoader {
    nonisolated static let placeholderSource = "netvplayer-artwork://audio"

    static func load(_ spec: PlaySpec, pipeline: PosterImagePipeline = .shared) async throws -> Data {
        let rawSource = spec.artwork.isEmpty ? spec.audioFallbackArtwork : spec.artwork
        if rawSource != placeholderSource, let source = EmbeddedImageSource.parse(rawSource) {
            do {
                let headers = ImageLoader.mergedHeaders(siteHeaders: spec.artworkHeaders, embeddedHeaders: source.headers)
                let request = ImageLoader.makeRequest(url: source.url, headers: spec.artworkHeaders,
                                                      embeddedHeaders: source.headers, timeout: 12)
                let image = try await pipeline.image(request: request,
                    key: ImageLoader.cacheKey(url: source.url, headers: headers), maxPixelSize: 1_920)
                try Task.checkCancellation()
                if let data = NSBitmapImageRep(cgImage: image.cgImage).representation(using: .png, properties: [:]) {
                    return data
                }
            } catch {
                try Task.checkCancellation()
                // Never print the image URL, embedded headers, or server error body.
                DiagnosticLog.write("[PLAYBACK_ARTWORK_FALLBACK] remote image unavailable; using music backdrop")
            }
        }
        try Task.checkCancellation()
        return try placeholder(title: spec.metadata["vod.name"] ?? spec.title)
    }

    static func placeholder(title: String) throws -> Data {
        let size = NSSize(width: 1_280, height: 720)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.06, green: 0.09, blue: 0.18, alpha: 1),
                                NSColor(red: 0.18, green: 0.14, blue: 0.28, alpha: 1)])?.draw(in: rect, angle: 30)
            let center = NSPoint(x: 640, y: 425)
            for radius in stride(from: CGFloat(130), through: 40, by: -10) {
                NSColor(calibratedWhite: 1, alpha: radius == 130 ? 0.16 : 0.045).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                      width: radius * 2, height: radius * 2))
                ring.lineWidth = 2
                ring.stroke()
            }
            NSColor(red: 0.33, green: 0.85, blue: 0.95, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 630, y: 415, width: 20, height: 20)).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
            ((text.isEmpty ? L10n.text("正在播放音乐") : text) as NSString).draw(
                in: NSRect(x: 120, y: 230, width: 1_040, height: 52),
                withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .medium),
                                 .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1), .paragraphStyle: paragraph]
            )
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
