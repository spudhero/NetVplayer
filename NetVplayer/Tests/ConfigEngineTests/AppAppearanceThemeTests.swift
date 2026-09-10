import AppKit
import Foundation
import SwiftUI
import Testing
import Storage
@testable import NetVplayerApp

@Suite("App appearance themes")
struct AppAppearanceThemeTests {
    @Test
    func stableThemeIdentifiersAndCodableRoundTrip() throws {
        #expect(AppAppearanceThemeID.allCases.map(\.rawValue) == [
            "legacy-deep-space",
            "aurora-violet",
            "crimson-petals",
            "deep-sea",
            "coral-dusk",
            "glacier-bloom",
            "orange-sea",
            "mint-lemon",
            "blush-sky",
            "lemon-summer",
            "sea-salt",
            "green-peach-blush",
            "caramel-sunrise",
            "monochrome-flow",
        ])
        #expect(AppAppearanceThemeID(rawValue: "peach-sunrise") == nil)
        #expect(AppAppearanceThemeID.orangeSea.displayName == "暮海橙光")
        #expect(AppAppearanceThemeID.caramelSunrise.displayName == "焦糖橙曦")
        #expect(AppAppearanceThemeID.caramelSunrise.symbolName == "cup.and.saucer.fill")
        #expect(AppAppearanceThemeID.monochromeFlow.displayName == "玄白流光")
        #expect(AppAppearanceThemeID.monochromeFlow.symbolName == "waveform.path")

        for id in AppAppearanceThemeID.allCases {
            let data = try JSONEncoder().encode(id)
            #expect(try JSONDecoder().decode(AppAppearanceThemeID.self, from: data) == id)
        }
    }

    @Test
    func defaultsAndUnknownIdentifiersUseDocumentedFallbacks() {
        #expect(AppAppearanceDefaults.releaseDefaultThemeID == .auroraViolet)
        #expect(AppAppearanceDefaults.resolvedThemeID(storedRawValue: nil) == .auroraViolet)
        #expect(AppAppearanceDefaults.resolvedThemeID(storedRawValue: "orange-sea") == .orangeSea)
        #expect(AppAppearanceDefaults.resolvedThemeID(storedRawValue: "future-theme") == .legacyDeepSpace)
    }

    @Test
    func catalogContainsSixLightAndEightDarkThemesWithDocumentedTransmission() {
        #expect(AppThemeCatalog.lightThemeIDs == [
            .blushSky,
            .mintLemon,
            .lemonSummer,
            .greenPeachBlush,
            .seaSalt,
            .orangeSea,
        ])
        #expect(AppThemeCatalog.darkThemeIDs == [
            .auroraViolet,
            .crimsonPetals,
            .legacyDeepSpace,
            .deepSea,
            .coralDusk,
            .glacierBloom,
            .caramelSunrise,
            .monochromeFlow,
        ])
        #expect(Set(AppThemeCatalog.lightThemeIDs).isDisjoint(with: AppThemeCatalog.darkThemeIDs))
        #expect(Set(AppThemeCatalog.lightThemeIDs + AppThemeCatalog.darkThemeIDs).count == 14)

        for id in AppThemeCatalog.lightThemeIDs {
            let palette = AppThemeCatalog.palette(for: id)
            #expect(palette.tone == .light)
            #expect(palette.preferredColorScheme == .light)
            #expect((0.26...0.32).contains(palette.desktopTransmission))
            #expect(palette.surfaceTokens.primarySidebarChromeOpacity == 0.30)
            #expect(palette.surfaceTokens.chromeOpacity == 0.26)
            #expect(palette.surfaceTokens.panelOpacity == 0.48)
        }

        for id in AppThemeCatalog.darkThemeIDs {
            let palette = AppThemeCatalog.palette(for: id)
            #expect(palette.tone == .dark)
            #expect(palette.preferredColorScheme == .dark)
            if [.caramelSunrise, .monochromeFlow].contains(id) {
                #expect(palette.desktopTransmission == 0)
            } else {
                #expect((0.18...0.22).contains(palette.desktopTransmission))
            }
            if id == .monochromeFlow {
                #expect(palette.surfaceTokens.primarySidebarChromeOpacity == 0.86)
                #expect(palette.surfaceTokens.chromeOpacity == 0.86)
                #expect(palette.surfaceTokens.panelOpacity == 0.72)
            } else {
                #expect(palette.surfaceTokens.primarySidebarChromeOpacity == 0.30)
                #expect(palette.surfaceTokens.chromeOpacity == 0.30)
                #expect(palette.surfaceTokens.panelOpacity == 0.38)
            }
        }
    }

    @Test
    func caramelSunriseUsesCoffeeAndBrightOrangeWithoutSacrificingContrast() {
        let caramel = AppThemeCatalog.palette(for: .caramelSunrise)

        #expect(caramel.tone == .dark)
        #expect(caramel.backgroundStops.map(\.hex) == [0x1D0804, 0x431208, 0x682109, 0x7A2B0C])
        #expect(caramel.backgroundStops.map(\.location) == [0, 0.34, 0.72, 1])
        #expect(caramel.gradientVector == AppThemeGradientVector(startX: 0.5, startY: 0, endX: 0.5, endY: 1))
        #expect(caramel.surfaceHex == 0x241109)
        #expect(caramel.foregroundHex == 0xFFF5EB)
        #expect(caramel.mutedHex == 0xDCC1AA)
        #expect(caramel.primaryAccentHex == 0xFFDDBB)
        #expect(caramel.secondaryAccentHex == 0xFFC27A)
        #expect(caramel.baseOpacity == 1.0)
        #expect(caramel.backdropAsset == nil)
        #expect(caramel.fields.map(\.kind) == [.band, .ellipse])
        #expect(caramel.fields.map(\.startHex) == [0xB63E00, 0xD95600])
        #expect(caramel.fields.map(\.endHex) == [0xFF8A00, 0xFFAA08])
        #expect(caramel.fields.map(\.centerX) == [0.52, 0.82])
        #expect(caramel.fields.map(\.centerY) == [0.91, 0.98])
        #expect(caramel.fields.map(\.widthScale) == [1.55, 0.46])
        #expect(caramel.fields.map(\.heightScale) == [0.18, 0.28])
        #expect(caramel.fields.map(\.rotationDegrees) == [-2, 0])
        #expect(caramel.fields.map(\.opacity) == [0.82, 0.58])
        #expect(caramel.fields.map(\.blurScale) == [0.030, 0.060])
    }

    @Test
    func monochromeFlowUsesPureBlackAndBundledReferenceArtwork() throws {
        let monochrome = AppThemeCatalog.palette(for: .monochromeFlow)

        #expect(monochrome.tone == .dark)
        #expect(monochrome.backgroundStops.map(\.hex) == [0x000000, 0x000000])
        #expect(monochrome.backgroundStops.map(\.location) == [0, 1])
        #expect(monochrome.gradientVector == AppThemeGradientVector(startX: 0, startY: 0.5, endX: 1, endY: 0.5))
        #expect(monochrome.surfaceHex == 0x101010)
        #expect(monochrome.foregroundHex == 0xFFFFFF)
        #expect(monochrome.mutedHex == 0xC7C7C7)
        #expect(monochrome.primaryAccentHex == 0xFFFFFF)
        #expect(monochrome.secondaryAccentHex == 0xD8D8D8)
        #expect(monochrome.baseOpacity == 1.0)
        #expect(monochrome.backdropAsset == .monochromeFlow)
        #expect(monochrome.fields.isEmpty)

        let resourceURL = try #require(AppThemeResourceBundle.url(for: .monochromeFlow))
        let image = try #require(NSImage(contentsOf: resourceURL))
        let representation = try #require(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        )
        #expect(representation.pixelsWide == 3840)
        #expect(representation.pixelsHigh == 2160)
    }

    @Test
    func palettesKeepStableCoreTokensAndThemeSpecificBackgrounds() {
        let legacy = AppThemeCatalog.palette(for: .legacyDeepSpace)
        #expect(legacy.backgroundStops.map(\.hex) == [0x02050D, 0x091A35, 0x0B3544])
        #expect(legacy.surfaceHex == 0x172A3B)
        #expect(legacy.foregroundHex == 0xF1F6FA)
        #expect(legacy.mutedHex == 0xA9BCC9)
        #expect(legacy.primaryAccentHex == 0x7EA6FF)
        #expect(legacy.secondaryAccentHex == 0xE3C36C)
        #expect(legacy.baseOpacity == 0.82)
        #expect(abs(legacy.desktopTransmission - 0.18) < 0.000_001)
        #expect(legacy.backgroundMode == .diffuseTranslucent)
        #expect(legacy.fields.map(\.kind) == [.band, .radial])

        let orange = AppThemeCatalog.palette(for: .orangeSea)
        #expect(orange.tone == .light)
        #expect(orange.backgroundStops.map(\.hex) == [0xE8F9FF, 0xC9EFF5, 0xFFD6BE, 0xFFF0DC])
        #expect(orange.gradientVector.startX == 0.5)
        #expect(orange.gradientVector.startY == 1)
        #expect(orange.gradientVector.endX == 0.5)
        #expect(orange.gradientVector.endY == 0)
        #expect(orange.fields.map(\.centerY) == [0.84, 0.52, 0.16])
        #expect(orange.surfaceHex == 0xFFF9F4)
        #expect(orange.foregroundHex == 0x263D3A)
        #expect(orange.mutedHex == 0x4D645F)
        #expect(orange.primaryAccentHex == 0x2F625E)
        #expect(orange.secondaryAccentHex == 0x984329)

        let crimson = AppThemeCatalog.palette(for: .crimsonPetals)
        #expect(crimson.backgroundStops.map(\.hex) == [0x020101, 0x43000B, 0x0A0103, 0x010101])
        #expect(crimson.surfaceHex == 0x261116)
        #expect(crimson.foregroundHex == 0xFFF4F2)
        #expect(crimson.mutedHex == 0xC9AAA7)
        #expect(crimson.primaryAccentHex == 0xFF6262)
        #expect(crimson.secondaryAccentHex == 0xD9B1A7)
        #expect(crimson.fields.map(\.kind) == [.radial, .inkBloom, .splatter])
        #expect(crimson.fields.map(\.startHex) == [0x62000D, 0x61000C, 0x78000F])
        #expect(crimson.fields.map(\.endHex) == [0x340006, 0xF3262E, 0xFF3038])
        #expect(crimson.fields.map(\.centerX) == [0.50, 0.50, 0.52])
        #expect(crimson.fields.map(\.centerY) == [0.50, 0.50, 0.50])

        let glacier = AppThemeCatalog.palette(for: .glacierBloom)
        #expect(glacier.backgroundStops.map(\.hex) == [0x031522, 0x0A3555, 0x312642])
        #expect(glacier.surfaceHex == 0x1A3046)
        #expect(glacier.foregroundHex == 0xF3FAFF)
        #expect(glacier.mutedHex == 0xAFC3D4)
        #expect(glacier.primaryAccentHex == 0x87C7FF)
        #expect(glacier.secondaryAccentHex == 0xF3A5C8)
        #expect(glacier.fields.map(\.kind) == [.band, .band, .ellipse])
        #expect(glacier.fields.map(\.startHex) == [0x2389C4, 0x5874D8, 0xDF69A9])
        #expect(glacier.fields.map(\.endHex) == [0x8AD8F2, 0xB26BC5, 0xFFB0CA])

        let lemon = AppThemeCatalog.palette(for: .lemonSummer)
        #expect(lemon.backgroundStops.map(\.hex) == [0xFFFDEB, 0xFFF2A6, 0xF0F7C7])
        #expect(lemon.surfaceHex == 0xFFFDF7)
        #expect(lemon.foregroundHex == 0x353219)
        #expect(lemon.mutedHex == 0x625E34)
        #expect(lemon.primaryAccentHex == 0x6F5B00)
        #expect(lemon.secondaryAccentHex == 0x3F6A22)
        #expect(lemon.baseOpacity == 0.70)

        let greenPeach = AppThemeCatalog.palette(for: .greenPeachBlush)
        #expect(greenPeach.backgroundStops.map(\.hex) == [0xF8FBEF, 0xF6F2E7, 0xFDE7EA, 0xFFE4E9])
        #expect(greenPeach.surfaceHex == 0xFFFDF8)
        #expect(greenPeach.foregroundHex == 0x3F342B)
        #expect(greenPeach.mutedHex == 0x6B5D52)
        #expect(greenPeach.primaryAccentHex == 0x876047)
        #expect(greenPeach.secondaryAccentHex == 0x8D4F66)
        #expect(greenPeach.baseOpacity == 0.72)

        for id in AppAppearanceThemeID.allCases {
            let palette = AppThemeCatalog.palette(for: id)
            #expect(palette.backgroundMode == .diffuseTranslucent)
            #expect((2...4).contains(palette.backgroundStops.count))
            #expect(palette.backgroundStops.first?.location == 0)
            #expect(palette.backgroundStops.last?.location == 1)
            #expect(palette.backdropAsset != nil || !palette.fields.isEmpty)
        }
    }

    @Test
    func crimsonPetalsUsesScatteredSmallRedAndBlackInkFlowers() throws {
        let flowers = AppThemeInkBloomComposition.flowers

        #expect(flowers.count == 15)
        #expect(flowers.count(where: { $0.tone == .crimson }) == 8)
        #expect(flowers.count(where: { $0.tone == .black }) == 7)
        #expect(try #require(flowers.map(\.scale).max()) <= 0.14)
        #expect(Set(flowers.map(\.variant)).count == 4)
        #expect(flowers.allSatisfy { (0...1).contains($0.centerX) && (0...1).contains($0.centerY) })
    }

    @Test
    func greenPeachBlushUsesThreeDirectionalPeachSkinTransitions() {
        let palette = AppThemeCatalog.palette(for: .greenPeachBlush)

        #expect(palette.fields.map(\.kind) == [
            .band, .band, .band, .ellipse, .ellipse, .ellipse,
        ])
        #expect(palette.fields.map(\.startHex) == [
            0x9CCB7A, 0xA4D07C, 0xB2D993, 0xF19AAC, 0xED6F90, 0xF7B7C3,
        ])
        #expect(palette.fields.map(\.endHex) == [
            0xF39AAF, 0xEF6F92, 0xF7B5C2, 0xF8BCC7, 0xF6A0AF, 0xFAD0D5,
        ])
        #expect(palette.fields.map(\.centerX) == [0.705, 0.346, 0.084, 0.90, 0.59, 0.11])
        #expect(palette.fields.map(\.centerY) == [0.085, 0.348, 0.448, 0.08, 0.59, 0.77])
        #expect(palette.fields.prefix(3).map(\.rotationDegrees) == [0, 32, 82])
        #expect(palette.fields[0].widthScale == 0.97)
        #expect(palette.fields[3].widthScale == 0.36)

        let topBlush = palette.fields[3]
        let diagonalBlush = palette.fields[4]
        let lowerBlush = palette.fields[5]
        #expect(diagonalBlush.opacity > topBlush.opacity)
        #expect(topBlush.opacity > lowerBlush.opacity)
    }

    @Test
    func fieldRecipesAreValidAndSpatiallyDistinct() {
        #expect(AppThemeFieldKind.allCases == [.radial, .ellipse, .band, .inkBloom, .splatter])
        #expect(Set(AppThemeCatalog.palettes.values.flatMap { $0.fields.map(\.kind) }) == Set(AppThemeFieldKind.allCases))

        var compositionSignatures = Set<String>()
        for id in AppAppearanceThemeID.allCases {
            let palette = AppThemeCatalog.palette(for: id)
            let locations = palette.backgroundStops.map(\.location)
            #expect(locations == locations.sorted())

            for field in palette.fields {
                #expect((-0.25...1.25).contains(field.centerX))
                #expect((-0.25...1.25).contains(field.centerY))
                #expect((0.10...1.60).contains(field.widthScale))
                #expect((0.10...1.60).contains(field.heightScale))
                #expect((-180...180).contains(field.rotationDegrees))
                #expect((0.01...1).contains(field.opacity))
                #expect((0...0.25).contains(field.blurScale))
                if field.kind == .radial {
                    #expect(abs(field.widthScale - field.heightScale) < 0.000_001)
                }
            }

            let fieldSignature = palette.fields.map {
                "\($0.kind.rawValue):\($0.centerX):\($0.centerY):\($0.widthScale):\($0.heightScale):\($0.rotationDegrees)"
            }.joined(separator: "|")
            let signature = "\(palette.gradientVector.startX):\(palette.gradientVector.startY):\(fieldSignature)"
            #expect(compositionSignatures.insert(signature).inserted)
        }
    }

    @Test
    func reducedTransparencyAndPlaybackForceOpaqueBackgrounds() {
        let palette = AppThemeCatalog.palette(for: .orangeSea)
        #expect(palette.effectiveBackgroundMode(reduceTransparency: false, forceOpaque: false) == .diffuseTranslucent)
        #expect(palette.effectiveBackgroundMode(reduceTransparency: true, forceOpaque: false) == .opaque)
        #expect(palette.effectiveBackgroundMode(reduceTransparency: false, forceOpaque: true) == .opaque)
    }

    @Test
    func textAndAccentContrastMeetsTheContractOnEveryBackgroundAndSurface() {
        for id in AppAppearanceThemeID.allCases {
            let palette = AppThemeCatalog.palette(for: id)
            let canvases = palette.backgroundStops.map(\.hex) + [palette.surfaceHex]

            for canvas in canvases {
                for foreground in [
                    palette.foregroundHex,
                    palette.mutedHex,
                    palette.primaryAccentHex,
                    palette.secondaryAccentHex,
                ] {
                    #expect(
                        AppThemePalette.contrastRatio(foreground, canvas) >= 4.5,
                        "\(id.rawValue): \(String(foreground, radix: 16)) on \(String(canvas, radix: 16))"
                    )
                }
            }

            #expect(
                AppThemePalette.contrastRatio(
                    palette.hex(for: .onAccent),
                    palette.primaryAccentHex
                ) >= 4.5
            )
            let expectedSuccess = palette.tone == .light
                ? AppThemePalette.lightSuccessHex
                : AppThemePalette.darkSuccessHex
            #expect(palette.hex(for: .success) == expectedSuccess)
        }
    }

    @Test
    func reducedTransparencyUsesOpaqueSemanticSurfaces() {
        for id in AppAppearanceThemeID.allCases {
            let palette = AppThemeCatalog.palette(for: id)
            #expect(palette.surfaceOpacity(for: .chrome, reduceTransparency: true) == 0.92)
            #expect(palette.surfaceOpacity(for: .panel, reduceTransparency: true) == 0.96)
            #expect(palette.surfaceOpacity(for: .control, reduceTransparency: true) == 0.90)
            #expect(palette.surfaceOpacity(for: .raised, reduceTransparency: true) == 1.0)
        }
    }

    @Test @MainActor
    func glacierBloomPlacesBlueAndPinkInTheBackdropInsteadOfPrimaryControls() throws {
        let stats = try renderedBackdropStats(for: .glacierBloom)
        let left = try #require(meanSample(in: stats) { $0.column <= 4 })
        let middle = try #require(meanSample(in: stats) { (6...9).contains($0.column) })
        let right = try #require(meanSample(in: stats) { $0.column >= 11 })

        #expect(left.blue - left.red >= 0.08)
        #expect(right.red - right.green >= 0.025)
        #expect(right.blue - right.green >= 0.05)
        #expect(middle.blue > middle.red)
        #expect(AppThemeCatalog.palette(for: .glacierBloom).primaryAccentHex == 0x87C7FF)
    }

    @Test @MainActor
    func greenPeachBlushRendersGreenPathsIntoThreePinkTargets() throws {
        let stats = try renderedBackdropStats(
            for: .greenPeachBlush,
            size: CGSize(width: 320, height: 200),
            sampleStride: 5
        )
        let horizontalGreen = try #require(meanSample(in: stats, near: CGPoint(x: 0.55, y: 0.085)))
        let diagonalGreen = try #require(meanSample(in: stats, near: CGPoint(x: 0.13, y: 0.13)))
        let verticalGreen = try #require(meanSample(in: stats, near: CGPoint(x: 0.06, y: 0.17)))
        let topPink = try #require(meanSample(in: stats, near: CGPoint(x: 0.90, y: 0.08)))
        let diagonalPink = try #require(meanSample(in: stats, near: CGPoint(x: 0.59, y: 0.59)))
        let lowerPink = try #require(meanSample(in: stats, near: CGPoint(x: 0.11, y: 0.77)))

        for green in [horizontalGreen, diagonalGreen, verticalGreen] {
            #expect(green.green > green.red)
        }
        for pink in [topPink, diagonalPink, lowerPink] {
            #expect(pink.red > pink.green)
        }
        #expect(diagonalPink.red - diagonalPink.green > topPink.red - topPink.green)
        #expect(topPink.red - topPink.green > lowerPink.red - lowerPink.green)
    }

    @Test @MainActor
    func caramelSunriseRendersMostlyCoffeeWithAControlledBottomOrangeGlow() throws {
        let stats = try renderedBackdropStats(
            for: .caramelSunrise,
            size: CGSize(width: 320, height: 200),
            sampleStride: 4
        )
        let coffeeFraction = sampleFraction(in: stats) { sample in
            sample.luminance <= 0.28
                && sample.red - sample.green >= 0.045
                && sample.green - sample.blue >= 0.005
        }
        let orangeFraction = sampleFraction(in: stats) { sample in
            sample.luminance > 0.32
                && sample.red >= sample.green * 1.35
                && sample.blue <= 0.16
        }
        let nearWhiteFraction = sampleFraction(in: stats) { sample in
            min(sample.red, sample.green, sample.blue) >= 0.92
        }
        let yellowFraction = sampleFraction(in: stats) { sample in
            sample.red >= 0.75 && sample.green >= 0.70 && sample.blue <= 0.35
        }
        let upperCoffee = try #require(
            meanSample(in: stats, near: CGPoint(x: 0.50, y: 0.22), radius: 0.12)
        )
        let lowerOrange = try #require(
            meanSample(in: stats, near: CGPoint(x: 0.60, y: 0.93), radius: 0.08)
        )

        #expect(coffeeFraction >= 0.70, "coffee fraction: \(coffeeFraction)")
        #expect((0.08...0.20).contains(orangeFraction), "orange fraction: \(orangeFraction)")
        #expect(nearWhiteFraction < 0.01, "near-white fraction: \(nearWhiteFraction)")
        #expect(yellowFraction < 0.01, "yellow fraction: \(yellowFraction)")
        #expect(upperCoffee.red > upperCoffee.green * 2.0)
        #expect(lowerOrange.red > lowerOrange.green)
        #expect(lowerOrange.green - upperCoffee.green >= 0.12)
        #expect(lowerOrange.luminance - upperCoffee.luminance >= 0.16)
    }

    @Test @MainActor
    func monochromeFlowRendersConnectedWhiteRibbonAcrossPureBlackNegativeSpace() throws {
        let stats = try renderedBackdropStats(
            for: .monochromeFlow,
            size: CGSize(width: 320, height: 180),
            sampleStride: 2
        )
        let blackFraction = sampleFraction(in: stats) { $0.luminance <= 0.04 }
        let nearWhiteFraction = sampleFraction(in: stats) { sample in
            min(sample.red, sample.green, sample.blue) >= 0.89
        }
        let litColumns = Set(
            stats.samples
                .filter { $0.luminance >= 0.16 }
                .map(\.column)
        )
        let topLeft = try #require(meanSample(in: stats, near: CGPoint(x: 0.05, y: 0.05)))
        let topRight = try #require(meanSample(in: stats, near: CGPoint(x: 0.95, y: 0.05)))
        let bottomLeft = try #require(meanSample(in: stats, near: CGPoint(x: 0.05, y: 0.95)))
        let bottomRight = try #require(meanSample(in: stats, near: CGPoint(x: 0.95, y: 0.95)))
        let chromeStats = try renderedChromeStats(for: .monochromeFlow)
        let brightestChromeSample = try #require(chromeStats.samples.map(\.luminance).max())

        #expect(blackFraction >= 0.70, "black fraction: \(blackFraction)")
        #expect(nearWhiteFraction >= 0.015, "near-white fraction: \(nearWhiteFraction)")
        #expect(stats.meanChroma < 0.02, "mean chroma: \(stats.meanChroma)")
        #expect(
            longestConsecutiveRun(in: litColumns)
                >= Int(Double(stats.sampleColumns) * 0.95)
        )
        #expect(litColumns.contains(0))
        #expect(litColumns.contains(stats.sampleColumns - 1))
        #expect(topLeft.luminance <= 0.02)
        #expect(topRight.luminance <= 0.02)
        #expect(bottomLeft.luminance <= 0.02)
        #expect(bottomRight.luminance <= 0.02)
        #expect(brightestChromeSample <= 0.24, "brightest chrome sample: \(brightestChromeSample)")
    }

    @Test @MainActor
    func crimsonPetalsKeepsDarkNegativeSpaceAndSeparatedRedInkDetails() throws {
        let stats = try renderedBackdropStats(
            for: .crimsonPetals,
            size: CGSize(width: 384, height: 216),
            sampleStride: 8
        )
        let redMask = stats.samples.map { sample in
            sample.red >= 0.14
                && sample.red - sample.green >= 0.07
                && sample.red - sample.blue >= 0.045
        }
        let darkCount = stats.samples.count { sample in
            (0.2126 * sample.red) + (0.7152 * sample.green) + (0.0722 * sample.blue) < 0.08
        }

        #expect(Double(darkCount) / Double(stats.samples.count) >= 0.52)
        #expect(redMask.count(where: { $0 }) >= 28)
        #expect(
            connectedComponentCount(
                active: redMask,
                columns: stats.sampleColumns,
                rows: stats.sampleRows
            ) >= 4
        )
    }

    @Test
    func userPreferencePersistsAndClearsTheStableThemeIdentifier() throws {
        let domain = "AppAppearanceThemeTests.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = UserPreferences(defaults: defaults)

        #expect(preferences.appearanceThemeID == nil)
        for id in AppAppearanceThemeID.allCases {
            preferences.appearanceThemeID = id.rawValue
            #expect(preferences.appearanceThemeID == id.rawValue)
        }
        preferences.appearanceThemeID = nil
        #expect(preferences.appearanceThemeID == nil)
    }

    @Test
    func backupThemeFieldIsOptionalAndRoundTripsWhenPresent() throws {
        let oldBackup = try JSONDecoder().decode(
            UserPreferenceSnapshot.self,
            from: Data("{}".utf8)
        )
        #expect(oldBackup.appearanceThemeID == nil)

        let sourceDomain = "AppAppearanceThemeTests.backup.source.\(UUID().uuidString)"
        let targetDomain = "AppAppearanceThemeTests.backup.target.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceDomain))
        let targetDefaults = try #require(UserDefaults(suiteName: targetDomain))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceDomain)
            targetDefaults.removePersistentDomain(forName: targetDomain)
        }

        let source = UserPreferences(defaults: sourceDefaults)
        let target = UserPreferences(defaults: targetDefaults)
        target.appearanceThemeID = AppAppearanceThemeID.orangeSea.rawValue

        oldBackup.apply(to: target)
        #expect(target.appearanceThemeID == "orange-sea")

        for id in AppAppearanceThemeID.allCases {
            source.appearanceThemeID = id.rawValue
            let encoded = try JSONEncoder().encode(UserPreferenceSnapshot(preferences: source))
            let decoded = try JSONDecoder().decode(UserPreferenceSnapshot.self, from: encoded)
            decoded.apply(to: target)

            #expect(decoded.appearanceThemeID == id.rawValue)
            #expect(target.appearanceThemeID == id.rawValue)
        }
    }

    @Test @MainActor
    func appearanceThemePickerRendersAStableNonblankPreviewGrid() throws {
        let size = CGSize(width: 900, height: 900)
        let renderer = ImageRenderer(
            content: AppearanceThemePicker(selectedThemeID: .orangeSea) { _ in }
                .environment(
                    \.appThemePalette,
                    AppThemeCatalog.palette(for: .orangeSea)
                )
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        )
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1

        let image = try #require(renderer.nsImage)
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))

        #expect(bitmap.pixelsWide == Int(size.width))
        #expect(bitmap.pixelsHigh == Int(size.height))
        #expect(pngData.count > 45_000)

        var sampledColors = Set<String>()
        for x in stride(from: 8, to: bitmap.pixelsWide, by: 24) {
            for y in stride(from: 8, to: bitmap.pixelsHigh, by: 24) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                sampledColors.insert(
                    "\(Int(color.redComponent * 255))-\(Int(color.greenComponent * 255))-\(Int(color.blueComponent * 255))-\(Int(color.alphaComponent * 255))"
                )
            }
        }
        #expect(sampledColors.count > 24)

        let lightSamples = try AppThemeCatalog.lightThemeIDs.map {
            try renderedBackdropStats(for: $0)
        }
        let darkSamples = try AppThemeCatalog.darkThemeIDs.map {
            try renderedBackdropStats(for: $0)
        }
        #expect((lightSamples.map { $0.meanLuminance }.min() ?? 0) > 0.62)
        for (id, sample) in zip(AppThemeCatalog.darkThemeIDs, darkSamples) {
            #expect(
                sample.meanLuminance < 0.28,
                "\(id.rawValue): \(sample.meanLuminance)"
            )
        }
        #expect(
            Set((lightSamples + darkSamples).map { $0.signature }).count
                == AppAppearanceThemeID.allCases.count
        )

        let statsByID = Dictionary(
            uniqueKeysWithValues: try AppAppearanceThemeID.allCases.map {
                ($0, try renderedBackdropStats(for: $0))
            }
        )
        try expectSpatialDistance(
            between: .blushSky,
            and: .seaSalt,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .lemonSummer,
            and: .mintLemon,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .lemonSummer,
            and: .orangeSea,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .greenPeachBlush,
            and: .blushSky,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .orangeSea,
            and: .seaSalt,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .orangeSea,
            and: .blushSky,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .crimsonPetals,
            and: .coralDusk,
            atLeast: 0.10,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .crimsonPetals,
            and: .legacyDeepSpace,
            atLeast: 0.075,
            statsByID: statsByID
        )
        try expectSpatialDistance(
            between: .legacyDeepSpace,
            and: .deepSea,
            atLeast: 0.075,
            statsByID: statsByID
        )
        for (index, lhs) in AppThemeCatalog.darkThemeIDs.enumerated() {
            for rhs in AppThemeCatalog.darkThemeIDs.dropFirst(index + 1) {
                let minimum = [.legacyDeepSpace, .auroraViolet, .glacierBloom].contains(lhs)
                    && [.legacyDeepSpace, .auroraViolet, .glacierBloom].contains(rhs)
                    ? 0.075
                    : 0.045
                try expectSpatialDistance(
                    between: lhs,
                    and: rhs,
                    atLeast: minimum,
                    statsByID: statsByID
                )
            }
        }
        for (index, lhs) in AppThemeCatalog.lightThemeIDs.enumerated() {
            for rhs in AppThemeCatalog.lightThemeIDs.dropFirst(index + 1) {
                try expectSpatialDistance(
                    between: lhs,
                    and: rhs,
                    atLeast: 0.045,
                    statsByID: statsByID
                )
            }
        }

        if let outputPath = ProcessInfo.processInfo.environment["NETVPLAYER_THEME_SNAPSHOT_PATH"] {
            try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }

    @Test @MainActor
    func lightChromeKeepsEveryThemeVisibleAndSpatiallyDistinct() throws {
        let statsByID = Dictionary(
            uniqueKeysWithValues: try AppThemeCatalog.lightThemeIDs.map {
                ($0, try renderedChromeStats(for: $0))
            }
        )

        #expect(Set(statsByID.values.map(\.signature)).count == AppThemeCatalog.lightThemeIDs.count)
        for id in AppThemeCatalog.lightThemeIDs {
            let stats = try #require(statsByID[id])
            #expect(stats.meanChroma >= 0.025, "\(id.rawValue): \(stats.meanChroma) < 0.025")
        }

        for (index, lhs) in AppThemeCatalog.lightThemeIDs.enumerated() {
            for rhs in AppThemeCatalog.lightThemeIDs.dropFirst(index + 1) {
                try expectSpatialDistance(
                    between: lhs,
                    and: rhs,
                    atLeast: 0.03,
                    statsByID: statsByID
                )
            }
        }
    }

    @Test @MainActor
    func lightPrimarySidebarKeepsEveryThemeVisibleAndSpatiallyDistinct() throws {
        let statsByID = Dictionary(
            uniqueKeysWithValues: try AppThemeCatalog.lightThemeIDs.map {
                ($0, try renderedPrimarySidebarStats(for: $0))
            }
        )

        #expect(Set(statsByID.values.map(\.signature)).count == AppThemeCatalog.lightThemeIDs.count)
        for id in AppThemeCatalog.lightThemeIDs {
            let stats = try #require(statsByID[id])
            #expect(stats.meanChroma >= 0.025, "\(id.rawValue): \(stats.meanChroma) < 0.025")
        }

        for (index, lhs) in AppThemeCatalog.lightThemeIDs.enumerated() {
            for rhs in AppThemeCatalog.lightThemeIDs.dropFirst(index + 1) {
                try expectSpatialDistance(
                    between: lhs,
                    and: rhs,
                    atLeast: 0.03,
                    statsByID: statsByID
                )
            }
        }
    }

    @Test @MainActor
    func primarySidebarOverrideDoesNotBypassReducedTransparency() throws {
        for id in AppThemeCatalog.lightThemeIDs {
            let primary = try renderedPrimarySidebarStats(for: id, reduceTransparency: true)
            let standard = try renderedChromeStats(for: id, reduceTransparency: true)
            #expect(primary.signature == standard.signature, "\(id.rawValue)")
        }
    }

    @Test @MainActor
    func brandIconSurfaceKeepsBackdropVisibleAcrossLightAndDarkThemes() throws {
        for id in [AppAppearanceThemeID.greenPeachBlush, .legacyDeepSpace] {
            let backdrop = try renderedBackdropStats(for: id)
            let translucent = try renderedBrandIconSurfaceStats(for: id)
            let reducedTransparency = try renderedBrandIconSurfaceStats(
                for: id,
                reduceTransparency: true
            )
            let translucentDistance = spatialDistance(between: translucent, and: backdrop)
            let opaqueDistance = spatialDistance(between: reducedTransparency, and: backdrop)

            #expect(opaqueDistance > 0.01, "\(id.rawValue): \(opaqueDistance)")
            #expect(
                translucentDistance < opaqueDistance * 0.55,
                "\(id.rawValue): \(translucentDistance) / \(opaqueDistance)"
            )
        }
    }

    @Test @MainActor
    func darkChromeKeepsEveryThemeVisibleAndSpatiallyDistinct() throws {
        let statsByID = Dictionary(
            uniqueKeysWithValues: try AppThemeCatalog.darkThemeIDs.map {
                ($0, try renderedChromeStats(for: $0))
            }
        )

        #expect(Set(statsByID.values.map(\.signature)).count == AppThemeCatalog.darkThemeIDs.count)
        for id in AppThemeCatalog.darkThemeIDs {
            let stats = try #require(statsByID[id])
            if id == .monochromeFlow {
                #expect(stats.meanChroma < 0.02, "\(id.rawValue): \(stats.meanChroma) >= 0.02")
            } else {
                #expect(stats.meanChroma >= 0.025, "\(id.rawValue): \(stats.meanChroma) < 0.025")
            }
        }

        for (index, lhs) in AppThemeCatalog.darkThemeIDs.enumerated() {
            for rhs in AppThemeCatalog.darkThemeIDs.dropFirst(index + 1) {
                try expectSpatialDistance(
                    between: lhs,
                    and: rhs,
                    atLeast: 0.03,
                    statsByID: statsByID
                )
            }
        }
    }

    @Test @MainActor
    func vodDetailBackgroundRetainsEveryPaletteSpatialIdentity() throws {
        let detailStats = try Dictionary(
            uniqueKeysWithValues: AppAppearanceThemeID.allCases.map {
                ($0, try renderedDetailBackdropStats(for: $0))
            }
        )
        #expect(
            Set(detailStats.values.map(\.signature)).count
                == AppAppearanceThemeID.allCases.count
        )

        for id in AppAppearanceThemeID.allCases {
            let detail = try #require(detailStats[id])
            let reference = try renderedDetailBackdropReferenceStats(for: id)
            let distance = spatialDistance(between: detail, and: reference)
            #expect(distance <= 0.01, "\(id.rawValue): \(distance) > 0.01")
        }
    }

    @MainActor
    private func renderedBackdropStats(
        for id: AppAppearanceThemeID,
        size: CGSize = CGSize(width: 160, height: 90),
        sampleStride: Int = 10
    ) throws -> BackdropStats {
        let palette = AppThemeCatalog.palette(for: id)
        return try renderedStats(
            content: AppThemeBackdropLayer(palette: palette)
                .frame(width: size.width, height: size.height),
            size: size,
            sampleStride: sampleStride
        )
    }

    @MainActor
    private func renderedChromeStats(
        for id: AppAppearanceThemeID,
        reduceTransparency: Bool = false
    ) throws -> BackdropStats {
        let size = CGSize(width: 218, height: 640)
        let palette = AppThemeCatalog.palette(for: id)
        return try renderedStats(
            content: ZStack {
                AppThemeBackdropLayer(palette: palette)
                AppGlassSurface(
                    cornerRadius: 0,
                    role: .chrome,
                    reduceTransparencyOverride: reduceTransparency
                )
            }
                .environment(\.appThemePalette, palette)
                .frame(width: size.width, height: size.height),
            size: size,
            sampleStride: 20
        )
    }

    @MainActor
    private func renderedPrimarySidebarStats(
        for id: AppAppearanceThemeID,
        reduceTransparency: Bool = false
    ) throws -> BackdropStats {
        let size = CGSize(width: 218, height: 640)
        let palette = AppThemeCatalog.palette(for: id)
        return try renderedStats(
            content: ZStack {
                AppThemeBackdropLayer(palette: palette)
                AppGlassSurface(
                    cornerRadius: 0,
                    role: .chrome,
                    normalOpacityOverride: palette.surfaceTokens.primarySidebarChromeOpacity,
                    reduceTransparencyOverride: reduceTransparency
                )
            }
                .environment(\.appThemePalette, palette)
                .frame(width: size.width, height: size.height),
            size: size,
            sampleStride: 20
        )
    }

    @MainActor
    private func renderedBrandIconSurfaceStats(
        for id: AppAppearanceThemeID,
        reduceTransparency: Bool = false
    ) throws -> BackdropStats {
        let size = CGSize(width: 160, height: 90)
        let palette = AppThemeCatalog.palette(for: id)
        return try renderedStats(
            content: ZStack {
                AppThemeBackdropLayer(palette: palette)
                AppGlassSurface(
                    cornerRadius: 0,
                    role: .raised,
                    normalOpacityOverride: HomeVisualPolicy.sidebarBrandSurfaceOpacity,
                    usesSystemMaterial: false,
                    reduceTransparencyOverride: reduceTransparency
                )
            }
                .environment(\.appThemePalette, palette)
                .frame(width: size.width, height: size.height),
            size: size
        )
    }

    @MainActor
    private func renderedDetailBackdropStats(
        for id: AppAppearanceThemeID
    ) throws -> BackdropStats {
        let size = CGSize(width: 320, height: 180)
        let palette = AppThemeCatalog.palette(for: id)
        return try renderedStats(
            content: VodDetailThemeBackground(
                palette: palette,
                artworkURL: "",
                siteHeader: nil
            )
                .frame(width: size.width, height: size.height),
            size: size
        )
    }

    @MainActor
    private func renderedDetailBackdropReferenceStats(
        for id: AppAppearanceThemeID
    ) throws -> BackdropStats {
        let size = CGSize(width: 320, height: 180)
        let palette = AppThemeCatalog.palette(for: id)
        return try renderedStats(
            content: AppThemeBackdropLayer(palette: palette)
                .frame(width: size.width, height: size.height),
            size: size
        )
    }

    @MainActor
    private func renderedStats<Content: View>(
        content: Content,
        size: CGSize,
        sampleStride: Int = 10
    ) throws -> BackdropStats {
        let renderer = ImageRenderer(
            content: content
        )
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1

        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var luminanceTotal = 0.0
        var sampleCount = 0
        var signatureParts: [String] = []
        var samples: [RGBSample] = []
        let sampleOffset = max(1, sampleStride / 2)
        var sampleRows = 0
        var sampleColumns = 0

        for (row, y) in stride(from: sampleOffset, to: bitmap.pixelsHigh, by: sampleStride).enumerated() {
            sampleRows = max(sampleRows, row + 1)
            for (column, x) in stride(from: sampleOffset, to: bitmap.pixelsWide, by: sampleStride).enumerated() {
                sampleColumns = max(sampleColumns, column + 1)
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                luminanceTotal += (0.2126 * color.redComponent)
                    + (0.7152 * color.greenComponent)
                    + (0.0722 * color.blueComponent)
                sampleCount += 1
                signatureParts.append(
                    "\(Int(color.redComponent * 31))-\(Int(color.greenComponent * 31))-\(Int(color.blueComponent * 31))"
                )
                samples.append(
                    RGBSample(
                        red: Double(color.redComponent),
                        green: Double(color.greenComponent),
                        blue: Double(color.blueComponent),
                        column: column,
                        row: row
                    )
                )
            }
        }

        return BackdropStats(
            meanLuminance: sampleCount == 0 ? 0 : luminanceTotal / Double(sampleCount),
            signature: signatureParts.joined(separator: ":"),
            samples: samples,
            sampleColumns: sampleColumns,
            sampleRows: sampleRows
        )
    }

    private func meanSample(
        in stats: BackdropStats,
        where predicate: (RGBSample) -> Bool
    ) -> RGBSample? {
        let matching = stats.samples.filter(predicate)
        guard !matching.isEmpty else { return nil }
        let totals = matching.reduce((red: 0.0, green: 0.0, blue: 0.0)) { result, sample in
            (
                red: result.red + sample.red,
                green: result.green + sample.green,
                blue: result.blue + sample.blue
            )
        }
        let count = Double(matching.count)
        return RGBSample(
            red: totals.red / count,
            green: totals.green / count,
            blue: totals.blue / count,
            column: 0,
            row: 0
        )
    }

    private func sampleFraction(
        in stats: BackdropStats,
        where predicate: (RGBSample) -> Bool
    ) -> Double {
        guard !stats.samples.isEmpty else { return 0 }
        return Double(stats.samples.count(where: predicate)) / Double(stats.samples.count)
    }

    private func meanSample(
        in stats: BackdropStats,
        near point: CGPoint,
        radius: Double = 0.05
    ) -> RGBSample? {
        meanSample(in: stats) { sample in
            let normalizedX = (Double(sample.column) + 0.5) / Double(stats.sampleColumns)
            let normalizedY = (Double(sample.row) + 0.5) / Double(stats.sampleRows)
            return hypot(
                normalizedX - Double(point.x),
                normalizedY - Double(point.y)
            ) <= radius
        }
    }

    private func connectedComponentCount(
        active: [Bool],
        columns: Int,
        rows: Int
    ) -> Int {
        guard columns > 0, rows > 0, active.count == columns * rows else { return 0 }
        var visited = Array(repeating: false, count: active.count)
        var count = 0

        for index in active.indices where active[index] && !visited[index] {
            count += 1
            var stack = [index]
            visited[index] = true
            while let current = stack.popLast() {
                let column = current % columns
                let row = current / columns
                let neighbors = [
                    column > 0 ? current - 1 : -1,
                    column + 1 < columns ? current + 1 : -1,
                    row > 0 ? current - columns : -1,
                    row + 1 < rows ? current + columns : -1,
                ]
                for neighbor in neighbors
                where neighbor >= 0 && active[neighbor] && !visited[neighbor] {
                    visited[neighbor] = true
                    stack.append(neighbor)
                }
            }
        }
        return count
    }

    private func longestConsecutiveRun(in values: Set<Int>) -> Int {
        guard let maximum = values.max() else { return 0 }
        var longest = 0
        var current = 0
        for value in 0...maximum {
            if values.contains(value) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private func expectSpatialDistance(
        between lhsID: AppAppearanceThemeID,
        and rhsID: AppAppearanceThemeID,
        atLeast minimum: Double,
        statsByID: [AppAppearanceThemeID: BackdropStats]
    ) throws {
        let lhs = try #require(statsByID[lhsID])
        let rhs = try #require(statsByID[rhsID])
        let distance = spatialDistance(between: lhs, and: rhs)
        #expect(
            distance >= minimum,
            "\(lhsID.rawValue) / \(rhsID.rawValue): \(distance) < \(minimum)"
        )
    }

    private func spatialDistance(
        between lhs: BackdropStats,
        and rhs: BackdropStats
    ) -> Double {
        let count = min(lhs.samples.count, rhs.samples.count)
        let squaredDifference = zip(lhs.samples.prefix(count), rhs.samples.prefix(count))
            .reduce(0.0) { result, pair in
                result
                    + pow(pair.0.red - pair.1.red, 2)
                    + pow(pair.0.green - pair.1.green, 2)
                    + pow(pair.0.blue - pair.1.blue, 2)
            }
        return count == 0
            ? 0
            : sqrt(squaredDifference / Double(count * 3))
    }

    private struct RGBSample {
        let red: Double
        let green: Double
        let blue: Double
        let column: Int
        let row: Int

        var luminance: Double {
            (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        }
    }

    private struct BackdropStats {
        let meanLuminance: Double
        let signature: String
        let samples: [RGBSample]
        let sampleColumns: Int
        let sampleRows: Int

        var meanChroma: Double {
            guard !samples.isEmpty else { return 0 }
            let total = samples.reduce(0.0) { result, sample in
                result + max(sample.red, sample.green, sample.blue)
                    - min(sample.red, sample.green, sample.blue)
            }
            return total / Double(samples.count)
        }
    }
}
