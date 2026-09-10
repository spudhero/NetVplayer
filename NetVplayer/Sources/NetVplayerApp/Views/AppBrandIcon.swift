// NetVplayerApp/Views/AppBrandIcon.swift
// Shared rendering for the bundled application icon inside the app UI.

import AppKit
import SwiftUI

@MainActor
enum NetVplayerApplicationIcon {
    static let image: NSImage = {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon-Runtime", withExtension: "png"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            return NSApp.applicationIconImage
        }

        return icon
    }()
}

struct AppBrandIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NetVplayerApplicationIcon.image)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
