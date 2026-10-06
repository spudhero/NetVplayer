import CoreGraphics

struct VodDetailLayout: Equatable, Sendable {
    let containerSize: CGSize
    let scaleProgress: CGFloat
    let contentInset: CGFloat
    let columnSpacing: CGFloat
    let informationPaneWidth: CGFloat
    let posterWidth: CGFloat
    let titleFontSize: CGFloat
    let sectionSpacing: CGFloat
    let overviewLineLimit: Int?
    let episodeColumnCount: Int
    let closeButtonInset: CGFloat

    var posterHeight: CGFloat {
        posterWidth / (2.0 / 3.0)
    }

    var playbackTopInset: CGFloat {
        closeButtonInset + VodDetailLayoutPolicy.closeButtonSize + 4
    }
}

enum VodDetailLayoutPolicy {
    static let minimumSize = CGSize(width: 960, height: 540)
    static let maximumSize = CGSize(width: 1_600, height: 900)
    static let viewportScale: CGFloat = 0.90
    static let aspectRatio: CGFloat = 16.0 / 9.0
    static let episodeGridSpacing: CGFloat = 10
    static let episodeItemMinimumWidth: CGFloat = 128
    static let episodeItemMaximumWidth: CGFloat = 220
    static let closeButtonSize: CGFloat = 32

    static func layout(in viewportSize: CGSize) -> VodDetailLayout {
        let width: CGFloat
        if viewportSize.width.isFinite,
           viewportSize.height.isFinite,
           viewportSize.width > 0,
           viewportSize.height > 0 {
            let widthBound = viewportSize.width * viewportScale
            let heightBound = viewportSize.height * viewportScale * aspectRatio
            width = min(max(min(widthBound, heightBound), minimumSize.width), maximumSize.width)
        } else {
            width = minimumSize.width
        }

        let progress = min(
            1,
            max(0, (width - minimumSize.width) / (maximumSize.width - minimumSize.width))
        )
        let contentInset = interpolate(from: 16, to: 28, progress: progress)
        let columnSpacing = interpolate(from: 16, to: 24, progress: progress)
        let informationPaneWidth = interpolate(from: 340, to: 440, progress: progress)
        let posterWidth = interpolate(from: 190, to: 260, progress: progress)
        let titleFontSize = interpolate(from: 28, to: 32, progress: progress)
        let sectionSpacing = interpolate(from: 16, to: 20, progress: progress)
        let closeButtonInset = interpolate(from: 16, to: 22, progress: progress)
        let playbackWidth = max(0, width - informationPaneWidth - columnSpacing - 1)
        let episodeAvailableWidth = max(
            0,
            playbackWidth - (contentInset * 2) - AppScrollbarMetrics.gutterWidth
        )

        return VodDetailLayout(
            containerSize: CGSize(width: width, height: width / aspectRatio),
            scaleProgress: progress,
            contentInset: contentInset,
            columnSpacing: columnSpacing,
            informationPaneWidth: informationPaneWidth,
            posterWidth: posterWidth,
            titleFontSize: titleFontSize,
            sectionSpacing: sectionSpacing,
            overviewLineLimit: overviewLineLimit(for: progress),
            episodeColumnCount: episodeColumnCount(availableWidth: episodeAvailableWidth),
            closeButtonInset: closeButtonInset
        )
    }

    static func episodeColumnCount(availableWidth: CGFloat) -> Int {
        guard availableWidth.isFinite, availableWidth > 0 else { return 3 }
        let targetWidth: CGFloat = 154
        let fitted = Int(
            floor((availableWidth + episodeGridSpacing) / (targetWidth + episodeGridSpacing))
        )
        return min(6, max(3, fitted))
    }

    private static func overviewLineLimit(for progress: CGFloat) -> Int? {
        if progress >= 0.75 { return nil }
        if progress >= 0.35 { return 14 }
        return 10
    }

    private static func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * progress)
    }
}
