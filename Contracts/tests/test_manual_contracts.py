#!/usr/bin/env python3
"""Run the actual portable Swift verification sources against the shared FX1 fixtures.

Copies sources unchanged into an isolated temporary package. No substitutes for signature,
archive, manifest or ZIP verification are used; the app UI/installer is outside this suite.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "Services/OfficeSync/OfficeManualAssignment.swift",
    "Services/OfficeSync/OfficeManagedJob.swift",
    "Services/OfficeSync/OfficeManagedJobReceipt.swift",
    "Services/OfficeSync/OfficeManualImport.swift",
    "Services/Vault/VaultArchive.swift",
    "Services/Vault/VaultPublisher.swift",
    "Services/Vault/VaultManifest.swift",
    "Services/SkillPacks/SkillPackSignature.swift",
    "Services/Reading/BookFileExtractor.swift",
]
TESTS = ["OfficeManualAssignmentTests.swift", "OfficeManagedJobTests.swift", "OfficeManagedJobReceiptTests.swift", "OfficeManualImportTests.swift", "VaultArchiveFixtures.swift"]


def main():
    cache = ROOT / "Transport/.tools"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="manual-contract-check-", dir=cache) as directory:
        package = Path(directory)
        source = package / "Sources/OpenGlasses"
        tests = package / "Tests/ContractTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        for path in SOURCES:
            shutil.copyfile(ROOT / "OpenGlasses/Sources" / path, source / Path(path).name)
        for name in TESTS:
            shutil.copyfile(ROOT / "OpenGlassesTests" / name, tests / name)
        shutil.copytree(ROOT / "Contracts/fixtures", tests / "Fixtures")
        (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AvenkinContractCheck", platforms: [.macOS(.v13)], targets: [
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
