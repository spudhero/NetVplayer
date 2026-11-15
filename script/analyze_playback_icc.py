#!/usr/bin/env python3
"""Compare unchanged AV-02 ColorSync reference with the bundled LittleCMS.

Read-only diagnostic; never installs, replaces or edits an ICC profile.
The optional current-display formula investigation requires the captured
matrix plus three signed ParamCurve3 stages and a single-gamma rTRC.
It fails explicitly for other profile shapes; it is not a general ICC engine.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--render-results", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Refusing to overwrite evidence")
    report = json.loads((args.capture / "reference.json").read_text())
    lib = C.CDLL(str(args.library))
    def bind(name, returns, *arguments):
        fn = getattr(lib, name)
        fn.restype, fn.argtypes = returns, arguments
        return fn
    open_profile = bind("cmsOpenProfileFromMem", C.c_void_p, C.c_void_p, C.c_uint32)
    close = bind("cmsCloseProfile", C.c_int, C.c_void_p)
    transform = bind("cmsCreateTransform", C.c_void_p, C.c_void_p, C.c_uint32,
                     C.c_void_p, C.c_uint32, C.c_uint32, C.c_uint32)
    apply = bind("cmsDoTransform", None, C.c_void_p, C.c_void_p, C.c_void_p, C.c_uint32)
    delete = bind("cmsDeleteTransform", None, C.c_void_p)
    version = bind("cmsGetEncodedCMMversion", C.c_int)
    rgb_double = (1 << 22) | (4 << 16) | (3 << 3)
    source_data = (args.capture / "linear-srgb.icc").read_bytes()
    source = open_profile(source_data, len(source_data))
    assert source
    results = []
    renders = json.loads(args.render_results.read_text()) if args.render_results else []
    for profile in report["profiles"]:
        data = (args.capture / (profile["profile"] + ".icc")).read_bytes()
        dest = open_profile(data, len(data))
        assert dest
        tags = []
        count, = struct.unpack_from(">I", data, 128)
        for i in range(count):
            signature, offset, size = struct.unpack_from(">4sII", data, 132+i*12)
            item = {"signature": signature.decode("ascii"), "type": data[offset:offset+4].decode("ascii"), "size": size}
            if item["type"] == "para":
                kind, = struct.unpack_from(">H", data, offset+8)
                n = [1, 3, 4, 5, 7][kind]
                item.update(functionType=kind, parameters=[x/65536 for x in struct.unpack_from(">"+"i"*n, data, offset+12)])
            elif item["type"] == "curv":
                n, = struct.unpack_from(">I", data, offset+8)
                item["curveEntries"] = n
                if n == 1:
                    item["gamma"] = struct.unpack_from(">H", data, offset+12)[0]/256
            tags.append(item)
        runs = []
        for bpc in (False, True):
            handle = transform(source, rgb_double, dest, rgb_double, 1,
                               0x40 | 0x100 | (0x2000 if bpc else 0))
            assert handle
            samples = []
            for sample in profile["samples"]:
                patches = []
                for i, patch in enumerate(sample["patches"]):
                    values = (C.c_double*3)(*patch["linearSRGB"])
                    output = (C.c_double*3)()
                    apply(handle, values, output, 1)
                    rgb8 = [min(1, max(0, v))*255 for v in output]
                    errors = [abs(a-b) for a,b in zip(rgb8, patch["referenceRGB8"])]
                    entry = {"patch": i, "rgb8": rgb8, "maximumErrorLSB": max(errors)}
                    rendered = next((r for r in renders if r["file"] == sample["file"] and r["profile"] == profile["profile"]), None)
                    if rendered:
                        entry["mpvDifferenceLSB"] = max(abs(a-b) for a,b in zip(rgb8, rendered["rgb8"][i]))
                    patches.append(entry)
                samples.append({"file": sample["file"], "maximumErrorLSB": max(x["maximumErrorLSB"] for x in patches), "patches": patches})
            delete(handle)
            runs.append({"blackPointCompensation": bpc, "samples": samples})
        close(dest)
        entry = {"profile": profile["profile"], "sha256": hashlib.sha256(data).hexdigest(), "tags": tags, "runs": runs}
        if profile["profile"] == "current-display":
            fragment = profile["colorSyncParametricFragments"]["best"]
            matrix = next(x["com.apple.cmm.Matrix"] for x in fragment if "com.apple.cmm.Matrix" in x)
            curves = [x["com.apple.cmm.ParamCurve3"] for x in fragment if "com.apple.cmm.ParamCurve3" in x]
            stages = [x for x in fragment if "com.apple.cmm.ParamCurve3" in x]
            if (len(fragment) != 4 or len(curves) != 3 or len(matrix) != 3
                    or any(len(row) != 4 for row in matrix)
                    or any(len(curve) != 7 for curve in curves)
                    or [stage.get("com.apple.cmm.ChannelID") for stage in stages] != [0, 1, 2]
                    or not all(stage.get("com.apple.cmm.FunctionDoesSignedReflection") is True for stage in stages)):
                raise ValueError("Current-display curve reconstruction requires the AV-12 matrix/signed ParamCurve3 shape")
            formula_errors = []
            for sample in profile["samples"]:
                for patch in sample["patches"]:
                    linear = [sum(row[i]*patch["linearSRGB"][i] for i in range(3))+row[3] for row in matrix]
                    for value, curve, expected in zip(linear, curves, patch["referenceRGB8"]):
                        gamma, a, b, c, d, _, _ = curve
                        signed = (a*abs(value)+b)**gamma if abs(value) >= d else c*abs(value)
                        actual = min(1, max(0, signed if value >= 0 else -signed))*255
                        formula_errors.append(abs(actual-expected))
            entry["colorSyncPublicCurve"] = curves
            entry["colorSyncFormulaToOriginalReferenceMaximumLSB"] = max(formula_errors)
            entry["bpcOnOffMaximumDifferenceLSB"] = max(abs(a-b) for s0,s1 in zip(runs[0]["samples"], runs[1]["samples"])
                for p0,p1 in zip(s0["patches"],s1["patches"]) for a,b in zip(p0["rgb8"],p1["rgb8"]))
            gamma = next(t["gamma"] for t in tags if t["signature"] == "rTRC")
            # Neutral ramps isolate TRCs from gamut matrices and clipping.
            entry["neutralGammaFormulaToLCMSMaximumLSB"] = max(abs(max(0,p["linearSRGB"][0])**(1/gamma)*255-l["rgb8"][0])
                for p,l in zip(profile["samples"][0]["patches"][:16], runs[0]["samples"][0]["patches"][:16]))
        results.append(entry)
    close(source)
    result = {"schema": 1, "lcmsVersion": version(), "librarySHA256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
              "captureReferenceSHA256": hashlib.sha256((args.capture / "reference.json").read_bytes()).hexdigest(),
              "linearSourceICCSHA256": hashlib.sha256(source_data).hexdigest(),
              "renderResultsSHA256": hashlib.sha256(args.render_results.read_bytes()).hexdigest() if args.render_results else None,
              "analyzerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "reference": report["reference"], "systemSettingsChanged": False, "profiles": results}
    with args.output.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
    for p in results:
        print(p["profile"], [(r["blackPointCompensation"], round(max(s["maximumErrorLSB"] for s in r["samples"]), 6)) for r in p["runs"]])


if __name__ == "__main__":
    main()
