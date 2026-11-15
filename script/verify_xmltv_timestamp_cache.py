#!/usr/bin/env python3
"""Compare baseline/current XMLTV parsing: complete outputs, CPU, wall time and process peak RSS."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixtures(root):
    base = datetime(2026, 10, 1, tzinfo=timezone.utc)
    result = {}

    def write(name, channels, rows, tail='</tv>'):
        path = root / (name + '.xml')
        with path.open('w') as f:
            f.write('<tv>')
            for channel in range(channels):
                f.write(f'<channel id="c{channel}"><display-name>频道 {channel}</display-name></channel>')
            for channel, start, stop, title in rows:
                f.write(f'<programme channel="c{channel}" start="{start}" stop="{stop}"><title>{title}</title></programme>')
            f.write(tail)
        result[name] = path

    def stamp(slot, minutes):
        return (base + timedelta(minutes=slot * minutes)).strftime('%Y%m%d%H%M%S +0000')

    write('aligned', 200, ((c, stamp(s, 30), stamp(s + 1, 30), f'节目 {c}-{s}')
                          for c in range(200) for s in range(336)))
    write('wide-working-set', 30, ((c, stamp(s, 5), stamp(s + 1, 5), f'节目 {c}-{s}')
                                  for c in range(30) for s in range(2016)))
    write('unique-over-capacity', 4, ((s % 4, stamp(2*s, 1), stamp(2*s + 1, 1), f'唯一 {s}')
                                     for s in range(12000)))
    formats = ('%Y%m%d%H%M%S %z', '%Y%m%d%H%M%S%z', '%Y%m%d%H%M%S', '%Y%m%d%H%M')
    zones = (timezone.utc, timezone(timedelta(hours=8)), timezone(timedelta(hours=-7)),
             timezone(timedelta(hours=5, minutes=45)))
    pairs = []
    for fmt in formats:
        for zone in zones:
            start = base.astimezone(zone)
            pairs.append((start.strftime(fmt), (start + timedelta(hours=1)).strftime(fmt)))
    pairs += [(v, '20261001010000 +0000') for v in (
        '', 'bad-date', '20260230000000 +0000', '20261301000000 +0000',
        '20261001250000 +0000', '20261001006000 +0000', '20261001000060 +0000',
        '20261001000000 +2460', '20261001000000 +0000junk',
        '20261001000000 +0000' + ' ' * 20, '20261001000000 +0000' + ' ' * 21,
        '20261001000000 +0000' + '界' * 6 + '  ', '20261001000000 +0000' + '界' * 7,
        '0' * 40, '0' * 41)]
    pairs += [('20261001000000 +0000', v) for v in (
        'bad-stop', '20260230010000 +0000', '20260930230000 +0000',
        '20261001000000 +0000', '20261003000000 +0000', '20261003000001 +0000')]
    write('formats-invalid-boundaries', 3, ((i % 3, a, b, f'边界 {i}-{repeat}')
           for repeat in range(30) for i, (a, b) in enumerate(pairs)))
    write('malformed', 1, [(0, stamp(0, 30), stamp(1, 30), 'before error')], '<programme>')
    path = root / 'entity.xml'
    path.write_text("<!DOCTYPE tv [<!ENTITY e 'expanded'>]><tv>&e;</tv>")
    result['entity'] = path
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline-ref', default='b6ec7417a8b284ec0b462be277a99fabdd76d74e')
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    if args.output.exists() or args.repetitions < 1:
        parser.error('use a fresh output directory and positive repetitions')
    output = args.output.resolve()
    output.mkdir(parents=True)
    repo = Path(__file__).resolve().parents[1]
    relative = 'NetVplayer/Sources/LiveEngine/XMLTVStreamingParser.swift'
    current = (repo / relative).read_text()
    baseline = subprocess.check_output(['git', 'show', args.baseline_ref + ':' + relative], cwd=repo, text=True)
    build = (repo / 'NetVplayer/.build/debug').resolve()
    description = json.loads((build / 'description.json').read_text())
    models = next(v for v in description['swiftCommands'].values() if v['moduleName'] == 'Models')
    fixture_source = repo / 'script/fixtures/xmltv_timestamp_probe.swift'
    records = []
    diagnostics = {}
    with tempfile.TemporaryDirectory(prefix='ov91-08-probe-') as folder:
        root = Path(folder)
        feeds = fixtures(root)
        binaries = {}
        for name, text in [('baseline', baseline), ('cache-256', current), ('cache-1024', current), ('cache-4096', current)]:
            if name != 'baseline':
                capacity = name.split('-')[1]
                text, changed = re.subn(r'static let capacity = 4_096', 'static let capacity = ' + capacity, text)
                if changed != 1:
                    raise SystemExit('capacity declaration changed; review the measurement variants')
            source = root / (name + '.swift')
            source.write_text(text)
            binary = root / name
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-O',
                            '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(root / 'ModuleCache'),
                            '-I', str(build / 'Modules'), str(source), str(fixture_source),
                            *models['objects'], '-o', str(binary)], check=True, timeout=120)
            binaries[name] = binary
        instrumented = current.replace(
            'if let cached = values[key] { return cached.date }',
            'if let cached = values[key] { XMLTVCacheProbeCounters.hits += 1; return cached.date }'
        ).replace('let date = resolve()', 'XMLTVCacheProbeCounters.misses += 1\n        let date = resolve()').replace(
            'return date\n    }',
            'XMLTVCacheProbeCounters.peakEntries = max(XMLTVCacheProbeCounters.peakEntries, values.count)\n        return date\n    }')
        if instrumented.count('XMLTVCacheProbeCounters.') != 4:
            raise SystemExit('cache changed; review diagnostic instrumentation')
        source = root / 'diagnostic.swift'
        source.write_text(instrumented)
        diagnostic = root / 'diagnostic'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-O',
                        '-D', 'XMLTV_CACHE_DIAGNOSTICS', '-target', 'arm64-apple-macosx14.0',
                        '-module-cache-path', str(root / 'ModuleCache'), '-I', str(build / 'Modules'),
                        str(source), str(fixture_source), *models['objects'], '-o', str(diagnostic)],
                       check=True, timeout=120)
        for scenario, feed in feeds.items():
            run = subprocess.run([str(diagnostic), str(feed), 'all'], check=True, capture_output=True,
                                 text=True, timeout=60, env={**os.environ, 'TZ': 'UTC'})
            diagnostics[scenario] = json.loads(run.stdout)
        # Fresh process per run, alternating forward/reverse order to reduce drift.
        for scenario, feed in feeds.items():
            modes = ('all', 'window') if scenario == 'formats-invalid-boundaries' else ('all',)
            for mode in modes:
                for repetition in range(args.repetitions):
                    variants = list(binaries)
                    if repetition % 2:
                        variants.reverse()
                    for variant in variants:
                        run = subprocess.run([str(binaries[variant]), str(feed), mode], check=True,
                                             capture_output=True, text=True, timeout=60,
                                             env={**os.environ, 'TZ': 'UTC'})
                        record = json.loads(run.stdout)
                        record.update(scenario=scenario, window=mode, variant=variant, repetition=repetition)
                        records.append(record)
                        print(json.dumps(record), flush=True)
        (output / 'fixture-manifest.json').write_text(json.dumps({k: {'sha256': sha(p), 'bytes': p.stat().st_size}
                                                                 for k, p in feeds.items()}, indent=2) + '\n')
    groups = {}
    identity_fields = ('status', 'programmes', 'channels', 'batches', 'maxBatch', 'fullOutputSHA256')
    for record in records:
        key = record['scenario'] + '/' + record['window']
        group = groups.setdefault(key, {})
        identity = {k: record[k] for k in identity_fields}
        if group and next(iter(group.values()))['output'] != identity:
            raise SystemExit('complete output or error mismatch: ' + key)
        variant = group.setdefault(record['variant'], {'output': identity, 'samples': []})
        variant['samples'].append({k: record[k] for k in ('wallSeconds', 'cpuSeconds', 'peakRSSBytes')})
    for group in groups.values():
        for variant in group.values():
            variant['median'] = {k: statistics.median(s[k] for s in variant['samples']) for k in variant['samples'][0]}
    for scenario, record in diagnostics.items():
        if {k: record[k] for k in identity_fields} != groups[scenario + '/all']['cache-4096']['output']:
            raise SystemExit('diagnostic build changed output: ' + scenario)
        if record['cachePeakEntries'] > 4096:
            raise SystemExit('diagnostic cache exceeded capacity: ' + scenario)
    result = {'baselineRef': args.baseline_ref, 'allOutputsEqual': True, 'optimization': '-O',
              'repetitions': args.repetitions, 'groups': groups, 'runs': records, 'diagnosticOnly': diagnostics,
              'environment': {'os': subprocess.check_output(['sw_vers'], text=True).strip(),
                              'swift': subprocess.check_output(['swift', '--version'], text=True).strip()},
              'sourceSHA256': {relative: hashlib.sha256(current.encode()).hexdigest(),
                               str(fixture_source.relative_to(repo)): sha(fixture_source),
                               str(Path(__file__).relative_to(repo)): sha(Path(__file__))},
              'baselineParserSHA256': hashlib.sha256(baseline.encode()).hexdigest(),
              'scope': 'Synthetic streaming parser only; no network, index I/O, UI, user data or product launch.'}
    (output / 'comparison.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
