// Read-only API/device inventory for playback queue item 12. No playback,
// device setters, JVM startup, USB claims, model downloads, or GPU encoding.
import Foundation
import CoreAudio
import AudioToolbox
import Metal
import MetalFX

func fourCC(_ value: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((value >> $0) & 255) }, encoding: .ascii)
        ?? String(format: "0x%08x", value)
}

func values<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
               initial: T) -> (OSStatus, [T]) {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let info = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard info == noErr else { return (info, []) }
    guard size % UInt32(MemoryLayout<T>.stride) == 0, size <= 1_048_576 else { return (-1, []) }
    var result = Array(repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
    guard !result.isEmpty else { return (noErr, []) }
    let status = result.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
    }
    return (status, status == noErr ? result : [])
}

func asbd(_ format: AudioStreamBasicDescription) -> [String: Any] {
    ["formatID": fourCC(format.mFormatID), "sampleRate": format.mSampleRate,
     "channels": format.mChannelsPerFrame, "bitsPerChannel": format.mBitsPerChannel,
     "bytesPerFrame": format.mBytesPerFrame, "flags": format.mFormatFlags]
}

let system = AudioObjectID(kAudioObjectSystemObject)
let (devicesStatus, deviceIDs) = values(system, kAudioHardwarePropertyDevices, initial: AudioObjectID(0))
let (_, defaults) = values(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
var outputs: [[String: Any]] = []
for device in deviceIDs {
    let (streamsStatus, streams) = values(device, kAudioDevicePropertyStreams,
                                         scope: kAudioObjectPropertyScopeOutput, initial: AudioStreamID(0))
    guard streamsStatus == noErr, !streams.isEmpty else { continue }
    let (_, transport) = values(device, kAudioDevicePropertyTransportType, initial: UInt32(0))
    var formats: [[String: Any]] = []
    for stream in streams.prefix(8) {
        let (currentStatus, current) = values(stream, kAudioStreamPropertyPhysicalFormat,
                                             initial: AudioStreamBasicDescription())
        let (availableStatus, available) = values(stream, kAudioStreamPropertyAvailablePhysicalFormats,
                                                 initial: AudioStreamRangedDescription())
        formats.append([
            "currentStatus": currentStatus, "current": current.map(asbd),
            "availableStatus": availableStatus,
            "advertisedPhysicalFormats": available.map {
                ["format": asbd($0.mFormat), "minimumRate": $0.mSampleRateRange.mMinimum,
                 "maximumRate": $0.mSampleRateRange.mMaximum] as [String: Any]
            }
        ])
    }
    outputs.append(["ordinal": outputs.count + 1, "isDefault": defaults.first == device,
                    "transport": transport.first.map(fourCC) ?? "unknown", "streams": formats])
}

var decodeSize: UInt32 = 0
let decodeInfoStatus = AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &decodeSize)
var decodeIDs = [AudioFormatID]()
var decodeStatus = decodeInfoStatus
if decodeInfoStatus == noErr, decodeSize <= 1_048_576,
   decodeSize % UInt32(MemoryLayout<AudioFormatID>.stride) == 0 {
    decodeIDs = Array(repeating: 0, count: Int(decodeSize) / MemoryLayout<AudioFormatID>.stride)
    decodeStatus = decodeIDs.withUnsafeMutableBytes {
        AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &decodeSize, $0.baseAddress!)
    }
}

var gpu: [String: Any] = ["deviceFound": false]
if let device = MTLCreateSystemDefaultDevice() {
    gpu = ["deviceFound": true, "name": device.name,
           "spatialScalerSupported": MTLFXSpatialScalerDescriptor.supportsDevice(device),
           "temporalScalerSupported": MTLFXTemporalScalerDescriptor.supportsDevice(device)]
    if #available(macOS 26.0, *) {
        gpu["frameInterpolatorSupported"] = MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
    }
}

let result: [String: Any] = [
    "schemaVersion": 1, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
    "audioDevicesStatus": devicesStatus, "outputs": outputs,
    "decodeFormatQueryStatus": decodeStatus,
    "decodeFormatIDs": decodeStatus == noErr ? decodeIDs.map(fourCC).sorted() : [],
    "metalFX": gpu,
    "scope": "API availability / advertised and current HAL formats only; no effect, payload, receiver, or hardware acceptance",
    "mutations": [String]()
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
