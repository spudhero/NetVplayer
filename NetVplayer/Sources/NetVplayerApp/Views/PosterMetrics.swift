// NetVplayerApp/Views/PosterMetrics.swift
// Shared poster sizing used by grids and detail surfaces.

import SwiftUI

enum PosterMetrics {
    static let aspectRatio: CGFloat = 2.0 / 3.0
    static let detailWidth: CGFloat = 190
    static let detailHeight: CGFloat = detailWidth / aspectRatio
}

struct PosterAspectContainer<Content: View>: View {
    let width: CGFloat
    private let content: Content

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        Color.clear
            .frame(width: width, height: width / PosterMetrics.aspectRatio)
            .overlay {
                content
                    .scaledToFill()
            }
            .clipped()
    }
}
