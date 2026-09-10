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
