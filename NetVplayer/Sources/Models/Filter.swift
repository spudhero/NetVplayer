// Models/Filter.swift
// 筛选条件模型

import Foundation

public enum FilterInputKind: String, Codable, Sendable {
    case options
    case text
}

/// 筛选条件
public struct Filter: Codable, Sendable, Equatable {
    public var key: String
    public var name: String
    public var values: [FilterValue]
    public var inputKind: FilterInputKind
    public var isRequired: Bool

    public init(
        key: String = "",
        name: String = "",
        values: [FilterValue] = [],
        inputKind: FilterInputKind = .options,
        isRequired: Bool = false
    ) {
        self.key = key
        self.name = name
        self.values = values
        self.inputKind = inputKind
        self.isRequired = isRequired
    }

    enum CodingKeys: String, CodingKey {
        case key, name, values, inputKind, isRequired
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.values = (try? container.decodeIfPresent([FilterValue].self, forKey: .values))
            ?? (try? container.decodeIfPresent([FilterValue].self, forKey: .value))
            ?? []
        self.inputKind = try container.decodeIfPresent(FilterInputKind.self, forKey: .inputKind) ?? .options
        self.isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(name, forKey: .name)
        try container.encode(values, forKey: .values)
        if inputKind != .options {
            try container.encode(inputKind, forKey: .inputKind)
        }
        if isRequired {
            try container.encode(isRequired, forKey: .isRequired)
        }
    }
}

/// 筛选值
public struct FilterValue: Codable, Identifiable, Sendable, Equatable {
    public var name: String
    public var value: String

    public var id: String { "\(name)_\(value)" }

    public init(name: String = "", value: String = "") {
        self.name = name
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case value = "v"
    }
}

public enum CategoryFilterSelectionPolicy {
    public static func normalized(
        filters: [Filter],
        existing: [String: String]
    ) -> [String: String] {
        var selection: [String: String] = [:]
        for filter in filters {
            guard !filter.key.isEmpty else { continue }
            if filter.inputKind == .text {
                selection[filter.key] = CategoryFilterTextPolicy.normalized(existing[filter.key] ?? "") ?? ""
                continue
            }
            guard let first = filter.values.first else { continue }
            if let saved = existing[filter.key],
               filter.values.contains(where: { $0.value == saved }) {
                selection[filter.key] = saved
            } else {
                selection[filter.key] = first.value
            }
        }
        return selection
    }

    public static func hasMissingRequiredText(
        filters: [Filter],
        selection: [String: String]
    ) -> Bool {
        filters.contains { filter in
            guard filter.inputKind == .text, filter.isRequired else { return false }
            let value = selection[filter.key] ?? ""
            return CategoryFilterTextPolicy.normalized(value)?.isEmpty != false
        }
    }
}

public enum CategoryFilterTextPolicy {
    public static let maximumLength = 256

    public static func normalized(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength else {
            return nil
        }
        return trimmed
    }
}
