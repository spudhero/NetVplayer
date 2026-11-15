import Foundation
import PlayerEngine
import Testing
@testable import NetVplayerApp

@Suite("Floating video display geometry")
struct PlayerVideoGeometryTests {
    @Test func displayGeometryUsesPixelAspectAndRotation() {
        #expect(PlayerVideoGeometry.displayAspectRatio(json: #"{"w":720,"h":576,"dw":1024,"dh":576}"#) == 16.0 / 9)
        #expect(PlayerVideoGeometry.displayAspectRatio(json: #"{"w":720,"h":576,"par":1.4222222222222223}"#) == 16.0 / 9)
        #expect(PlayerVideoGeometry.displayAspectRatio(json: #"{"aspect":1.7777777777777777,"rotate":90}"#) == 9.0 / 16)
        #expect(PlayerVideoGeometry.displayAspectRatio(json: #"{"w":3840,"h":1608}"#) == 3840.0 / 1608)
        #expect(PlayerVideoGeometry.displayAspectRatio(json: #"{"w":1920,"h":0}"#) == nil)
        #expect(PlayerVideoGeometry.displayAspectRatio(json: "null") == nil)
    }

    @Test func smallWindowFitsPictureAndAvailableDisplay() {
        let screen = CGSize(width: 1440, height: 900)
        let fallback = CompactPlayerLayoutPolicy.floatingContentSize(aspectRatio: nil, availableSize: screen)
        #expect(fallback == CGSize(width: 480, height: 270))
        for ratio in [2.39, 4.0 / 3, 9.0 / 16, 16.0 / 9] {
            let size = CompactPlayerLayoutPolicy.floatingContentSize(aspectRatio: ratio, availableSize: screen)
            #expect(abs(size.width / size.height - ratio) < 0.0001)
            #expect(size.width <= 480 && size.height <= screen.height)
        }
        let smallScreen = CGSize(width: 360, height: 300)
        let portrait = CompactPlayerLayoutPolicy.floatingContentSize(aspectRatio: 9.0 / 16, availableSize: smallScreen)
        #expect(portrait.width <= smallScreen.width && portrait.height <= smallScreen.height)
        #expect(abs(portrait.width / portrait.height - 9.0 / 16) < 0.0001)
    }
}
