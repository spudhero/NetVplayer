#!/usr/bin/env python3
"""Read CoreAudio stream formats without opening audio or changing device state."""
import argparse
import ctypes as C
import json
from pathlib import Path


def fourcc(text):
    return int.from_bytes(text.encode("ascii"), "big")


def printable(value):
    return value.to_bytes(4, "big").decode("ascii", errors="replace")


class Address(C.Structure):
    _fields_ = [("selector", C.c_uint32), ("scope", C.c_uint32), ("element", C.c_uint32)]


class ASBD(C.Structure):
    _fields_ = [("rate", C.c_double), ("format", C.c_uint32), ("flags", C.c_uint32),
                ("bytesPerPacket", C.c_uint32), ("framesPerPacket", C.c_uint32),
                ("bytesPerFrame", C.c_uint32), ("channels", C.c_uint32),
                ("bits", C.c_uint32), ("reserved", C.c_uint32)]


class RangedFormat(C.Structure):
    _fields_ = [("format", ASBD), ("minimumRate", C.c_double), ("maximumRate", C.c_double)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("Refusing to replace prior evidence")
    core = C.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    core.AudioObjectGetPropertyDataSize.argtypes = [C.c_uint32, C.POINTER(Address), C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32)]
    core.AudioObjectGetPropertyData.argtypes = [C.c_uint32, C.POINTER(Address), C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32), C.c_void_p]

    def read(object_id, selector, item_type, scope="glob"):
        address = Address(fourcc(selector), fourcc(scope), 0)
        size = C.c_uint32()
        status = core.AudioObjectGetPropertyDataSize(object_id, C.byref(address), 0, None, C.byref(size))
        if status or size.value > 65536 or size.value % C.sizeof(item_type):
            return None
        result = (item_type * (size.value // C.sizeof(item_type)))()
        status = core.AudioObjectGetPropertyData(object_id, C.byref(address), 0, None, C.byref(size), result)
        return list(result) if status == 0 else None

    def format_info(asbd):
        return {"formatID": printable(asbd.format), "sampleRate": asbd.rate,
                "channelCount": asbd.channels, "bitsPerChannel": asbd.bits}

    report = {"schema": 1, "readOnly": True, "devices": [],
              "limits": "Advertised/current formats only; no receiver, payload, physical speaker or Atmos validation."}
    devices = read(1, "dev#", C.c_uint32)
    if devices is None or len(devices) > 64:
        raise SystemExit("Device enumeration unavailable or out of bounds")
    for device in devices:
        streams = read(device, "stm#", C.c_uint32, "outp")
        if not streams:
            continue
        if len(streams) > 64:
            raise SystemExit("Output stream count out of bounds")
        transport = read(device, "tran", C.c_uint32)
        record = {"transport": printable(transport[0]) if transport else None, "streams": []}
        for stream in streams:
            physical = read(stream, "pft ", ASBD)
            virtual = read(stream, "sfmt", ASBD)
            available = read(stream, "pfta", RangedFormat)
            record["streams"].append({"physical": [format_info(f) for f in physical] if physical else None,
                                       "virtual": [format_info(f) for f in virtual] if virtual else None,
                                       "availablePhysical": [{**format_info(f.format), "rateRange": [f.minimumRate, f.maximumRate]}
                                                             for f in available] if available else None})
        report["devices"].append(record)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Read {len(report['devices'])} output devices; names and UIDs omitted.")


if __name__ == "__main__":
    main()
