import CoreGraphics
import Foundation
import Models

/// Native sRGB inspection charts. These do not exercise the mpv video pipeline
/// and contain no calibration, measured luminance, or system profile changes.
public enum DisplayInspectionPattern: String, CaseIterable, Sendable {
    case grayscale, nearBlack, highlights, colors

    public var title: String {
        switch self {
        case .grayscale: L10n.text("灰阶测试图")
        case .nearBlack: L10n.text("近黑测试图")
        case .highlights: L10n.text("高光测试图")
        case .colors: L10n.text("色块测试图")
        }
    }

    public var guidance: String {
        switch self {
        case .grayscale: L10n.text("从左到右为 0、17…255 的中性灰阶，观察层次和明显偏色。")
        case .nearBlack: L10n.text("从左到右为 0…15 的近黑灰阶。环境光会影响辨识；不要为了看清每一级而抬高黑位。")
        case .highlights: L10n.text("从左到右为 240…255 的高光灰阶，观察亮部层次；这不是 HDR 亮度测试。")
        case .colors: L10n.text("依次为白、黄、青、绿、品红、红、蓝、黑。色块用于目视检查，不用于测量色域或色差。")
        }
    }

    public func makeImage() -> CGImage? {
        let width = 512, height = 288
        let bars: [[UInt8]]
        switch self {
        case .grayscale: bars = (0..<16).map { Array(repeating: UInt8($0 * 17), count: 3) }
        case .nearBlack: bars = (0..<16).map { Array(repeating: UInt8($0), count: 3) }
        case .highlights: bars = (240...255).map { Array(repeating: UInt8($0), count: 3) }
        case .colors: bars = [[255,255,255], [255,255,0], [0,255,255], [0,255,0],
                             [255,0,255], [255,0,0], [0,0,255], [0,0,0]]
        }
        var row: [UInt8] = []
        row.reserveCapacity(width * 4)
        for x in 0..<width { row.append(contentsOf: bars[x * bars.count / width] + [255]) }
        var data = Data(capacity: width * height * 4)
        for _ in 0..<height { data.append(contentsOf: row) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)
    }
}
