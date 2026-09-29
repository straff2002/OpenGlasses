#!/usr/bin/env python3
"""Prepare the pinned mobile source extension without modifying the Go module cache."""
import hashlib
import base64
import json
from pathlib import Path
import sys
import shutil
import tempfile


def prepare_source(module_cache, destination):
    transport = Path(__file__).resolve().parents[1]
    extension = transport / "vendor/syncthing/mobile-extension"
    pin = json.loads((extension / "pin.json").read_text())
    source = Path(module_cache) / f"github.com/syncthing/syncthing@{pin['moduleVersion']}" / pin["source"]
    if hashlib.sha256(source.read_bytes()).hexdigest() != pin["upstreamSHA256"]:
        raise ValueError("Upstream source changed; review the model hook before building")
    root = source.parents[2]
    digest = hashlib.sha256()
    prefix = f"github.com/syncthing/syncthing@{pin['moduleVersion']}"
    for path in sorted(root.rglob("*")):
        if path.is_symlink(): raise ValueError("Unexpected symlink in upstream module")
        if path.is_file():
            name = f"{prefix}/{path.relative_to(root).as_posix()}"
            if "\n" in name: raise ValueError("Invalid upstream source name")
            digest.update(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {name}\n".encode())
    if "h1:" + base64.b64encode(digest.digest()).decode() != pin["upstreamModuleSum"]:
        raise ValueError("Upstream module differs from its recorded Go checksum")
    replacement = extension / "syncthing.go"
    destination = Path(destination).resolve()
    if destination != (transport / ".tools/syncthing-mobile").resolve():
        raise ValueError("Only the generated mobile engine directory may be replaced")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Only this generated source directory is replaced; the module cache is read-only.
    staging = Path(tempfile.mkdtemp(prefix="mobile-source-", dir=destination.parent))
    try:
        shutil.copytree(source.parents[2], staging, dirs_exist_ok=True)
        for directory in [staging, *[p for p in staging.rglob("*") if p.is_dir()]]:
            directory.chmod(0o700)
        target = staging / pin["source"]
        target.chmod(0o600)
        target.write_bytes(replacement.read_bytes())
        if destination.exists():
            for directory in [destination, *[p for p in destination.rglob("*") if p.is_dir()]]:
                directory.chmod(0o700)
            shutil.rmtree(destination)
        staging.rename(destination)
    finally:
        if staging.exists(): shutil.rmtree(staging)
    return destination


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: prepare_mobile_source.py MODULE_CACHE GENERATED_SOURCE_DIRECTORY")
    print(prepare_source(sys.argv[1], sys.argv[2]))
