#!/usr/bin/env python3
"""AV-05 offline evaluator. Missing/short/interrupted observations cannot pass."""
import argparse
import json
import math
from pathlib import Path
import statistics


def finite(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def percentile(values, fraction):
    return sorted(values)[min(len(values) - 1, math.ceil(len(values) * fraction) - 1)] if values else None


def summarize(records, case):
    rows = [r for r in records if r.get("phase") == "measurement"]
    issues = []
    report = {"id": case["id"], "purpose": case["purpose"], "samples": len(rows),
              "collectionCompleted": case.get("completed", False),
              "targets": {"warmupSeconds": 60, "continuousSeconds": 1800,
                          "maximumDropFraction": .001, "maximumAbsoluteAVSyncSeconds": .080},
              "issues": issues, "sustainedAcceptance": "not-evaluated"}
    if len(rows) < 2:
        issues.append("Insufficient samples")
        return report
    first, last = rows[0], rows[-1]
    readings = [r["reading"] for r in rows]
    diagnostics = [r["diagnostics"] for r in readings]
    uptime = [r.get("uptime") for r in readings]
    positions = [r.get("position") for r in readings]
    if not all(finite(x) for x in uptime + positions):
        issues.append("Missing or invalid sample time/position")
        return report
    wall = uptime[-1] - uptime[0]
    media = positions[-1] - positions[0]
    fps_values = [d.get("video", {}).get("framesPerSecond") for d in diagnostics]
    fps = fps_values[0]
    if not finite(fps) or fps <= 0 or not all(finite(x) and abs(x - fps) < .01 for x in fps_values):
        issues.append("Missing or changing frame rate")
        return report
    gaps = [b - a for a, b in zip(uptime, uptime[1:])]
    if any(g <= 0 or g > 2.5 for g in gaps):
        issues.append("Non-monotonic or >2.5 second diagnostic sampling gap")
    if any(b <= a or abs((b - a) - dt) > max(.35, dt * .1)
           for a, b, dt in zip(positions, positions[1:], gaps)):
        issues.append("Media timeline stalled, sought, looped or advanced outside 1x tolerance")
    if any(r.get("paused") is not False or r.get("speed") != 1 for r in readings):
        issues.append("Paused, non-1x, or missing playback state")
    cache_pauses = sum(r.get("pausedForCache") is True for r in readings)
    if any(r.get("pausedForCache") is not False for r in readings):
        issues.append("Supply pause observed or cache-pause property unavailable")
    owners = {d.get("mediaID") for d in diagnostics}
    hardware = {d.get("video", {}).get("hardwareDecoder") for d in diagnostics}
    if len(owners) != 1 or None in owners:
        issues.append("Missing or replaced media identity")
    if len(hardware) != 1 or None in hardware:
        issues.append("Missing or changing decoder path")
    first_frame = first["render"].get("firstFrameUptime")
    load = first["render"].get("loadUptime")
    warmup = uptime[0] - first_frame if finite(first_frame) else None
    frames = media * fps if media > 0 else 0
    fresh = [r["render"].get("freshFrames") for r in rows]
    if not all(finite(v) and v >= 0 and v == int(v) for v in fresh) or any(b < a for a, b in zip(fresh, fresh[1:])):
        issues.append("Missing/reset fresh presentation counter")
    else:
        delivered = fresh[-1] - fresh[0]
        report["freshFrameSubmissions"] = delivered
        report["expectedFramesFromMediaTime"] = frames
        report["estimatedUnsubmittedFraction"] = max(0, 1 - delivered / frames) if frames else None
        report["presentationCountNote"] = "Independent host submission cross-check; sample boundaries and media-derived frame count can differ slightly. Does not measure panel scanout."
        if delivered <= 0:
            issues.append("No fresh frame submissions during measurement")
    report.update(wallSeconds=wall, mediaSeconds=media, warmupSeconds=warmup,
                  maximumSamplingGapSeconds=max(gaps), supplyPausedSampleCount=cache_pauses,
                  hardwareDecoders=sorted(x for x in hardware if x), fps=fps,
                  firstSubmittedFrameMilliseconds=(first_frame - load) * 1000 if finite(first_frame) and finite(load) else None,
                  dimensions=[diagnostics[-1].get("video", {}).get("width"), diagnostics[-1].get("video", {}).get("height")],
                  renderPixels=[last["render"].get("width"), last["render"].get("height")])
    for field in ["cachePauseCount", "cachePauseSeconds", "pauseRequests", "seekRequests", "speedChanges"]:
        values = [r["render"].get(field) for r in rows]
        if not all(finite(v) for v in values) or any(b < a for a, b in zip(values, values[1:])):
            issues.append(f"Missing/reset {field} event counter")
            report[field + "Delta"] = None
        else:
            report[field + "Delta"] = values[-1] - values[0]
            if values[-1] != values[0]:
                issues.append(f"Continuous segment interrupted: {field}")
    drops = []
    for key, label in [("decoderDroppedFrames", "decoder"), ("rendererDroppedFrames", "renderer")]:
        values = [d.get(key) for d in diagnostics]
        valid = all(finite(v) and v >= 0 and v == int(v) for v in values)
        if not valid or any(b < a for a, b in zip(values, values[1:])):
            issues.append(f"Missing/reset {label} drop counter")
            report[label + "DropFraction"] = None
        else:
            count = values[-1] - values[0]
            report[label + "DroppedFrames"] = count
            report[label + "DropFraction"] = count / frames if frames else None
            drops.append(count)
    report["conservativeCombinedDropFraction"] = sum(drops) / frames if len(drops) == 2 and frames else None
    sync = [d.get("audioVideoOffsetSeconds") for d in diagnostics]
    if all(finite(v) for v in sync):
        report["maximumAbsoluteAVSyncSeconds"] = max(map(abs, sync))
        report["p95AbsoluteAVSyncSeconds"] = percentile(list(map(abs, sync)), .95)
    else:
        report["maximumAbsoluteAVSyncSeconds"] = None
        issues.append("Audio/video synchronization property unavailable")
    cpu = []
    for a, b in zip(rows, rows[1:]):
        ra, rb = a["resources"], b["resources"]
        dt = rb["uptime"] - ra["uptime"]
        dc = rb["cpuSeconds"] - ra["cpuSeconds"]
        if dt > 0 and dc >= 0:
            cpu.append(100 * dc / dt)
    report["cpuPercentOneCore100"] = {"mean": statistics.mean(cpu) if cpu else None, "p95": percentile(cpu, .95)}
    resources = [r["resources"] for r in rows]
    for field in ["residentBytes", "footprintBytes"]:
        values = [r.get(field) for r in resources]
        if not all(finite(v) and v > 0 for v in values):
            report[field] = None
            issues.append(f"Missing {field}")
            continue
        bins = {}
        for t, v in zip(uptime, values):
            bins.setdefault(int((t - uptime[0]) / 60), []).append(v)
        medians = [statistics.median(v) for _, v in sorted(bins.items()) if len(v) >= 20]
        early = statistics.median([v for t, v in zip(uptime, values) if t <= uptime[0] + 300])
        late = statistics.median([v for t, v in zip(uptime, values) if t >= uptime[-1] - 300])
        # A concern flag, not a proof that bounded growth can never become a leak.
        growing = len(medians) >= 3 and medians[-3] < medians[-2] < medians[-1]
        concern = late - early > max(64 * 1024 * 1024, early * .1) and growing
        report[field] = {"firstFiveMinuteMedian": early, "lastFiveMinuteMedian": late,
                         "difference": late - early, "minimum": min(values), "maximum": max(values),
                         "minuteMedians": medians, "growthConcern": concern}
    gpu = [r.get("gpuPassAverageMilliseconds") for r in readings]
    available_gpu = [v for v in gpu if finite(v)]
    report["gpuPassAverageMilliseconds"] = {"availableSamples": len(available_gpu), "totalSamples": len(gpu),
        "median": statistics.median(available_gpu) if available_gpu else None, "p95": percentile(available_gpu, .95)}
    energy = [r.get("billedEnergyCounter") for r in resources]
    report["billedEnergyCounterDeltaUncalibrated"] = energy[-1] - energy[0] if all(finite(v) for v in energy) else None
    energy_rates = [(b - a) / dt for a, b, dt in zip(energy, energy[1:], gaps)
                    if finite(a) and finite(b) and b >= a and dt > 0]
    report["billedEnergyRawUnitsPerSecond"] = {"median": statistics.median(energy_rates) if energy_rates else None,
        "p95": percentile(energy_rates, .95), "units": "uncalibrated Darwin accounting units, not watts"}
    system_gpu = [r.get("systemGPUDeviceUtilizationPercent") for r in resources]
    available = [v for v in system_gpu if finite(v)]
    report["systemGPUDeviceUtilizationPercent"] = {"availableSamples": len(available),
        "median": statistics.median(available) if available else None, "p95": percentile(available, .95),
        "scope": "whole-system AGX driver gauge, not app-attributed"}
    report["thermalStates"] = sorted({r["thermalState"] for r in resources})
    hdr_requested = case.get("hdrPresentationRequested") is True
    report["dynamicRange"] = "EDR" if hdr_requested else "SDR"
    if hdr_requested:
        displays = [d.get("display", {}) for d in diagnostics]
        if any(d.get("edrEnabled") is not True or d.get("targetFormat") != "GL_RGBA16F / rgba16Float"
               or not finite(d.get("currentEDRHeadroom")) or d["currentEDRHeadroom"] <= 1.01
               or d.get("hdrPresentation", {}).get("awaitingHeadroom") is not False
               for d in displays):
            issues.append("Requested EDR route not active throughout measurement")
        if any(not finite(d.get("hdrPresentation", {}).get("maximumLinearComponent"))
               or d["hdrPresentation"]["maximumLinearComponent"] > d.get("currentEDRHeadroom", 1)
               for d in displays):
            issues.append("Missing EDR signal budget or budget exceeds current headroom")
        surfaces = [r.get("hdrSurface") or {} for r in rows]
        if any(s.get("surfaceCount") != 2 or not finite(s.get("surfaceBytes"))
               or s["surfaceBytes"] <= 0 or s["surfaceBytes"] > 128*1024*1024
               or not finite(s.get("maximumObservedInFlightFrames"))
               or not 1 <= s["maximumObservedInFlightFrames"] <= 2 for s in surfaces):
            issues.append("HDR surface budget or in-flight lifetime evidence missing/invalid")
        for field in ["glFinishMS", "metalWaitMS", "drawableWaitMS", "hostPresentMS", "metalPassGPUMS", "busyFrames"]:
            values = [s.get(field) for s in surfaces]
            report[field] = {"availableSamples": sum(finite(v) for v in values),
                             "median": statistics.median(values) if all(finite(v) for v in values) else None,
                             "p95": percentile(values, .95) if all(finite(v) for v in values) else None}
    if case["purpose"] != "sustained":
        report["sustainedAcceptance"] = "not-applicable-short-contract"
        return report
    if not 59.9 <= fps <= 60.1 or any(d.get("video", {}).get("width") != 3840 or
                         d.get("video", {}).get("height") != 2160 for d in diagnostics):
        issues.append("Fixed 3840x2160 59.94/60fps source not observed throughout")
    if any(r["render"].get("width") != 3840 or r["render"].get("height") != 2160 for r in rows):
        issues.append("Continuous native 3840x2160 render target not observed throughout")
    duration_ok = finite(warmup) and warmup >= 60 and wall >= 1800 and media >= 1799 and abs(wall - media) <= 2
    if not duration_ok:
        issues.append("Original 60 second warmup + uninterrupted 1800 second observation not met")
    valid = case.get("completed", False) and duration_ok and not issues
    measured = report["conservativeCombinedDropFraction"]
    avsync = report["maximumAbsoluteAVSyncSeconds"]
    unsubmitted = report.get("estimatedUnsubmittedFraction")
    memory_ok = all(report.get(f) is not None and not report[f]["growthConcern"] for f in ["residentBytes", "footprintBytes"])
    criteria_ok = (finite(measured) and measured <= .001 and finite(unsubmitted) and unsubmitted <= .001
                   and finite(avsync) and avsync <= .080 and memory_ok)
    report["sustainedAcceptance"] = "observed-targets-met" if valid and criteria_ok else "failed" if valid else "incomplete-or-interrupted"
    report["completeAV05Milestone"] = False
    report["fullPanelPresentationVerified"] = False
    report["scopeNote"] = "Only this fixed local/transport sample, explicitly recorded SDR/EDR route and render API target on this machine. Optical luminance/color, panel scanout, calibrated energy, real networks, other hardware and optical A/V latency remain separate. Full AV-05 is not established."
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cases = json.loads((args.directory / "cases.json").read_text())
    reports = []
    for case in cases:
        path = args.directory / (case["id"] + ".jsonl")
        records = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        reports.append(summarize(records, case))
    environment_path = args.directory / "environment.json"
    environment = json.loads(environment_path.read_text()) if environment_path.exists() else {}
    args.output.write_text(json.dumps({"schema": 1, "environment": environment, "cases": reports}, indent=2) + "\n")
    for report in reports:
        print(report["id"], report["sustainedAcceptance"], "; ".join(report["issues"]))


if __name__ == "__main__":
    main()
