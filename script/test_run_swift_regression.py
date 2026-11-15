from pathlib import Path
import subprocess
import sys
import unittest


RUNNER = Path(__file__).with_name("run_swift_regression.py")


class SwiftRegressionRunnerTests(unittest.TestCase):
    def run_child(self, code, *, summary=True, idle=2):
        command = [sys.executable, str(RUNNER), "--idle-timeout", str(idle)]
        if summary:
            command.append("--require-summary")
        return subprocess.run(command + ["--", sys.executable, "-c", code],
                              capture_output=True, text=True, timeout=15)

    def test_non_swift_commands_keep_their_exit_status(self):
        self.assertEqual(self.run_child('print("normal")', summary=False).returncode, 0)
        self.assertEqual(self.run_child('raise SystemExit(7)').returncode, 7)

    def test_each_started_run_requires_its_own_completion(self):
        for count in (1, 2, 8):
            with self.subTest(count=count):
                code = ('print("◇ Test run started."); '
                        'print("✔ Test run with 10 tests passed after 0.1 seconds."); ') * count
                self.assertEqual(self.run_child(code).returncode, 0)

    def test_zero_exit_without_any_test_run_is_rejected(self):
        self.assertEqual(self.run_child('pass').returncode, 125)

    def test_zero_exit_with_an_unfinished_run_is_rejected(self):
        result = self.run_child('print("◇ Test run started.")')
        self.assertEqual(result.returncode, 125)
        self.assertIn("1 runs started, 0 completed", result.stdout)

    def test_earlier_completed_runs_do_not_hide_a_later_early_exit(self):
        result = self.run_child('print("◇ Test run started."); '
                                'print("✔ Test run with 2 tests passed."); '
                                'print("◇ Test run started.")')
        self.assertEqual(result.returncode, 125)

    def test_ansi_chunk_boundaries_and_no_final_newline_are_supported(self):
        result = self.run_child('import sys,time; print("◇ Test run started."); '
                                'sys.stdout.write("\\x1b[32m✔ Test run with 1 te"); '
                                'sys.stdout.flush(); time.sleep(0.05); '
                                'sys.stdout.write("st passed.\\x1b[0m")')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_idle_child_is_bounded(self):
        self.assertEqual(self.run_child('import time; time.sleep(10)', idle=0.1).returncode, 124)

    def test_closed_output_does_not_disable_the_idle_deadline(self):
        result = self.run_child('import os,time; os.close(1); os.close(2); time.sleep(10)', idle=0.1)
        self.assertEqual(result.returncode, 124)


if __name__ == "__main__":
    unittest.main()
