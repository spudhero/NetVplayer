import Foundation

enum VodDescriptionPresentation {
    private static let expandMarker = try! NSRegularExpression(
        pattern: #"(?:\[\s*展开全部\s*\]|【\s*展开全部\s*】|［\s*展开全部\s*］)"#
    )
    private static let disclosureMarker = try! NSRegularExpression(
        pattern: #"(?:\[\s*(?:展开全部|收起部分)\s*\]|【\s*(?:展开全部|收起部分)\s*】|［\s*(?:展开全部|收起部分)\s*］)"#
    )
    private static let separatorRun = try! NSRegularExpression(
        pattern: #"(?:[ \t\r\n]*[;；][ \t\r\n]*){2,}"#
    )
    private static let horizontalWhitespace = try! NSRegularExpression(pattern: #"[ \t]+"#)
    private static let newlineWhitespace = try! NSRegularExpression(pattern: #" *\n *"#)
    private static let blankLineRun = try! NSRegularExpression(pattern: #"\n{3,}"#)

    static func text(from rawValue: String) -> String {
        var value = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")

        if let markerRange = firstRange(of: expandMarker, in: value) {
            value = String(value[markerRange.upperBound...])
        }

        value = replacing(disclosureMarker, in: value, with: "")
        value = replacing(separatorRun, in: value, with: " ")
        value = replacing(horizontalWhitespace, in: value, with: " ")
        value = replacing(newlineWhitespace, in: value, with: "\n")
        value = replacing(blankLineRun, in: value, with: "\n\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstRange(of expression: NSRegularExpression, in value: String) -> Range<String.Index>? {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: searchRange) else { return nil }
        return Range(match.range, in: value)
    }

    private static func replacing(
        _ expression: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        let searchRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: searchRange,
            withTemplate: replacement
        )
    }
}
