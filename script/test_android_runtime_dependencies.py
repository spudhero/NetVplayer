from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import zipfile

from validate_android_runtime_dependencies import validate


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("vtool"), "requires macOS command-line tools")
class EmbeddedHostNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inputs = tempfile.TemporaryDirectory(prefix="netvplayer-embedded-native-inputs-")
        root = Path(cls.inputs.name)
        source = root / "probe.c"
        source.write_text("int probe(void) { return 7; }\n")
        cls.binaries = {}
        for name, target in [("arm14", "arm64-apple-macos14.0"), ("arm15", "arm64-apple-macos15.0"),
                             ("intel14", "x86_64-apple-macos14.0")]:
            output = root / (name + ".dylib")
            subprocess.run(["xcrun", "clang", "-dynamiclib", "-target", target, str(source), "-o", str(output)],
                           check=True, capture_output=True)
            cls.binaries[name] = output.read_bytes()
        ios = root / "ios13.dylib"
        subprocess.run(["/usr/bin/vtool", "-set-build-version", "ios", "13.0", "26.2", "-replace",
                        "-output", str(ios), str(root / "arm14.dylib")], check=True, capture_output=True)
        cls.binaries["ios13"] = ios.read_bytes()
        external = root / "external.dylib"
        shutil.copyfile(root / "arm14.dylib", external)
        subprocess.run(["/usr/bin/install_name_tool", "-change", "/usr/lib/libSystem.B.dylib",
                        "@rpath/absent.dylib", str(external)], check=True, capture_output=True)
        cls.binaries["external"] = external.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.inputs.cleanup()

    def inspect(self, entries):
        with tempfile.TemporaryDirectory(prefix="netvplayer-embedded-native-package-") as tmp:
            root = Path(tmp)
            jar = root / "fixture.jar"
            with zipfile.ZipFile(jar, "w") as archive:
                for name, data in entries.items():
                    archive.writestr(name, data)
            before = jar.read_bytes()
            report = validate(root, "14.0", {"arm64"})
            self.assertEqual(jar.read_bytes(), before)
            return report

    def test_keeps_both_loader_variants_and_checks_every_slice(self):
        report = self.inspect({"natives/osx_arm64/probe.dylib": self.binaries["arm14"],
                               "natives/osx_64/probe.dylib": self.binaries["intel14"]})
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["nativeMachOCount"], 2)

    def test_wrong_loader_directory_is_rejected(self):
        report = self.inspect({"natives/osx_64/probe.dylib": self.binaries["arm14"]})
        self.assertIn("directory", str(report["failures"]))

    def test_intel_only_library_cannot_satisfy_arm_declaration(self):
        report = self.inspect({"natives/osx_64/probe.dylib": self.binaries["intel14"]})
        self.assertIn("missing declared architectures: arm64", str(report["failures"]))

    def test_newer_embedded_native_is_rejected(self):
        report = self.inspect({"natives/osx_arm64/probe.dylib": self.binaries["arm15"]})
        self.assertIn("exceeds 14.0", str(report["failures"]))

    def test_ios_native_is_rejected(self):
        report = self.inspect({"natives/osx_arm64/probe.dylib": self.binaries["ios13"]})
        self.assertIn("not macOS", str(report["failures"]))

    def test_corrupt_native_is_rejected(self):
        report = self.inspect({"natives/osx_arm64/probe.dylib": b"corrupt"})
        self.assertIn("not Mach-O", str(report["failures"]))

    def test_missing_embedded_dependency_is_rejected(self):
        report = self.inspect({"natives/osx_arm64/probe.dylib": self.binaries["external"]})
        self.assertIn("non-system dependency", str(report["failures"]))

    def test_guest_android_elf_is_not_a_macos_host_library(self):
        report = self.inspect({"lib/arm64-v8a/probe.so": b"\x7fELFguest-fixture"})
        self.assertEqual(report["nativeMachOCount"], 0)
        self.assertEqual(report["failures"], [])


if __name__ == "__main__":
    unittest.main()
