import Testing
import LiveEngine

@Test func liveParserMergesRepeatedM3UChannelsIntoOrderedUniqueLines() throws {
    let source = """
    #EXTM3U
    #EXTINF:-1 tvg-id="cctv1" group-title="央视频道",CCTV 1
    https://line-a.example.test/cctv1.m3u8
    #EXTINF:-1 tvg-id="cctv1" group-title="央视频道",CCTV 1
    https://line-b.example.test/cctv1.m3u8
    #EXTINF:-1 tvg-id="cctv1" group-title="央视频道",CCTV 1
    https://line-a.example.test/cctv1.m3u8
    #EXTINF:-1 tvg-id="cctv1" group-title="备用频道",CCTV 1
    https://backup.example.test/cctv1.m3u8
    """

    let groups = LiveParser.parse(text: source)
    let primary = try #require(groups.first)
    let channel = try #require(primary.channels.first)

    #expect(groups.count == 2)
    #expect(primary.channels.count == 1)
    #expect(channel.name == "CCTV 1")
    #expect(channel.urls == [
        "https://line-a.example.test/cctv1.m3u8",
        "https://line-b.example.test/cctv1.m3u8"
    ])
    #expect(groups[1].channels.count == 1)
}

@Test func liveParserKeepsDistinctDisplayNamesThatShareAnEPGName() throws {
    let source = """
    #EXTM3U
    #EXTINF:-1 tvg-name="春晚" group-title="历年春晚",春晚1983
    https://archive.example.test/spring-1983.mp4
    #EXTINF:-1 tvg-name="春晚" group-title="历年春晚",春晚2025
    https://archive.example.test/spring-2025.m3u8
    #EXTINF:-1 tvg-name="春晚" group-title="历年春晚",春晚2026
    https://archive.example.test/spring-2026.m3u8
    """

    let group = try #require(LiveParser.parse(text: source).first)

    #expect(group.name == "历年春晚")
    #expect(group.channels.map(\.name) == ["春晚1983", "春晚2025", "春晚2026"])
    #expect(group.channels.allSatisfy { $0.tvgName == "春晚" && $0.epgName == "春晚" })
    #expect(group.channels.allSatisfy { $0.urls.count == 1 })
}

@Test func liveParserMergesNormalizedTXTAndJSONChannelNames() throws {
    let txt = """
    央视频道,#genre#
    CCTV 1,https://line-a.example.test/cctv1.m3u8
      cctv   1  ,https://line-b.example.test/cctv1.m3u8
    """
    let txtChannel = try #require(LiveParser.parse(text: txt).first?.channels.first)

    #expect(txtChannel.name == "CCTV 1")
    #expect(txtChannel.urls == [
        "https://line-a.example.test/cctv1.m3u8",
        "https://line-b.example.test/cctv1.m3u8"
    ])

    let json = """
    {
      "groups": [{
        "name": "央视频道",
        "channels": [
          { "name": "CCTV 1", "urls": ["https://json-a.example.test/cctv1.m3u8"] },
          { "name": "ＣＣＴＶ １", "urls": ["https://json-b.example.test/cctv1.m3u8"] }
        ]
      }]
    }
    """
    let jsonChannel = try #require(LiveParser.parse(text: json).first?.channels.first)

    #expect(jsonChannel.urls == [
        "https://json-a.example.test/cctv1.m3u8",
        "https://json-b.example.test/cctv1.m3u8"
    ])
}

@Test func liveParserKeepsSameNameChannelsSeparateWhenPlaybackHeadersDiffer() {
    let source = """
    #EXTM3U
    #EXTVLCOPT:http-user-agent=LineA
    #EXTINF:-1 group-title="央视频道",CCTV 1
    https://line-a.example.test/cctv1.m3u8
    #EXTVLCOPT:http-user-agent=LineB
    #EXTINF:-1 group-title="央视频道",CCTV 1
    https://line-b.example.test/cctv1.m3u8
    """

    let channels = LiveParser.parse(text: source).first?.channels ?? []

    #expect(channels.count == 2)
    #expect(channels.map { $0.header["User-Agent"] } == ["LineA", "LineB"])
}
