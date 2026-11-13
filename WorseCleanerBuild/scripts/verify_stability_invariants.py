#!/usr/bin/env python3
"""Guard the requested v90 UI baseline and release/test execution order."""
from pathlib import Path
import hashlib
import re
import shlex

root = Path(__file__).resolve().parents[2]
src = root / "WorseCleanerBuild" / "WorseCleaner"
baseline = {'ContentView.swift': '26694f3f3ff85b9a000996a5108818aac22b4f625b02e968e8cadb86cce85f12', 'CleanerUIComponents.swift': '43d477c53530bf084ee17dd5c8e66ae1698aa07144c4dcdd5e34ae6d049ef5c9', 'CleanerAdvancedSettingsView.swift': 'f6dce62dc28e4f6606bf262685da08c82904c7b079df87cbf5a4ae812e1c0a0e', 'CleanerScreenshotFixtures.swift': '28ff70b51ad2c68e62f68604141520a0d248d062e73d250b0189aa2fcf0f28e1', 'WorseCleanerApp.swift': '124e2a3018a99d68f714c69276a2e3241cdcc24a9fbed0ec0c5a12d6f0375e2f', 'Info.plist': 'b469ee4b625a3890740f0dbf59285e5fa36cb48a1678df7ff4b2f676978c8ca0', 'Assets.xcassets/AppIcon.appiconset/Contents.json': 'd3aa64d06ac13ee1b55d6b31e9c5f415b04847b74742d7ef5012738756c11d90'}
for name, expected in baseline.items():
    assert hashlib.sha256((src / name).read_bytes()).hexdigest() == expected, "Protected UI changed: " + name
print("PASS protected homepage, search, settings layout, fixtures and app assets match v90")

for workflow in (root / ".github" / "workflows").glob("*.yml"):
    script = workflow.read_text(encoding="utf-8")
    joined = re.sub(r"\\\n[ \t]*", " ", script)
    for line in joined.splitlines():
        if line.lstrip().startswith("xcodebuild "):
            args = shlex.split(line.strip())
            assert args.count("test") <= 1, "Repeated test action: " + workflow.name
print("PASS each xcodebuild command declares the test action at most once")

release = (root / ".github" / "workflows" / "cleaner-ipa.yml").read_text(encoding="utf-8")
publish = release.index("- name: Publish Cleaner release")
for step in ["Verify source safety invariants", "Compile unsigned", "Verify search spacing and keyboard in simulator",
             "Run Cleaner logic unit tests", "Capture native toolbar menus with UI tests"]:
    assert release.index("- name: " + step) < publish, "Release precedes required gate: " + step
assert "if: success() && github.ref == 'refs/heads/main'" in release
assert '"$current_main" != "$GITHUB_SHA"' in release
print("PASS release follows all required checks and refuses superseded main commits")
