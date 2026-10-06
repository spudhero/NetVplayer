// WebHomeEngine/WebHomeDestination.swift
// Resolves the configured WebHome URL without creating WebKit objects.

import Foundation
import ProxyServer

public enum WebHomeDestination: Sendable, Equatable {
    case localDemo
    case remote(URL)

    public static func resolve(_ value: String) throws -> WebHomeDestination {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .localDemo }
        let safeURL = try ProxyAccessPolicy.validateTargetURL(trimmed)
        return .remote(safeURL)
    }
}
