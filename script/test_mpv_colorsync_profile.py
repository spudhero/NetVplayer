#!/usr/bin/env python3
"""Compare private render profiles with independent native ColorSync references."""
import ctypes as C
import json
import os
import platform
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


REFERENCE = r'''
import AppKit
import ColorSync
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let linear = NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!
try linear.iccProfileData!.write(to: folder.appendingPathComponent("linear.icc"))
var spaces: [(String, NSColorSpace)] = [("sRGB", .sRGB), ("P3", .displayP3)]
for (name, gammas) in [("gamma10", [1.0, 1.0, 1.0]), ("gamma18", [1.8, 1.8, 1.8]),
                       ("gamma22", [2.2, 2.2, 2.2]), ("gamma26", [2.6, 2.6, 2.6]),
                       ("per-channel", [1.0, 2.2, 2.6])] {
    let base = ColorSyncProfileCreate(NSColorSpace.displayP3.iccProfileData! as CFData, nil)!.takeRetainedValue()
    let profile = ColorSyncProfileCreateMutableCopy(base)!.takeRetainedValue()
    for i in 0..<3 {
        var tag = Data("curv".utf8) + Data(repeating: 0, count: 4)
        var count = UInt32(1).bigEndian
        withUnsafeBytes(of: &count) { tag.append(contentsOf: $0) }
        var gamma = UInt16((gammas[i] * 256).rounded()).bigEndian
        withUnsafeBytes(of: &gamma) { tag.append(contentsOf: $0) }
        if name == "gamma22" { tag.append(contentsOf: [0, 0]) }
        ColorSyncProfileSetTag(profile, ["rTRC", "gTRC", "bTRC"][i] as CFString, tag as CFData)
    }
    let data = ColorSyncProfileCopyData(profile, nil)!.takeRetainedValue() as Data
    spaces.append((name, NSColorSpace(iccProfileData: data)!))
}
let levels = [0.0, 0.000001, 0.00001, 0.0001, 0.0004, 0.0012, 0.003, 0.0062, 0.01, 0.1, 0.5, 1.0]
var inputs = levels.map { [$0, $0, $0] }
for r in [0.0, 0.0012, 0.1, 1.0] {
    for g in [0.0, 0.003, 0.2, 1.0] {
        for b in [0.0, 0.0062, 0.5, 1.0] { inputs.append([r,g,b]) }
    }
}
var results: [[String: Any]] = []
for (name, space) in spaces {
    try space.iccProfileData!.write(to: folder.appendingPathComponent(name + ".icc"))
    let samples: [[String: Any]] = inputs.map { input in
        let components = (input + [1]).map { CGFloat($0) }
        let color = NSColor(colorSpace: linear, components: components, count: 4).usingColorSpace(space)!
        return ["input": input, "expected": [color.redComponent, color.greenComponent, color.blueComponent].map { min(1, max(0, Double($0))) }]
    }
    results.append(["name": name, "samples": samples])
}
try JSONSerialization.data(withJSONObject: results).write(to: folder.appendingPathComponent("reference.json"))
'''


class ColorSyncRenderProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="netvplayer-colorsync-")
        cls.folder = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        helper = cls.folder / "profile.dylib"
        subprocess.run(["cc", "-dynamiclib", "-mmacosx-version-min=14.0",
                        str(root / "NetVplayer/Sources/MPVShim/NVMPVColorProfile.c"),
                        "-framework", "ColorSync", "-framework", "CoreFoundation",
                        "-Wall", "-Wextra", "-Werror", "-o", str(helper)], check=True, capture_output=True)
        source = cls.folder / "reference.swift"
        source.write_text(REFERENCE)
        executable = cls.folder / "reference"
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-module-cache-path", str(cls.folder / "modules"),
                        "-target", platform.machine() + "-apple-macosx14.0", str(source), "-o", str(executable)],
                       check=True, capture_output=True)
        subprocess.run([str(executable), str(cls.folder)], check=True, capture_output=True)
        cls.helper = C.CDLL(str(helper))
        cls.helper.nv_mpv_copy_render_profile.argtypes = [C.c_void_p, C.c_size_t]
        cls.helper.nv_mpv_copy_render_profile.restype = C.c_void_p
        cls.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        cls.cf.CFDataGetLength.argtypes = [C.c_void_p]
        cls.cf.CFDataGetLength.restype = C.c_long
        cls.cf.CFDataGetBytePtr.argtypes = [C.c_void_p]
        cls.cf.CFDataGetBytePtr.restype = C.c_void_p
        cls.cf.CFRelease.argtypes = [C.c_void_p]
        cls.lcms = C.CDLL(os.environ.get("NETVPLAYER_LCMS_PATH",
            "/Applications/NetVplayer.app/Contents/Frameworks/liblcms2.2.dylib"))
        for name, result, args in [
            ("cmsOpenProfileFromMem", C.c_void_p, [C.c_void_p, C.c_uint32]),
            ("cmsCreateTransform", C.c_void_p, [C.c_void_p, C.c_uint32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_uint32]),
            ("cmsDoTransform", None, [C.c_void_p, C.c_void_p, C.c_void_p, C.c_uint32]),
            ("cmsDeleteTransform", None, [C.c_void_p]), ("cmsCloseProfile", C.c_int, [C.c_void_p])]:
            fn = getattr(cls.lcms, name)
            fn.restype, fn.argtypes = result, args

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def render_profile(self, data):
        result = self.helper.nv_mpv_copy_render_profile(data, len(data))
        self.assertTrue(result)
        try:
            return C.string_at(self.cf.CFDataGetBytePtr(result), self.cf.CFDataGetLength(result))
        finally:
            self.cf.CFRelease(result)

    def test_gamma_profiles_match_native_reference_without_monitor_or_fixed_gamma(self):
        original = (self.folder / "linear.icc").read_bytes()
        source = self.lcms.cmsOpenProfileFromMem(original, len(original))
        self.assertTrue(source)
        rgb_double = (1 << 22) | (4 << 16) | (3 << 3)
        try:
            for profile in json.loads((self.folder / "reference.json").read_text()):
                if profile["name"] in ("sRGB", "P3"):
                    continue
                with self.subTest(profile=profile["name"]):
                    data = (self.folder / (profile["name"] + ".icc")).read_bytes()
                    converted = self.render_profile(data)
                    if profile["name"] != "gamma10":
                        self.assertNotEqual(data, converted)
                    self.assertEqual(struct.unpack_from(">I", converted)[0], len(converted))
                    destination = self.lcms.cmsOpenProfileFromMem(converted, len(converted))
                    self.assertTrue(destination)
                    transform = self.lcms.cmsCreateTransform(source, rgb_double, destination, rgb_double, 1, 0x100)
                    self.assertTrue(transform)
                    try:
                        errors = []
                        for sample in profile["samples"]:
                            input_rgb, output_rgb = (C.c_double * 3)(*sample["input"]), (C.c_double * 3)()
                            self.lcms.cmsDoTransform(transform, input_rgb, output_rgb, 1)
                            errors.extend(abs(max(0, min(1, a)) - b) * 255
                                          for a, b in zip(output_rgb, sample["expected"]))
                        self.assertLessEqual(max(errors), 0.5, profile["name"])
                    finally:
                        self.lcms.cmsDeleteTransform(transform)
                        self.lcms.cmsCloseProfile(destination)
        finally:
            self.lcms.cmsCloseProfile(source)

    def test_other_profiles_and_bounded_legacy_blobs_pass_through_unchanged(self):
        for name in ("sRGB", "P3"):
            data = (self.folder / (name + ".icc")).read_bytes()
            self.assertEqual(self.render_profile(data), data)
        self.assertEqual(self.render_profile(b"bounded-display-profile"), b"bounded-display-profile")
        data = bytearray((self.folder / "gamma22.icc").read_bytes())
        struct.pack_into(">I", data, 128, 0xFFFFFFFF)
        self.assertEqual(self.render_profile(bytes(data)), bytes(data))
        self.assertFalse(self.helper.nv_mpv_copy_render_profile(None, 1))
        self.assertFalse(self.helper.nv_mpv_copy_render_profile(b"x", 0))
        self.assertFalse(self.helper.nv_mpv_copy_render_profile(b"x", 4 * 1024 * 1024 + 1))


if __name__ == "__main__":
    unittest.main()
