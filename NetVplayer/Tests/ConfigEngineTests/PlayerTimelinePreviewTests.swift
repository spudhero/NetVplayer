import Foundation
import Testing
@testable import NetVplayerApp

struct PlayerTimelinePreviewTests {
    @Test(arguments: [CGFloat(0), CGFloat(19)])
    func previewAndSeekUseSameTrackEndpoints(thumbWidth: CGFloat) {
        #expect(PlayerTimelineCoordinatePolicy.time(at: -20, width: 320, duration: 120, thumbWidth: thumbWidth) == 0)
        #expect(PlayerTimelineCoordinatePolicy.time(at: 160, width: 320, duration: 120, thumbWidth: thumbWidth) == 60)
        #expect(PlayerTimelineCoordinatePolicy.time(at: 400, width: 320, duration: 120, thumbWidth: thumbWidth) == 120)
        // The track's leading inset and final inset represent precisely 0 and duration.
        #expect(PlayerTimelineCoordinatePolicy.time(at: thumbWidth / 2, width: 320, duration: 120, thumbWidth: thumbWidth) == 0)
        #expect(PlayerTimelineCoordinatePolicy.time(at: 320 - thumbWidth / 2, width: 320, duration: 120, thumbWidth: thumbWidth) == 120)
    }

    @Test func previewRejectsInvalidDurationsAndKeepsLabelsInsideTrack() {
        for duration in [Double.nan, .infinity, -1, 0, .greatestFiniteMagnitude] {
            #expect(PlayerTimelineCoordinatePolicy.time(at: 50, width: 100, duration: duration) == nil)
        }
        #expect(PlayerTimelineCoordinatePolicy.time(at: .nan, width: 100, duration: 120) == nil)
        #expect(PlayerTimelineCoordinatePolicy.time(at: 5, width: 10, duration: 120, thumbWidth: 19) == nil)
        #expect(PlayerTimelineCoordinatePolicy.previewCenter(x: -10, width: 320, bubbleWidth: 84) == 42)
        #expect(PlayerTimelineCoordinatePolicy.previewCenter(x: 340, width: 320, bubbleWidth: 84) == 278)
        #expect(PlayerTimelineCoordinatePolicy.previewCenter(x: 340, width: 40, bubbleWidth: 84) == 20)
        #expect(PlayerTimelineCoordinatePolicy.label(seconds: 65.9) == "01:05")
        #expect(PlayerTimelineCoordinatePolicy.label(seconds: 3_665) == "1:01:05")
        #expect(PlayerTimelineCoordinatePolicy.label(seconds: .infinity) == "--:--")
    }
}
