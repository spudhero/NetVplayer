import Foundation
import MPVShim
import Testing

@Suite("Floating picture black bars")
struct PlayerBlackBarTests {
    private func frame(top: Int = 22, bottom: Int = 22, left: Int = 0, right: Int = 0,
                       dark: Bool = false) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 320 * 180 * 4)
        for y in top..<(180 - bottom) {
            for x in left..<(320 - right) {
                let value: UInt8 = dark ? 4 : (x / 12 % 2 == 0 ? 80 : 180)
                let offset = (y * 320 + x) * 4
                pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
            }
        }
        return pixels
    }

    private func detect(_ pixels: [UInt8]) -> NVMPVBlackBarSample? {
        var result = NVMPVBlackBarSample()
        let valid = pixels.withUnsafeBytes {
            nv_mpv_detect_black_bars($0.baseAddress, $0.count, 320, 180, 320 * 4, &result)
        }
        return valid == 1 ? result : nil
    }

    @Test func recognizesLetterboxAndPillarboxWithoutChangingPicture() throws {
        let letterbox = try #require(detect(frame()))
        #expect(letterbox.top == 22 && letterbox.bottom == 22)
        #expect(letterbox.left == 0 && letterbox.right == 0)
        let pillarbox = try #require(detect(frame(top: 0, bottom: 0, left: 40, right: 40)))
        #expect(pillarbox.left == 40 && pillarbox.right == 40)
        #expect(pillarbox.top == 0 && pillarbox.bottom == 0)
    }

    @Test func rejectsDarkFramesAndAsymmetricShadows() throws {
        #expect(detect(frame(dark: true)) == nil)
        let shadow = try #require(detect(frame(top: 32, bottom: 0)))
        #expect(shadow.top == 0 && shadow.bottom == 0)
        let full = try #require(detect(frame(top: 0, bottom: 0)))
        #expect(full.top == 0 && full.bottom == 0 && full.left == 0 && full.right == 0)
    }

    @Test func validatesPixelBufferBounds() {
        let pixels = frame()
        var sample = NVMPVBlackBarSample()
        pixels.withUnsafeBytes { bytes in
            #expect(nv_mpv_detect_black_bars(bytes.baseAddress, 4, 320, 180, 1280, &sample) == 0)
            #expect(nv_mpv_detect_black_bars(bytes.baseAddress, bytes.count, 320, 180, -1280, &sample) == 0)
        }
    }
}
