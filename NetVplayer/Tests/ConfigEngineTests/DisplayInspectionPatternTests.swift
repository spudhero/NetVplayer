import CoreGraphics
import Foundation
import Testing
@testable import PlayerEngine

@Suite struct DisplayInspectionPatternTests {
    @Test func nearBlackAndHighlightSignalsRetainEveryCodeValue() throws {
        for (pattern, range) in [(DisplayInspectionPattern.nearBlack, 0...15), (.highlights, 240...255)] {
            let image = try #require(pattern.makeImage())
            let data = try #require(image.dataProvider?.data) as Data
            let values = stride(from: 0, to: data.count, by: 4).map { Int(data[$0]) }
            #expect(Set(values) == Set(range))
            #expect(values.prefix(image.width).elementsEqual(values.suffix(image.width)))
            let neutralAndOpaque = stride(from: 0, to: data.count, by: 4).allSatisfy { index in
                let neutral = data[index] == data[index + 1] && data[index + 1] == data[index + 2]
                return neutral && data[index + 3] == 255
            }
            #expect(neutralAndOpaque)
        }
    }

    @Test func chartsAreTaggedSDRBoundedAndOpaque() throws {
        for pattern in DisplayInspectionPattern.allCases {
            let image = try #require(pattern.makeImage())
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            #expect(image.bitsPerComponent == 8)
            #expect(image.width == 512 && image.height == 288)
            #expect(image.shouldInterpolate == false)
            let data = try #require(image.dataProvider?.data) as Data
            #expect(data.count == 589_824)
            #expect(stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] == 255 })
        }
    }

    @Test func colorPatchesCoverAdditivePrimariesAndComplements() throws {
        let image = try #require(DisplayInspectionPattern.colors.makeImage())
        let data = try #require(image.dataProvider?.data) as Data
        let packed: [Int] = stride(from: 0, to: image.bytesPerRow, by: 4).map { index in
            let red = Int(data[index]) << 16
            let green = Int(data[index + 1]) << 8
            return red | green | Int(data[index + 2])
        }
        let colors = Set(packed)
        #expect(colors == Set([0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x000000]))
    }
}
