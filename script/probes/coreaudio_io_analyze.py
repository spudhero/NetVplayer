#!/usr/bin/env python3
"""Inspect test-host IEC 61937 bytes and the independent IOProc callback trace.

Usage: python3 script/probes/coreaudio_io_analyze.py PREFIX.raw \
           --callbacks PREFIX.callbacks.csv [--extract-eac3 NEW_OUTPUT.eac3]
This does not access CoreAudio or play audio. Zero padding within each EAC3
24576-byte burst is expected; spacing changes and a full burst of zeros are
reported separately. A valid byte stream does not establish receiver lock.
"""

import argparse
import collections
import csv
import json
import pathlib
import re
import struct


BURST_BYTES = 24576
HOST_VALID = 2
SAMPLE_VALID = 1


def analyze(raw, callback_path=None):
    offsets = []
    payloads = []
    malformed = []
    padding_nonzero = []
    for match in re.finditer(b"\x72\xf8\x1f\x4e", raw):
        offset = match.start()
        if offset % 2 or offset + 8 > len(raw):
            continue
        kind, length = struct.unpack_from("<HH", raw, offset + 4)
        if kind & 0x1F != 0x15:
            continue
        if not 0 < length <= BURST_BYTES - 8:
            malformed.append({"offset": offset, "kind": kind, "length": length})
            continue
        offsets.append(offset)
        padded_length = (length + 1) // 2 * 2
        if offset + 8 + padded_length > len(raw):
            continue  # The final captured burst may be truncated.
        payload = raw[offset + 8:offset + 8 + padded_length]
        native = bytearray(len(payload))
        native[0::2], native[1::2] = payload[1::2], payload[0::2]
        native = bytes(native[:length])
        if not native.startswith(b"\x0b\x77"):
            malformed.append({"offset": offset, "reason": "payload lacks EAC3 sync after 16-bit byte swap"})
        else:
            payloads.append(native)
        if offset + BURST_BYTES <= len(raw) and any(raw[offset + 8 + padded_length:offset + BURST_BYTES]):
            padding_nonzero.append(offset)
    spacing = collections.Counter(b - a for a, b in zip(offsets, offsets[1:]))
    anomalies = [
        {"previousOffset": a, "nextOffset": b, "spacingBytes": b - a}
        for a, b in zip(offsets, offsets[1:]) if b - a != BURST_BYTES
    ]
    long_zero = [{"offset": m.start(), "bytes": m.end() - m.start()}
                 for m in re.finditer(b"\x00+", raw) if m.end() - m.start() >= BURST_BYTES]
    result = {
        "scope": "IOProc-supplied bytes only; receiver lock and HAL wire delivery unverified",
        "rawBytes": len(raw), "eac3Preambles": len(offsets),
        "completePayloads": len(payloads), "firstPreambleOffset": offsets[0] if offsets else None,
        "lastPreambleOffset": offsets[-1] if offsets else None,
        "burstSpacingBytes": dict(sorted(spacing.items())),
        "spacingAnomalyCount": len(anomalies), "spacingAnomaliesFirst20": anomalies[:20],
        "malformedPayloadCount": len(malformed), "malformedPayloadsFirst20": malformed[:20],
        "nonzeroBurstPaddingCount": len(padding_nonzero), "nonzeroBurstPaddingOffsetsFirst20": padding_nonzero[:20],
        "fullBurstOrLongerZeroRuns": long_zero[:20], "longZeroRunCount": len(long_zero),
        "bigEndianPreambleCount": raw.count(b"\xf8\x72\x4e\x1f"),
    }
    if callback_path:
        by_slot = collections.defaultdict(list)
        with pathlib.Path(callback_path).open(newline="") as f:
            for e in csv.DictReader(f):
                by_slot[int(e["slot"])].append(e)
        summaries = []
        for slot, events in sorted(by_slot.items()):
            host_indices = [i for i, e in enumerate(events) if int(e["output_flags"]) & HOST_VALID]
            host = [events[i] for i in host_indices]
            sample = [e for e in host if int(e["output_flags"]) & SAMPLE_VALID]
            elapsed = ((float(host[-1]["output_host_ns"]) - float(host[0]["output_host_ns"])) / 1e9
                       if len(host) > 1 else 0)
            # Each timestamp describes the start of its callback's output;
            # exclude the final buffer when measuring that exact interval.
            interval_bytes = (sum(int(e["bytes"]) for e in events[host_indices[0]:host_indices[-1]])
                              if len(host_indices) > 1 else 0)
            steps = collections.Counter(round(float(b["output_sample_time"]) - float(a["output_sample_time"]), 6)
                                        for a, b in zip(sample, sample[1:]))
            sample_elapsed = ((float(sample[-1]["output_host_ns"]) - float(sample[0]["output_host_ns"])) / 1e9
                              if len(sample) > 1 else 0)
            frames = float(sample[-1]["output_sample_time"]) - float(sample[0]["output_sample_time"]) if sample else 0
            summaries.append({
                "slot": slot, "callbacks": len(events), "outputHostValidCallbacks": len(host),
                "outputSampleAndHostValidCallbacks": len(sample),
                "outputHostElapsedSeconds": elapsed,
                "bytesPerOutputHostSecond": interval_bytes / elapsed if elapsed else None,
                "expectedEAC3CarrierBytesPerSecond": 192000 * 2 * 2,
                "sampleFramesPerOutputHostSecond": frames / sample_elapsed if sample_elapsed else None,
                "outputSampleStepHistogram": dict(sorted(steps.items())),
                "byteSizeHistogram": dict(sorted(collections.Counter(int(e["bytes"]) for e in events).items())),
                "channelsHistogram": dict(sorted(collections.Counter(int(e["channels"]) for e in events).items())),
                "maxCallbackGapMs": max((float(e["interval_ns"]) / 1e6 for e in events), default=0),
                "maxProducerMs": max((float(e["producer_ns"]) / 1e6 for e in events), default=0),
                "maxWrapperMs": max((float(e["wrapper_ns"]) / 1e6 for e in events), default=0),
                "totalCopiedBytes": sum(int(e["copied"]) for e in events),
            })
        result["ioProcs"] = summaries
    return result, payloads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=pathlib.Path)
    parser.add_argument("--callbacks", type=pathlib.Path)
    parser.add_argument("--extract-eac3", type=pathlib.Path)
    args = parser.parse_args()
    result, payloads = analyze(args.raw.read_bytes(), args.callbacks)
    if args.extract_eac3:
        with args.extract_eac3.open("xb") as f:
            for payload in payloads:
                f.write(payload)
        result["extractedEAC3Bytes"] = sum(map(len, payloads))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
