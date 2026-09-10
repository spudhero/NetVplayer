import AppKit
import Foundation
import SwiftUI

@MainActor
enum PlayerVisualRegressionCaptureController {
    private static var renderingWindow: NSWindow?

    static func schedule(configuration: PlayerVisualRegressionConfiguration) {
        guard configuration.outputURL != nil else { return }
        DispatchQueue.main.async {
            presentRenderingWindow(configuration: configuration)
        }
    }

    private static func presentRenderingWindow(configuration: PlayerVisualRegressionConfiguration) {
        let contentRect = NSRect(origin: .zero, size: configuration.viewport)
        let appState = NetVplayerWindowCoordinator.shared.appState
        let rootView = PlayerView(
            playerState: appState.playerState,
            windowContext: PlayerWindowContext(),
            visualRegressionConfiguration: configuration
        )
        .environmentObject(appState)
        .frame(width: configuration.viewport.width, height: configuration.viewport.height)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        window.setFrame(contentRect, display: false)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        renderingWindow = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            capture(window: window, configuration: configuration)
        }
    }

    private static func capture(
        window: NSWindow,
        configuration: PlayerVisualRegressionConfiguration
    ) {
        guard let outputURL = configuration.outputURL,
              let contentView = window.contentView else {
            fail("visual regression output or content view is unavailable")
        }

        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = contentView.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width.rounded()),
                pixelsHigh: Int(bounds.height.rounded()),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else {
            fail("could not allocate visual regression bitmap")
        }

        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fail("could not encode visual regression PNG")
        }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: outputURL, options: .atomic)
            print("Captured player visual regression: \(outputURL.path)")
            NSApp.terminate(nil)
        } catch {
            fail("could not write visual regression PNG: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}
