#!/usr/bin/env python3
"""Run the recorded-session rules (Contracts/recorded-session.md) against their fixtures.

The same shape as test_manual_contracts.py: the production sources and their tests are copied
unchanged into an isolated temporary package and run with `swift test`. These sources are pure —
no capture, no storage, no transport — so the whole of the recorded-job core runs here, not only
the rules an office must compute the same way.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = "OpenGlasses/Sources/Services/FieldAssist/JobRecording"
TESTS = [
    "RecordedJobFixtures.swift",
    "SessionClockTests.swift",
    "SessionTimelineCodingTests.swift",
    "TimedTranscriptCodingTests.swift",
    "WalkthroughSegmenterTests.swift",
    "TurnAlignerTests.swift",
    "ProcedureCandidateDetectorTests.swift",
    "ChunkPlanTests.swift",
    "BundleSyncStateTests.swift",
    "SyncEligibilityTests.swift",
    "RetentionDecisionTests.swift",
    "RecordingTextTests.swift",
    "ActionEventValidatorTests.swift",
    "SpeechAgreementTests.swift",
    "CrossReferenceIndexTests.swift",
    "BundleManifestTests.swift",
]


def main():
    cache = ROOT / "Transport/.tools"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="recorded-session-check-", dir=cache) as directory:
        package = Path(directory)
        source = package / "Sources/OpenGlasses"
        tests = package / "Tests/ContractTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        for path in sorted((ROOT / SOURCES).glob("*.swift")):
            shutil.copyfile(path, source / path.name)
        for name in TESTS:
            shutil.copyfile(ROOT / "OpenGlassesTests" / name, tests / name)
        shutil.copytree(ROOT / "Contracts/fixtures", tests / "Fixtures")
        (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AvenkinRecordedSessionCheck", platforms: [.macOS(.v13)], targets: [
    .target(name: "OpenGlasses"),
    .testTarget(name: "ContractTests", dependencies: ["OpenGlasses"], resources: [.copy("Fixtures")])
])
''')
        environment = os.environ.copy()
        environment.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/avenkin-clang-cache")
        environment.setdefault("SWIFT_MODULECACHE_PATH", "/private/tmp/avenkin-swift-cache")
        subprocess.run(["swift", "test", "--disable-sandbox", "--package-path", str(package)],
                       check=True, env=environment)


if __name__ == "__main__":
    main()
