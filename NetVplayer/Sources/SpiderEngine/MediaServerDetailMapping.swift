import Foundation
import MediaServerEngine
import Models

enum MediaServerDetailMapping {
  static func detail(_ item: ServerItem, reference: MediaServerReference) -> MediaServerDetail {
    let people = Array((item.People ?? []).prefix(256))
    let cast = people.filter { $0.Type == "Actor" || $0.Type == "GuestStar" }.compactMap {
      person -> MediaCastMember? in
      guard let name = text(person.Name) else { return nil }
      let portrait = person.Id.flatMap {
        try? MediaServerReference(accountID: reference.accountID, itemID: $0)
      }
      .flatMap { image($0, tag: person.PrimaryImageTag) }
      return .init(name: name, role: text(person.Role), portrait: portrait)
    }
    let streams = (item.MediaSources ?? []).flatMap { $0.MediaStreams ?? [] }
    let languages = Array(
      Set(streams.filter { $0.Type == "Audio" }.compactMap { text($0.Language) })
    ).sorted()
    let minutes = item.RunTimeTicks.flatMap { $0 > 0 ? Int($0 / 600_000_000) : nil }
    let metadata = MediaMetadata(
      title: text(item.Name), originalTitle: text(item.OriginalTitle), year: item.ProductionYear,
      kind: ["Series", "Season", "Episode"].contains(item.Type ?? "") ? .television : .movies,
      season: item.ParentIndexNumber, episode: item.IndexNumber,
      plot: text(item.Overview), poster: image(reference, tag: item.ImageTags?["Primary"]),
      fanart: image(reference, tag: item.BackdropImageTags?.first, kind: .backdrop),
      tmdbID: text(item.ProviderIds?["Tmdb"]), genres: item.Genres?.compactMap(text),
      runtimeMinutes: minutes,
      releaseDate: text(item.PremiereDate).map { String($0.prefix(10)) },
      countries: item.ProductionLocations?.compactMap(text), languages: languages,
      studios: item.Studios?.compactMap { text($0.Name) },
      tagline: item.Taglines?.compactMap(text).first,
      directors: people.filter { $0.Type == "Director" }.compactMap { text($0.Name) },
      writers: people.filter { $0.Type == "Writer" }.compactMap { text($0.Name) }, cast: cast)
    let files = (item.MediaSources ?? []).prefix(32).enumerated().map { index, source in
      let video = source.MediaStreams?.first { $0.Type == "Video" }
      return MediaServerFileDetail(
        id: reference.locator + ":" + (source.Id ?? String(index)), episodeURL: reference.locator,
        name: text(source.Name) ?? text(item.Name) ?? L10n.text("原始文件"),
        container: text(source.Container), size: source.Size.flatMap { $0 > 0 ? $0 : nil },
        width: video?.Width.flatMap { $0 > 0 ? $0 : nil },
        height: video?.Height.flatMap { $0 > 0 ? $0 : nil },
        videoCodec: text(video?.Codec),
        videoRange: text(video?.VideoRangeType) ?? text(video?.VideoRange),
        audio: tracks(source, type: "Audio"), subtitles: tracks(source, type: "Subtitle"),
        sourceID: source.Id.flatMap { MediaServerReference.validID($0) ? $0 : nil },
        supportsOriginalPlayback: source.SupportsDirectPlay != false && source.IsInfiniteStream != true
          && source.RequiresOpening != true && (source.VideoType == nil || source.VideoType == "VideoFile")
          && source.Container?.lowercased() != "iso")
    }
    let rating = item.CommunityRating.flatMap { $0.isFinite && (0...10).contains($0) ? $0 : nil }
    return .init(
      metadata: metadata, rating: rating, officialRating: text(item.OfficialRating), files: files)
  }

  static func episode(_ item: ServerItem, reference: MediaServerReference, name: String) -> Episode
  {
    .init(
      name: name, url: reference.locator,
      artwork: image(reference, tag: item.ImageTags?["Primary"]),
      overview: text(item.Overview),
      released: text(item.PremiereDate).map { String($0.prefix(10)) },
      season: item.ParentIndexNumber, number: item.IndexNumber)
  }

  private static func tracks(_ source: ServerMediaSource, type: String) -> [String] {
    (source.MediaStreams ?? []).filter { $0.Type == type }.prefix(64).compactMap { stream in
      if let title = text(stream.DisplayTitle) { return title }
      let parts = [
        text(stream.Codec)?.uppercased(), text(stream.Language),
        stream.Channels.flatMap { $0 > 0 ? L10n.text("{0} 声道", [String($0)]) : nil },
      ].compactMap { $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
  }
  private static func image(
    _ reference: MediaServerReference, tag: String?,
    kind: MediaServerArtworkReference.Kind = .primary
  ) -> String? {
    tag.flatMap { try? MediaServerArtworkReference(item: reference, tag: $0, kind: kind).locator }
  }
  private static func text(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return String(trimmed.prefix(32_768))
  }
}
