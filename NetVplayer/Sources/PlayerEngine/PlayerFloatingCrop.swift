import Foundation
import MPVShim

struct PlayerBlackBarSample: Sendable, Equatable {
    let width, height, left, top, right, bottom: Int
    init(_ sample: NVMPVBlackBarSample) {
        width = Int(sample.width); height = Int(sample.height)
        left = Int(sample.left); top = Int(sample.top)
        right = Int(sample.right); bottom = Int(sample.bottom)
    }
    var hasBars: Bool { left + top + right + bottom > 0 }
}

/// Owns only a temporary VO crop. It does not add filters, reload the decoder or read the URL again.
@MainActor
final class PlayerFloatingCrop {
    var enabled = false
    private(set) var displayAspectRatio: Double?
    private var owner: UUID?
    private var pending: (id: UInt64, owner: UUID)?
    private var pendingApplication: (id: UInt64, owner: UUID, crop: String?, aspect: Double?)?
    private var nextID: UInt64 = 0xC800_0000_0000_0000
    private var candidate: PlayerBlackBarSample?
    private var stableSamples = 0
    private var originalCrop: String?
    private var appliedCrop: String?
    private var lastSampleTime: TimeInterval = 0

    static func ownsReply(_ id: UInt64) -> Bool { id >> 56 == 0xC8 }

    func receiveApplication(id: UInt64, error: Int32, owner: UUID) -> Bool {
        guard let application = pendingApplication, application.id == id else { return false }
        pendingApplication = nil
        guard enabled, application.owner == owner, self.owner == owner, error >= 0 else { return false }
        appliedCrop = application.crop
        displayAspectRatio = application.aspect
        return true
    }

    func reset(context: OpaquePointer?) {
        if let context, let originalCrop, appliedCrop != nil || pendingApplication?.crop != nil {
            _ = nv_mpv_set_property_string_async(context, nextID, "video-crop", originalCrop)
            nextID &+= 1
        }
        owner = nil; pending = nil; pendingApplication = nil; candidate = nil; stableSamples = 0
        originalCrop = nil; appliedCrop = nil; displayAspectRatio = nil; lastSampleTime = 0
    }

    func sample(context: OpaquePointer, owner: UUID, eligible: Bool) {
        if self.owner != owner { reset(context: context); self.owner = owner }
        guard enabled, eligible, pending == nil, pendingApplication == nil,
              ProcessInfo.processInfo.systemUptime - lastSampleTime >= 1.5 else { return }
        if originalCrop == nil {
            guard let value = nv_mpv_copy_property_string(context, "video-crop") else { return }
            originalCrop = String(cString: value)
            nv_mpv_free_string(value)
        }
        // Respect an existing explicit crop rather than taking over its ownership.
        guard originalCrop?.isEmpty == true else { return }
        nextID &+= 1
        if nv_mpv_command3_async(context, nextID, "screenshot-raw", "video", "bgr0") >= 0 {
            pending = (nextID, owner)
            lastSampleTime = ProcessInfo.processInfo.systemUptime
        }
    }

    func receive(id: UInt64, sample: PlayerBlackBarSample?, context: OpaquePointer,
                 owner: UUID, geometryJSON: String?) -> Bool {
        guard let pending, pending.id == id else { return false }
        self.pending = nil
        guard enabled, pending.owner == owner, self.owner == owner, let sample,
              let data = geometryJSON?.data(using: .utf8),
              let params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let width = (params["w"] as? NSNumber)?.intValue,
              let height = (params["h"] as? NSNumber)?.intValue,
              let baseAspect = PlayerVideoGeometry.displayAspectRatio(json: geometryJSON) else {
            candidate = nil; stableSamples = 0
            return false
        }
        if let previous = candidate, previous.width == sample.width, previous.height == sample.height,
           abs(previous.top - sample.top) <= 2, abs(previous.bottom - sample.bottom) <= 2,
           abs(previous.left - sample.left) <= 2, abs(previous.right - sample.right) <= 2 { stableSamples += 1 }
        else { candidate = sample; stableSamples = 1 }
        guard stableSamples >= (sample.hasBars ? 3 : 2) else { return false }
        let left = Int(Double(sample.left) / Double(sample.width) * Double(width)) / 2 * 2
        let right = Int(Double(sample.right) / Double(sample.width) * Double(width)) / 2 * 2
        let top = Int(Double(sample.top) / Double(sample.height) * Double(height)) / 2 * 2
        let bottom = Int(Double(sample.bottom) / Double(sample.height) * Double(height)) / 2 * 2
        let cropWidth = width - left - right, cropHeight = height - top - bottom
        guard width > 0, height > 0, cropWidth > width / 2, cropHeight > height / 2 else { return false }
        let crop = sample.hasBars ? "\(cropWidth)x\(cropHeight)+\(left)+\(top)" : (originalCrop ?? "")
        guard crop != (appliedCrop ?? originalCrop) else { return false }
        nextID &+= 1
        guard nv_mpv_set_property_string_async(context, nextID, "video-crop", crop) >= 0 else { return false }
        let rotation = abs((params["rotate"] as? NSNumber)?.intValue ?? 0) % 180
        let factor = Double(cropWidth) / Double(width) * Double(height) / Double(cropHeight)
        pendingApplication = (nextID, owner, sample.hasBars ? crop : nil,
            sample.hasBars ? baseAspect * (rotation == 90 ? 1 / factor : factor) : nil)
        return false
    }
}
