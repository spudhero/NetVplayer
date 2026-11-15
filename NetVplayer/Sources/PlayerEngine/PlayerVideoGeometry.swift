import Foundation

/// The display geometry reported by mpv, including anamorphic pixels and rotation.
public enum PlayerVideoGeometry {
    public static func displayAspectRatio(json: String?) -> Double? {
        guard let data = json?.data(using: .utf8),
              let params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func positive(_ key: String) -> Double? {
            guard let value = (params[key] as? NSNumber)?.doubleValue,
                  value.isFinite, value > 0 else { return nil }
            return value
        }
        let dimensions = positive("dw").flatMap { width in positive("dh").map { width / $0 } }
            ?? positive("w").flatMap { width in positive("h").map { width * (positive("par") ?? 1) / $0 } }
        guard var ratio = positive("aspect") ?? dimensions else { return nil }
        let rotation = ((params["rotate"] as? NSNumber)?.intValue ?? 0) % 360
        if abs(rotation) == 90 || abs(rotation) == 270 { ratio = 1 / ratio }
        return ratio.isFinite && (0.1...10).contains(ratio) ? ratio : nil
    }
}
