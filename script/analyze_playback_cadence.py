#!/usr/bin/env python3
"""Validate AV-11 host continuity. Never label host timestamps as panel/QMS proof."""
import argparse
from collections import Counter
from fractions import Fraction
import json
import math
from pathlib import Path
import statistics


def analyze(report, rate):
    errors = []
    def check(condition, message):
        if not condition:
            errors.append(message)
    start, end = report.get('startUptime'), report.get('endUptime')
    check(report.get('completed') is True and report.get('error') is None, 'collection-incomplete')
    check(isinstance(start, (int, float)) and isinstance(end, (int, float)) and end - start >= 60, 'duration-under-60s')
    if start is None or end is None:
        return {'id': report['id'], 'errors': errors, 'hostContinuityPassed': False}
    check(report.get('modeWrites') == 0 and report.get('before') == report.get('after'), 'display-mode-changed')
    trace = report.get('trace', {})
    check(trace.get('overflow') == 0, 'trace-overflow')
    source_fps = float(Fraction(rate))
    refresh = (report.get('before') or {}).get('configuredRefreshHz')
    if not isinstance(refresh, (int, float)) or not math.isfinite(refresh) or refresh <= 0:
        errors.append('unknown-refresh-rate')
        return {'id': report['id'], 'errors': errors, 'hostContinuityPassed': False,
                'physicalCadenceVerified': False, 'physicalBlackoutMilliseconds': None, 'qmsVerified': False}
    frames = [f for f in trace.get('frames', []) if start <= f['uptime'] <= end]
    check(all(f['flags'] >= 0 for f in frames), 'unknown-render-flags')
    fresh = [f['uptime'] for f in frames if f['flags'] & 1 and not f['flags'] & 6]
    intervals = [b - a for a, b in zip(fresh, fresh[1:])]
    check(len(fresh) > 1 and all(x > 0 for x in intervals), 'invalid-frame-order')
    if len(fresh) < 2:
        return {'id': report['id'], 'errors': errors, 'hostContinuityPassed': False}
    actual_fps = (len(fresh) - 1) / (fresh[-1] - fresh[0])
    check(abs(actual_fps / source_fps - 1) <= 0.005, 'host-rate-error-over-0.5-percent')
    check(max(intervals) <= max(0.1, 3 / source_fps), 'host-gap-over-fixed-limit')
    samples = [s for s in report['samples'] if start <= s['reading']['uptime'] <= end]
    check(len(samples) >= 50, 'insufficient-diagnostic-samples')
    ids = {s['reading']['diagnostics']['mediaID'] for s in samples}
    check(len(ids) == 1, 'media-identity-changed')
    check(all(s['reading'].get('speed') == 1 and s['reading'].get('paused') is False and
              s['reading'].get('pausedForCache') is False for s in samples), 'speed-pause-or-cache-state')
    check(all(s['frames']['pauseRequests'] == 0 and s['frames']['seekRequests'] == 0 and
              s['frames']['speedChanges'] == 0 and s['frames']['cachePauseCount'] == 0 for s in samples), 'interaction-or-cache-event')
    check(all(abs(s['reading']['diagnostics']['video'].get('framesPerSecond', 0) / source_fps - 1) < 0.0001
              for s in samples), 'source-rate-mismatch')
    check(all(s['reading']['diagnostics'].get('mpvVersion') == 'mpv v0.41.0' and
              s['reading']['diagnostics'].get('ffmpegVersion') == '9.0.1' for s in samples), 'runtime-version-mismatch')
    check(all(s['reading']['diagnostics']['display'].get('timing', {}).get('configuredRefreshRateHz') == refresh
              for s in samples), 'display-rate-changed-or-unknown')
    for a, b in zip(samples, samples[1:]):
        check(0 < b['reading']['uptime'] - a['reading']['uptime'] <= 2.5, 'diagnostic-gap')
    drops = {}
    for key in ['decoderDroppedFrames', 'rendererDroppedFrames']:
        values = [s['reading']['diagnostics'].get(key) for s in samples]
        valid = bool(values) and all(isinstance(v, int) and v >= 0 for v in values)
        check(valid, 'missing-' + key)
        if valid:
            check(all(b >= a for a, b in zip(values, values[1:])), 'counter-regressed-' + key)
            drops[key] = values[-1] - values[0]
    check(len(drops) == 2 and sum(drops.values()) / (source_fps * (end - start)) <= 0.001, 'drop-rate-over-0.1-percent')
    av = [s['reading']['diagnostics'].get('audioVideoOffsetSeconds') for s in samples]
    valid_av = bool(av) and all(isinstance(x, (int, float)) and math.isfinite(x) for x in av)
    check(valid_av and max(abs(x) for x in av) <= 0.08, 'missing-or-over-80ms-engine-avsync')
    ticks = [t for t in trace.get('ticks', []) if start <= t['hostSeconds'] <= end]
    check(len(ticks) >= 50, 'missing-display-clock')
    # Host and video-time valid bits; unknown timestamps are never replaced by expected time.
    check(all(t['flags'] & 3 == 3 and t['videoTimeScale'] > 0 for t in ticks), 'invalid-clock-flags')
    periods = [b['hostSeconds'] - a['hostSeconds'] for a, b in zip(ticks, ticks[1:])]
    clock_hz = 1 / statistics.median(periods) if periods else None
    check(clock_hz is not None and abs(clock_hz / refresh - 1) <= 0.001, 'clock-rate-error-over-0.1-percent')
    check(all(0 < p <= 2.5 / refresh for p in periods), 'display-clock-discontinuity')
    ratio = refresh / source_fps
    # This is a histogram of flush-completion intervals, not repeated panel frames.
    histogram = Counter(round(x * refresh) for x in intervals)
    return {'id': report['id'], 'rate': rate, 'seconds': end - start, 'configuredRefreshHz': refresh,
        'cvDisplayLinkMedianHz': clock_hz, 'cvDisplayLinkActualPeriodSeconds': report.get('actualDisplayLinkPeriodSeconds'),
        'freshHostSubmissions': len(fresh), 'hostMeanFPS': actual_fps,
        'hostIntervalMedianMilliseconds': statistics.median(intervals) * 1000,
        'hostIntervalP95Milliseconds': sorted(intervals)[int(0.95 * (len(intervals) - 1))] * 1000,
        'hostIntervalMaximumMilliseconds': max(intervals) * 1000,
        'hostIntervalRoundedRefreshTicks': dict(sorted(histogram.items())),
        'idealAverageRefreshTicksPerSourceFrame': ratio,
        'idealAdjacentRefreshTickCounts': sorted({math.floor(ratio), math.ceil(ratio)}),
        'drops': drops, 'maximumAbsoluteEngineAVSyncMilliseconds': max(abs(x) for x in av) * 1000 if valid_av else None,
        'versions': sorted({(s['reading']['diagnostics'].get('mpvVersion'), s['reading']['diagnostics'].get('ffmpegVersion')) for s in samples}),
        'renderTargets': sorted({s['reading']['diagnostics']['display'].get('targetFormat', 'unknown') for s in samples}),
        'errors': sorted(set(errors)), 'hostContinuityPassed': not errors,
        'physicalCadenceVerified': False, 'physicalBlackoutMilliseconds': None, 'qmsVerified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--captures', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.fixtures.read_text())
    results = [analyze(json.loads((args.captures / (c['id'] + '.json')).read_text()), c['rate']) for c in manifest['cases']]
    report = {'schema': 1, 'scope': 'Fixed-refresh host continuity and display clock only; no physical scanout, QMS or complete AV-11 acceptance',
              'cases': results, 'hostContinuityPassed': all(c['hostContinuityPassed'] for c in results), 'completeAV11': False}
    with args.output.open('x') as f:
        json.dump(report, f, indent=2); f.write('\n')
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report['hostContinuityPassed'] else 1)
