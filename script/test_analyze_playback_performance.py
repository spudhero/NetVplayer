import copy
import unittest

from script.analyze_playback_performance import summarize


def fixture():
    rows = []
    for i in range(1801):
        rows.append({"phase": "measurement", "reading": {
            "uptime": 60 + i, "position": 60 + i, "paused": False,
            "pausedForCache": False, "speed": 1, "diagnostics": {
                "mediaID": "one", "video": {"framesPerSecond": 60, "width": 3840,
                    "height": 2160, "hardwareDecoder": "videotoolbox-copy"},
                "decoderDroppedFrames": 20, "rendererDroppedFrames": 30,
                "audioVideoOffsetSeconds": .01}},
            "render": {"firstFrameUptime": 0, "loadUptime": -.5, "width": 3840, "height": 2160,
                "freshFrames": i * 60,
                "cachePauseCount": 0, "cachePauseSeconds": 0, "pauseRequests": 0, "seekRequests": 0, "speedChanges": 0},
            "resources": {"uptime": 60 + i, "cpuSeconds": i * .2,
                "residentBytes": 500_000_000, "footprintBytes": 600_000_000, "thermalState": 0}})
    return rows, {"id": "synthetic-analysis-contract", "purpose": "sustained", "completed": True}


class PerformanceAnalysisTests(unittest.TestCase):
    def test_hdr_requests_require_current_edr_and_bounded_live_surfaces(self):
        rows, case = fixture()
        case["hdrPresentationRequested"] = True
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "incomplete-or-interrupted")
        for row in rows:
            row["reading"]["diagnostics"]["display"] = {"edrEnabled": True,
                "targetFormat": "GL_RGBA16F / rgba16Float", "currentEDRHeadroom": 4,
                "hdrPresentation": {"maximumLinearComponent": 4, "awaitingHeadroom": False}}
            row["hdrSurface"] = {"surfaceCount": 2, "surfaceBytes": 2*3840*2160*8,
                "maximumObservedInFlightFrames": 2, "glFinishMS": 2, "metalWaitMS": 0,
                "metalPassGPUMS": .5, "busyFrames": 0}
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "observed-targets-met")
        changed = copy.deepcopy(rows)
        changed[900]["reading"]["diagnostics"]["display"]["currentEDRHeadroom"] = 1
        self.assertEqual(summarize(changed, case)["sustainedAcceptance"], "incomplete-or-interrupted")
        rows[900]["hdrSurface"]["maximumObservedInFlightFrames"] = 3
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "incomplete-or-interrupted")

    def test_pre_warmup_drops_are_baselined_and_rates_are_separate(self):
        rows, case = fixture()
        rows[-1]["reading"]["diagnostics"]["decoderDroppedFrames"] += 10
        rows[-1]["reading"]["diagnostics"]["rendererDroppedFrames"] += 20
        result = summarize(rows, case)
        self.assertEqual(result["decoderDroppedFrames"], 10)
        self.assertEqual(result["rendererDroppedFrames"], 20)
        self.assertEqual(result["freshFrameSubmissions"], 108000)
        self.assertEqual(result["estimatedUnsubmittedFraction"], 0)
        self.assertAlmostEqual(result["conservativeCombinedDropFraction"], 30 / 108000)
        self.assertEqual(result["sustainedAcceptance"], "observed-targets-met")
        self.assertFalse(result["completeAV05Milestone"])
        self.assertEqual(result["gpuPassAverageMilliseconds"]["availableSamples"], 0)

    def test_short_or_interrupted_runs_cannot_close_sustained_acceptance(self):
        rows, case = fixture()
        mutations = [lambda r: r.pop(), lambda r: r[800]["reading"].update(pausedForCache=True),
            lambda r: r[800]["reading"].update(paused=True), lambda r: r[800]["reading"].update(speed=2),
            lambda r: r[800]["reading"].update(position=10), lambda r: r[800]["reading"].pop("pausedForCache"),
            lambda r: r[800]["reading"]["diagnostics"].update(decoderDroppedFrames=0),
            lambda r: r[800]["reading"]["diagnostics"].update(mediaID="replacement"),
            lambda r: r[800]["render"].update(width=1920, height=1080),
            lambda r: r[800]["render"].update(freshFrames=0),
            lambda r: r[800]["render"].pop("freshFrames"),
            lambda r: r[800]["reading"]["diagnostics"]["video"].update(width=1920),
            lambda r: r[-1]["render"].update(cachePauseCount=1, cachePauseSeconds=.1),
            lambda r: r.__delitem__(slice(800, 805))]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                changed = copy.deepcopy(rows); mutate(changed)
                self.assertEqual(summarize(changed, case)["sustainedAcceptance"], "incomplete-or-interrupted")

    def test_original_sync_and_drop_targets_are_not_relaxed(self):
        rows, case = fixture()
        rows[-1]["reading"]["diagnostics"]["rendererDroppedFrames"] += 109
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "failed")
        rows, case = fixture()
        rows[900]["reading"]["diagnostics"]["audioVideoOffsetSeconds"] = -.081
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "failed")
        rows, case = fixture()
        for i, row in enumerate(rows):
            row["reading"]["diagnostics"]["video"]["framesPerSecond"] = 120
            row["render"]["freshFrames"] = i * 120
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "incomplete-or-interrupted")

    def test_unchanged_mpv_drop_counters_do_not_hide_missing_host_submissions(self):
        rows, case = fixture()
        for i, row in enumerate(rows):
            row["render"]["freshFrames"] = i * 59
        result = summarize(rows, case)
        self.assertEqual(result["rendererDroppedFrames"], 0)
        self.assertGreater(result["estimatedUnsubmittedFraction"], .001)
        self.assertEqual(result["sustainedAcceptance"], "failed")

    def test_growth_concern_missing_fields_and_short_contract_remain_distinct(self):
        rows, case = fixture()
        for i, row in enumerate(rows):
            row["resources"]["footprintBytes"] += i * 100000
        self.assertTrue(summarize(rows, case)["footprintBytes"]["growthConcern"])
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "failed")
        rows[100]["reading"]["diagnostics"].pop("audioVideoOffsetSeconds")
        self.assertEqual(summarize(rows, case)["sustainedAcceptance"], "incomplete-or-interrupted")
        case["purpose"] = "compatibility"
        self.assertEqual(summarize(rows[:3], case)["sustainedAcceptance"], "not-applicable-short-contract")


if __name__ == "__main__":
    unittest.main()
