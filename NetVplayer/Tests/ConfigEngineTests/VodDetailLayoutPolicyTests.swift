import CoreGraphics
import Testing
@testable import NetVplayerApp

@Suite("VOD detail layout policy")
struct VodDetailLayoutPolicyTests {
    @Test
    func standardViewportsProduceTheResponsiveContract() {
        let minimum = VodDetailLayoutPolicy.layout(in: CGSize(width: 960, height: 640))
        let regular = VodDetailLayoutPolicy.layout(in: CGSize(width: 1_200, height: 800))
        let large = VodDetailLayoutPolicy.layout(in: CGSize(width: 1_440, height: 900))
        let maximum = VodDetailLayoutPolicy.layout(in: CGSize(width: 1_920, height: 1_080))

        expectSize(minimum.containerSize, width: 960, height: 540)
        expectSize(regular.containerSize, width: 1_080, height: 607.5)
        expectSize(large.containerSize, width: 1_296, height: 729)
        expectSize(maximum.containerSize, width: 1_600, height: 900)

        #expect(minimum.episodeColumnCount == 3)
        #expect(regular.episodeColumnCount == 4)
        #expect(large.episodeColumnCount == 5)
        #expect(maximum.episodeColumnCount == 6)
    }

    @Test
    func layoutTokensInterpolateAndClampAtTheirBounds() {
        let minimum = VodDetailLayoutPolicy.layout(in: CGSize(width: 960, height: 640))
        let maximum = VodDetailLayoutPolicy.layout(in: CGSize(width: 3_840, height: 2_160))

        #expect(minimum.scaleProgress == 0)
        #expect(minimum.contentInset == 16)
        #expect(minimum.columnSpacing == 16)
        #expect(minimum.informationPaneWidth == 340)
        #expect(minimum.posterWidth == 190)
        #expect(minimum.posterHeight == 285)
        #expect(minimum.titleFontSize == 28)
        #expect(minimum.overviewLineLimit == 10)

        #expect(maximum.scaleProgress == 1)
        #expect(maximum.contentInset == 28)
        #expect(maximum.columnSpacing == 24)
        #expect(maximum.informationPaneWidth == 440)
        #expect(maximum.posterWidth == 260)
        #expect(maximum.posterHeight == 390)
        #expect(maximum.titleFontSize == 32)
        #expect(maximum.overviewLineLimit == nil)
    }

    @Test
    func invalidViewportsAndGridWidthsFallBackSafely() {
        let invalid = VodDetailLayoutPolicy.layout(
            in: CGSize(width: CGFloat.infinity, height: CGFloat.nan)
        )

        #expect(invalid.containerSize == VodDetailLayoutPolicy.minimumSize)
        #expect(invalid.episodeColumnCount == 3)
        #expect(VodDetailLayoutPolicy.episodeColumnCount(availableWidth: -CGFloat.infinity) == 3)
        #expect(VodDetailLayoutPolicy.episodeColumnCount(availableWidth: 10_000) == 6)
    }

    private func expectSize(
        _ actual: CGSize,
        width: CGFloat,
        height: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual.width - width) < 0.01, sourceLocation: sourceLocation)
        #expect(abs(actual.height - height) < 0.01, sourceLocation: sourceLocation)
    }
}
