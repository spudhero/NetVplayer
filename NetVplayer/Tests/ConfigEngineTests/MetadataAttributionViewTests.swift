import AppKit
import SwiftUI
import Testing
@testable import NetVplayerApp

struct MetadataAttributionViewTests {
    @Test @MainActor
    func attributionRendersWithItsBundledTMDBLogo() throws {
        let logo = try #require(AppThemeResourceBundle.bundle.image(forResource: "TMDB"))
        #expect(logo.size.width > 0)
        #expect(logo.size.height > 0)

        let hostingView = NSHostingView(rootView: MetadataAttributionView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 140)
        hostingView.layoutSubtreeIfNeeded()

        let fittedSize = hostingView.fittingSize
        #expect(fittedSize.width > 0)
        #expect(fittedSize.height > 0)
    }
}
