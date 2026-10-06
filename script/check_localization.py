#!/usr/bin/env python3
"""Validate shipped Chinese/English resources and argument parity without a build."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = ROOT / "NetVplayer/Sources/Models/Resources/Localization"
PAIR = re.compile(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");$', re.M)


def read(language):
    text = (RESOURCE / f"{language}.lproj/Localizable.strings").read_text()
    result = {}
    for key, value in PAIR.findall(text):
        key, value = json.loads(key), json.loads(value)
        assert key not in result, f"Duplicate {language} key: {key}"
        result[key] = value
    assert len(result) >= 1000, f"Missing {language} resources"
    return result


def main():
    chinese, english = read("zh-Hans"), read("en")
    assert chinese.keys() == english.keys(), "Language keys differ"
    for key in chinese:
        source = set(re.findall(r"\{\d+\}", chinese[key]))
        assert source == set(re.findall(r"\{\d+\}", english[key])), f"Argument mismatch: {key}"
        assert english[key].strip(), f"Empty English translation: {key}"
    referenced = set()
    pattern = re.compile(r'L10n\.text\(("(?:\\.|[^"\\])*")')
    for source in (ROOT / "NetVplayer/Sources").rglob("*.swift"):
        for raw in pattern.findall(source.read_text()):
            referenced.add(json.loads(raw))
    missing = sorted(referenced - chinese.keys())
    assert not missing, "Missing localized source keys: " + ", ".join(missing)
    print(
        f"Localization: {len(chinese)} Chinese/English pairs; "
        f"{len(referenced)} source keys and argument parity verified"
    )


if __name__ == "__main__":
    main()
