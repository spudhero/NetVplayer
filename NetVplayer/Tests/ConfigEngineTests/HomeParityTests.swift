import Foundation
import Models
import Testing
@testable import NetVplayerApp
@testable import SpiderEngine

@Test func posterFallbackUsesAndroidTitleInitialAndMaterialPalette() {
    let chineseTitle = PosterFallbackStyle(title: " 從後面來的神威先生 ")
    #expect(chineseTitle.initial == "從")
    #expect(chineseTitle.rgb == 0x29B6F6)

    let latinTitle = PosterFallbackStyle(title: "Anime")
    #expect(latinTitle.initial == "A")
    #expect(latinTitle.rgb == 0x26A69A)

    let emptyTitle = PosterFallbackStyle(title: "   ")
    #expect(emptyTitle.initial == "！")
    #expect(emptyTitle.rgb == 0x8D6E63)
}

@Test func embeddedImageSourceExtractsAndroidStyleHeaders() throws {
    let rawURL = "https://img.example.test/poster.jpg"
        + "@Headers=%7B%22ua%22%3A%22InlineAgent%22%2C%22X-Poster%22%3A%22yes%22%7D"
        + "@Referer=https%3A%2F%2Fsource.example.test%2F"
    let source = try #require(EmbeddedImageSource.parse(rawURL))

    #expect(source.url.absoluteString == "https://img.example.test/poster.jpg")
    #expect(source.headers["User-Agent"] == "InlineAgent")
    #expect(source.headers["X-Poster"] == "yes")
    #expect(source.headers["Referer"] == "https://source.example.test/")
}

@MainActor
@Test func embeddedImageHeadersOverrideSiteAndInferredHeaders() throws {
    let url = try #require(URL(string: "https://img1.doubanio.com/view/photo/poster.jpg"))
    let request = ImageLoader.makeRequest(
        url: url,
        headers: ["Referer": "https://site.example.test/"],
        embeddedHeaders: ["Referer": "https://inline.example.test/"],
        timeout: 15
    )

    #expect(request.value(forHTTPHeaderField: "Referer") == "https://inline.example.test/")
}

@Test func homeVideoContentOnlyReplacesNonEmptyRecommendationLists() {
    var base = Models.Result(
        types: [VodClass(typeId: "anime", typeName: "动漫")],
        list: [Vod(vodId: "catalog", vodName: "分类首项")],
        total: 12
    )
    let recommendation = Models.Result(
        list: [Vod(vodId: "featured", vodName: "推荐首项")]
    )

    SiteApi.applyHomeVideoContent(recommendation, to: &base)
    #expect(base.types.map(\.typeId) == ["anime"])
    #expect(base.list.map(\.vodId) == ["featured"])
    #expect(base.total == 12)

    SiteApi.applyHomeVideoContent(Models.Result.empty, to: &base)
    #expect(base.list.map(\.vodId) == ["featured"])
}
