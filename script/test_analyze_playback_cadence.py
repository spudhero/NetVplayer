import copy
import unittest
from analyze_playback_cadence import analyze


def capture():
    samples = []
    for i in range(61):
        samples.append({'reading': {'uptime': i + 10, 'speed': 1, 'paused': False, 'pausedForCache': False,
            'diagnostics': {'mediaID': 'one', 'video': {'framesPerSecond': 24}, 'mpvVersion': 'mpv v0.41.0',
                'ffmpegVersion': '9.0.1', 'decoderDroppedFrames': 0, 'rendererDroppedFrames': 0,
                'audioVideoOffsetSeconds': 0, 'display': {'targetFormat': 'GL_RGBA8', 'timing': {'configuredRefreshRateHz': 60}}}},
            'frames': {'pauseRequests': 0, 'seekRequests': 0, 'speedChanges': 0, 'cachePauseCount': 0}})
    mode = {'configuredRefreshHz': 60}
    return {'id': 'reference', 'completed': True, 'startUptime': 10, 'endUptime': 70,
        'modeWrites': 0, 'before': mode, 'after': copy.copy(mode), 'samples': samples,
        'trace': {'overflow': 0, 'frames': [{'uptime': 10 + i / 24, 'flags': 1} for i in range(1441)],
                  'ticks': [{'hostSeconds': 10 + i / 60, 'videoTimeScale': 60, 'flags': 3} for i in range(3601)]}}


class CadenceAnalysisTests(unittest.TestCase):
    def test_host_reference_never_proves_panel_or_qms(self):
        result = analyze(capture(), '24')
        self.assertTrue(result['hostContinuityPassed'], result['errors'])
        self.assertFalse(result['physicalCadenceVerified'])
        self.assertFalse(result['qmsVerified'])
        self.assertIsNone(result['physicalBlackoutMilliseconds'])

    def test_host_under_delivery_is_not_hidden_by_zero_mpv_drops(self):
        report = capture()
        report['trace']['frames'] = report['trace']['frames'][::2]
        self.assertIn('host-rate-error-over-0.5-percent', analyze(report, '24')['errors'])

    def test_cache_and_unknown_mode_and_wrong_runtime_reject(self):
        report = capture()
        report['samples'][30]['frames']['cachePauseCount'] = 1
        report['samples'][30]['reading']['diagnostics']['ffmpegVersion'] = '9.0.2'
        report['samples'][30]['reading']['diagnostics']['display']['timing'] = {}
        errors = analyze(report, '24')['errors']
        self.assertIn('interaction-or-cache-event', errors)
        self.assertIn('runtime-version-mismatch', errors)
        self.assertIn('display-rate-changed-or-unknown', errors)
        for rate in [None, 0, float('nan')]:
            unavailable = capture()
            unavailable['before']['configuredRefreshHz'] = rate
            result = analyze(unavailable, '24')
            self.assertFalse(result['hostContinuityPassed'])
            self.assertIn('unknown-refresh-rate', result['errors'])

    def test_repeat_and_unknown_flags_do_not_count_as_new_frames(self):
        report = capture()
        for frame in report['trace']['frames'][::2]:
            frame['flags'] = 5
        report['trace']['frames'][5]['flags'] = -1
        result = analyze(report, '24')
        self.assertFalse(result['hostContinuityPassed'])
        self.assertIn('unknown-render-flags', result['errors'])


if __name__ == '__main__':
    unittest.main()
