import AppKit
import SwiftUI

struct AppThemeRootBackground: View {
    let palette: AppThemePalette
    let forceOpaque: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = palette.effectiveBackgroundMode(
            reduceTransparency: reduceTransparency,
            forceOpaque: forceOpaque
        )

        ZStack {
            if mode != .opaque {
                AppBehindWindowMaterialView(tone: palette.tone)
            }

            AppThemeBackdropLayer(palette: palette)
                .opacity(mode == .opaque ? 1 : palette.baseOpacity)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: palette.id
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AppThemeBackdropLayer: View {
    let palette: AppThemePalette

    var body: some View {
        ZStack {
            LinearGradient(
                stops: palette.backgroundStops.map {
                    Gradient.Stop(
                        color: Color(appHex: $0.hex),
                        location: $0.location
                    )
                },
                startPoint: palette.gradientVector.startPoint,
                endPoint: palette.gradientVector.endPoint
            )

            if let backdropAsset = palette.backdropAsset {
                AppThemeBackdropAssetLayer(asset: backdropAsset)
            } else if !palette.fields.isEmpty {
                AppDiffuseLightField(
                    fields: palette.fields,
                    tone: palette.tone
                )
            }
        }
    }
}

enum AppThemeResourceBundle {
    static let name = "NetVplayer_NetVplayerApp.bundle"

    static let bundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resourceURL.appendingPathComponent(name, isDirectory: true)
           ) {
            return packagedBundle
        }
        return .module
    }()

    static func url(for asset: AppThemeBackdropAsset) -> URL? {
        bundle.url(
            forResource: asset.rawValue,
            withExtension: asset.fileExtension,
            subdirectory: asset.subdirectory
        )
    }
}

private struct AppThemeBackdropAssetLayer: View {
    let asset: AppThemeBackdropAsset

    var body: some View {
        Color.black
            .overlay {
                if let resourceURL = AppThemeResourceBundle.url(for: asset),
                   let image = NSImage(contentsOf: resourceURL) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                }
            }
    }
}

private struct AppDiffuseLightField: View {
    let fields: [AppThemeField]
    let tone: AppThemeTone

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ZStack {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        if !usesNormalBlend(field) {
                            AppThemeFieldLayer(field: field, containerSize: geometry.size)
                        }
                    }
                }
                .blendMode(tone == .light ? .softLight : .screen)

                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    if usesNormalBlend(field) {
                        AppThemeFieldLayer(field: field, containerSize: geometry.size)
                    }
                }
            }
            .compositingGroup()
        }
    }

    private func usesNormalBlend(_ field: AppThemeField) -> Bool {
        switch field.kind {
        case .inkBloom, .splatter:
            return true
        default:
            return false
        }
    }
}

private struct AppThemeFieldLayer: View {
    let field: AppThemeField
    let containerSize: CGSize

    private var fieldWidth: CGFloat {
        containerSize.width * CGFloat(field.widthScale)
    }

    private var fieldHeight: CGFloat {
        containerSize.height * CGFloat(field.heightScale)
    }

    private var blurRadius: CGFloat {
        max(containerSize.width, containerSize.height) * CGFloat(field.blurScale)
    }

    var body: some View {
        fieldShape
            .frame(width: fieldWidth, height: fieldHeight)
            .rotationEffect(.degrees(field.rotationDegrees))
            .position(
                x: containerSize.width * CGFloat(field.centerX),
                y: containerSize.height * CGFloat(field.centerY)
            )
            .blur(radius: blurRadius)
    }

    @ViewBuilder
    private var fieldShape: some View {
        switch field.kind {
        case .radial:
            Circle()
                .fill(ellipticalGradient)
        case .ellipse:
            Ellipse()
                .fill(ellipticalGradient)
        case .band:
            RoundedRectangle(cornerRadius: min(fieldWidth, fieldHeight) / 2)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(
                                color: Color(appHex: field.startHex)
                                    .opacity(field.opacity * 0.32),
                                location: 0.12
                            ),
                            .init(
                                color: Color(appHex: field.startHex)
                                    .opacity(field.opacity),
                                location: 0.34
                            ),
                            .init(
                                color: Color(appHex: field.endHex)
                                    .opacity(field.opacity),
                                location: 0.68
                            ),
                            .init(
                                color: Color(appHex: field.endHex)
                                    .opacity(field.opacity * 0.28),
                                location: 0.88
                            ),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        case .inkBloom:
            AppThemeInkBloomLayer(field: field)
        case .splatter:
            AppThemeSplatterShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(appHex: field.startHex).opacity(field.opacity),
                            Color(appHex: field.endHex).opacity(field.opacity * 0.82),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }

    private var ellipticalGradient: RadialGradient {
        RadialGradient(
            stops: [
                .init(
                    color: Color(appHex: field.startHex).opacity(field.opacity),
                    location: 0
                ),
                .init(
                    color: Color(appHex: field.endHex).opacity(field.opacity * 0.42),
                    location: 0.46
                ),
                .init(color: .clear, location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: max(fieldWidth, fieldHeight) * 0.56
        )
    }
}

private struct AppThemeInkBloomLayer: View {
    let field: AppThemeField

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(Array(AppThemeInkBloomComposition.flowers.enumerated()), id: \.offset) { _, flower in
                    let flowerSize = max(7, scale * flower.scale)
                    AppThemeInkFlowerCluster(
                        field: field,
                        flower: flower
                    )
                    .frame(
                        width: flowerSize,
                        height: flowerSize * flower.aspectRatio
                    )
                    .rotationEffect(.degrees(flower.rotationDegrees))
                    .position(
                        x: geometry.size.width * flower.centerX,
                        y: geometry.size.height * flower.centerY
                    )
                }
            }
        }
    }
}

enum AppThemeInkTone: Equatable, Sendable {
    case crimson
    case black
}

struct AppThemeInkFlowerPlacement: Equatable, Sendable {
    let centerX: CGFloat
    let centerY: CGFloat
    let scale: CGFloat
    let aspectRatio: CGFloat
    let rotationDegrees: Double
    let tone: AppThemeInkTone
    let opacity: Double
    let variant: Int
}

enum AppThemeInkBloomComposition {
    static let flowers: [AppThemeInkFlowerPlacement] = [
        .init(centerX: 0.05, centerY: 0.18, scale: 0.10, aspectRatio: 0.92, rotationDegrees: -18, tone: .crimson, opacity: 0.82, variant: 0),
        .init(centerX: 0.18, centerY: 0.42, scale: 0.13, aspectRatio: 1.08, rotationDegrees: 14, tone: .black, opacity: 0.92, variant: 1),
        .init(centerX: 0.13, centerY: 0.79, scale: 0.09, aspectRatio: 0.88, rotationDegrees: 31, tone: .crimson, opacity: 0.74, variant: 2),
        .init(centerX: 0.31, centerY: 0.20, scale: 0.12, aspectRatio: 1.03, rotationDegrees: -32, tone: .black, opacity: 0.86, variant: 3),
        .init(centerX: 0.39, centerY: 0.62, scale: 0.14, aspectRatio: 0.94, rotationDegrees: 8, tone: .crimson, opacity: 0.94, variant: 1),
        .init(centerX: 0.50, centerY: 0.10, scale: 0.08, aspectRatio: 1.12, rotationDegrees: 22, tone: .crimson, opacity: 0.76, variant: 2),
        .init(centerX: 0.56, centerY: 0.40, scale: 0.13, aspectRatio: 0.90, rotationDegrees: -11, tone: .black, opacity: 0.90, variant: 0),
        .init(centerX: 0.65, centerY: 0.74, scale: 0.13, aspectRatio: 1.06, rotationDegrees: 27, tone: .crimson, opacity: 0.88, variant: 3),
        .init(centerX: 0.75, centerY: 0.21, scale: 0.11, aspectRatio: 0.86, rotationDegrees: 12, tone: .crimson, opacity: 0.80, variant: 0),
        .init(centerX: 0.85, centerY: 0.49, scale: 0.14, aspectRatio: 1.02, rotationDegrees: -24, tone: .black, opacity: 0.94, variant: 2),
        .init(centerX: 0.91, centerY: 0.81, scale: 0.09, aspectRatio: 0.91, rotationDegrees: 19, tone: .crimson, opacity: 0.76, variant: 1),
        .init(centerX: 0.47, centerY: 0.89, scale: 0.10, aspectRatio: 1.10, rotationDegrees: -38, tone: .black, opacity: 0.84, variant: 3),
        .init(centerX: 0.95, centerY: 0.11, scale: 0.07, aspectRatio: 0.96, rotationDegrees: 35, tone: .black, opacity: 0.82, variant: 1),
        .init(centerX: 0.01, centerY: 0.55, scale: 0.08, aspectRatio: 1.05, rotationDegrees: -7, tone: .crimson, opacity: 0.78, variant: 3),
        .init(centerX: 0.72, centerY: 0.96, scale: 0.07, aspectRatio: 0.90, rotationDegrees: -29, tone: .black, opacity: 0.80, variant: 0),
    ]
}

private struct AppThemeInkFlowerCluster: View {
    let field: AppThemeField
    let flower: AppThemeInkFlowerPlacement

    private var inkColor: Color {
        switch flower.tone {
        case .crimson:
            return Color(appHex: field.endHex)
        case .black:
            return Color(appHex: 0x010101)
        }
    }

    private var washColor: Color {
        switch flower.tone {
        case .crimson:
            return Color(appHex: field.startHex)
        case .black:
            return Color(appHex: 0x2A0308)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height)
            let edgeWidth = max(0.35, scale * 0.012)
            let filamentWidth = max(0.3, scale * 0.009)

            ZStack {
                AppThemeInkSplashShape(variant: flower.variant)
                    .fill(inkColor.opacity(field.opacity * flower.opacity * 0.88))

                AppThemeInkSplashFilamentShape(variant: flower.variant)
                    .stroke(
                        inkColor.opacity(field.opacity * flower.opacity * 0.74),
                        style: StrokeStyle(
                            lineWidth: filamentWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                AppThemeInkFlowerShape(variant: flower.variant)
                    .fill(
                        RadialGradient(
                            colors: [
                                washColor.opacity(field.opacity * flower.opacity),
                                inkColor.opacity(field.opacity * flower.opacity * 0.96),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: scale * 0.47
                        )
                    )

                AppThemeInkFlowerShape(variant: flower.variant)
                    .stroke(
                        inkColor.opacity(field.opacity * flower.opacity),
                        style: StrokeStyle(
                            lineWidth: edgeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                AppThemeInkCoreShape(variant: flower.variant)
                    .fill(inkColor.opacity(field.opacity * flower.opacity))
                    .frame(width: scale * 0.23, height: scale * 0.21)
            }
        }
    }
}

private struct AppThemeInkFlowerShape: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.5
        let petalCount = variant.isMultiple(of: 2) ? 5 : 6
        let lengthPatterns: [[CGFloat]] = [
            [0.92, 0.76, 0.86, 0.71, 0.82, 0.74],
            [0.78, 0.94, 0.72, 0.87, 0.76, 0.90],
            [0.84, 0.69, 0.96, 0.77, 0.88, 0.73],
            [0.73, 0.89, 0.80, 0.95, 0.70, 0.85],
        ]
        let widthPatterns: [[CGFloat]] = [
            [0.27, 0.34, 0.24, 0.31, 0.28, 0.30],
            [0.32, 0.25, 0.35, 0.27, 0.31, 0.24],
            [0.24, 0.31, 0.28, 0.35, 0.25, 0.29],
            [0.30, 0.26, 0.33, 0.23, 0.34, 0.27],
        ]
        let lengths = lengthPatterns[variant % lengthPatterns.count]
        let widths = widthPatterns[variant % widthPatterns.count]
        var path = Path()

        for index in 0..<petalCount {
            let angle = (-Double.pi / 2)
                + (Double(index) * 2 * Double.pi / Double(petalCount))
                + (Double(variant) * 0.09)
            let direction = CGVector(dx: CGFloat(cos(angle)), dy: CGFloat(sin(angle)))
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let length = radius * lengths[index]
            let width = radius * widths[index]
            let inner = radius * (0.08 + CGFloat((index + variant) % 2) * 0.025)

            let leadingRoot = point(center, direction, inner, normal, width * 0.22)
            let tip = point(center, direction, length, normal, width * -0.08)
            let trailingRoot = point(center, direction, inner * 0.86, normal, width * -0.24)
            path.move(to: leadingRoot)
            path.addCurve(
                to: tip,
                control1: point(center, direction, length * 0.42, normal, width),
                control2: point(center, direction, length * 0.82, normal, width * 0.52)
            )
            path.addCurve(
                to: trailingRoot,
                control1: point(center, direction, length * 0.76, normal, width * -0.62),
                control2: point(center, direction, length * 0.34, normal, width * -0.88)
            )
            path.closeSubpath()
        }
        return path
    }

    private func point(
        _ origin: CGPoint,
        _ direction: CGVector,
        _ forward: CGFloat,
        _ normal: CGVector,
        _ sideways: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: origin.x + (direction.dx * forward) + (normal.dx * sideways),
            y: origin.y + (direction.dy * forward) + (normal.dy * sideways)
        )
    }
}

private struct AppThemeInkCoreShape: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radii: [CGFloat] = [0.44, 0.52, 0.39, 0.48, 0.43, 0.54, 0.40, 0.49]
        let points = radii.enumerated().map { index, radius in
            let shiftedRadius = radii[(index + variant) % radii.count]
            let angle = (Double(index) * 2 * Double.pi / Double(radii.count))
                + (Double(variant) * 0.13)
            return CGPoint(
                x: center.x + (CGFloat(cos(angle)) * rect.width * shiftedRadius),
                y: center.y + (CGFloat(sin(angle)) * rect.height * radius)
            )
        }
        var path = Path()
        guard let first = points.first else { return path }
        let last = points[points.count - 1]
        path.move(to: midpoint(last, first))
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(points[index], next), control: points[index])
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}

private struct AppThemeInkSplashShape: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = min(rect.width, rect.height)
        var path = Path()

        for index in 0..<3 {
            let angle = (Double(index) * 2 * Double.pi / 3)
                + (Double(variant) * 0.41)
                + 0.22
            let direction = CGVector(dx: CGFloat(cos(angle)), dy: CGFloat(sin(angle)))
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let startRadius = scale * (0.17 + CGFloat(index) * 0.018)
            let endRadius = scale * (0.43 + CGFloat((index + variant) % 2) * 0.05)
            let halfWidth = scale * (0.014 + CGFloat(index) * 0.003)
            path.move(to: point(center, direction, startRadius, normal, halfWidth))
            path.addLine(to: point(center, direction, endRadius, normal, 0))
            path.addLine(to: point(center, direction, startRadius * 0.92, normal, -halfWidth))
            path.closeSubpath()
        }

        for index in 0..<9 {
            let angle = (Double(index) * 2 * Double.pi / 9)
                + (Double(variant) * 0.29)
            let distance = scale * (0.30 + CGFloat((index + variant) % 4) * 0.045)
            let dropletCenter = CGPoint(
                x: center.x + (CGFloat(cos(angle)) * distance),
                y: center.y + (CGFloat(sin(angle)) * distance)
            )
            let dropletWidth = scale * (0.025 + CGFloat((index + variant) % 3) * 0.011)
            let dropletHeight = dropletWidth * (1.15 + CGFloat(index % 2) * 0.42)
            path.addEllipse(
                in: CGRect(
                    x: dropletCenter.x - (dropletWidth / 2),
                    y: dropletCenter.y - (dropletHeight / 2),
                    width: dropletWidth,
                    height: dropletHeight
                )
            )
        }
        return path
    }

    private func point(
        _ origin: CGPoint,
        _ direction: CGVector,
        _ forward: CGFloat,
        _ normal: CGVector,
        _ sideways: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: origin.x + (direction.dx * forward) + (normal.dx * sideways),
            y: origin.y + (direction.dy * forward) + (normal.dy * sideways)
        )
    }
}

private struct AppThemeInkSplashFilamentShape: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = min(rect.width, rect.height)
        var path = Path()

        for index in 0..<4 {
            let angle = (Double(index) * 2 * Double.pi / 4)
                + (Double(variant) * 0.34)
                - 0.18
            let direction = CGVector(dx: CGFloat(cos(angle)), dy: CGFloat(sin(angle)))
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            path.move(to: CGPoint(
                x: center.x + (direction.dx * scale * 0.10),
                y: center.y + (direction.dy * scale * 0.10)
            ))
            path.addCurve(
                to: CGPoint(
                    x: center.x + (direction.dx * scale * 0.49),
                    y: center.y + (direction.dy * scale * 0.49)
                ),
                control1: CGPoint(
                    x: center.x + (direction.dx * scale * 0.24) + (normal.dx * scale * 0.035),
                    y: center.y + (direction.dy * scale * 0.24) + (normal.dy * scale * 0.035)
                ),
                control2: CGPoint(
                    x: center.x + (direction.dx * scale * 0.38) - (normal.dx * scale * 0.025),
                    y: center.y + (direction.dy * scale * 0.38) - (normal.dy * scale * 0.025)
                )
            )
        }
        return path
    }
}

private struct AppThemeSplatterShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height)
        var path = Path()

        let trails: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.10, 0.26, 0.01, 0.13, 0.006),
            (0.28, 0.73, 0.20, 0.88, 0.004),
            (0.43, 0.18, 0.37, 0.04, 0.005),
            (0.58, 0.62, 0.66, 0.49, 0.004),
            (0.71, 0.22, 0.80, 0.07, 0.006),
            (0.84, 0.69, 0.97, 0.78, 0.005),
            (0.92, 0.38, 0.99, 0.29, 0.003),
        ]
        for trail in trails {
            let start = point(x: trail.0, y: trail.1, in: rect)
            let end = point(x: trail.2, y: trail.3, in: rect)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(1, hypot(dx, dy))
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            let halfWidth = scale * trail.4
            path.move(to: CGPoint(
                x: start.x + (normal.dx * halfWidth),
                y: start.y + (normal.dy * halfWidth)
            ))
            path.addLine(to: end)
            path.addLine(to: CGPoint(
                x: start.x - (normal.dx * halfWidth),
                y: start.y - (normal.dy * halfWidth)
            ))
            path.closeSubpath()
        }

        for index in 0..<38 {
            let x = CGFloat(((index * 37) + 11) % 101) / 100
            let y = CGFloat(((index * 53) + 17) % 97) / 96
            let baseSize = scale * (0.0035 + (CGFloat((index * 7) % 5) * 0.0017))
            let dropletWidth = index.isMultiple(of: 13) ? baseSize * 1.8 : baseSize
            let dropletHeight = dropletWidth * (1.15 + (CGFloat(index % 3) * 0.34))
            let center = point(x: x, y: y, in: rect)
            path.addEllipse(
                in: CGRect(
                    x: center.x - (dropletWidth / 2),
                    y: center.y - (dropletHeight / 2),
                    width: dropletWidth,
                    height: dropletHeight
                )
            )
        }

        return path
    }

    private func point(x: CGFloat, y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + (x * rect.width),
            y: rect.minY + (y * rect.height)
        )
    }
}

private struct AppBehindWindowMaterialView: NSViewRepresentable {
    let tone: AppThemeTone

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.appearance = NSAppearance(
            named: tone == .light ? .aqua : .darkAqua
        )
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}
