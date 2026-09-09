#!/usr/bin/env bash
#
# Generate a CycloneDX 1.5 SBOM for a release (W06.4).
#
# What this answers: months after a build, which third-party code, which vendored binaries, which
# build tools and which model weights went into it — with a digest wherever one exists. The
# provenance record the test workflow writes says what the machine was; this says what the
# software was.
#
# Offline by construction. Every input is a file already in the repository, because an SBOM that
# needs the network to be produced cannot be produced for an old commit, which is exactly when
# anyone wants one.
#
# Inputs, all authoritative rather than convenient:
#   ci_scripts/Package.resolved                       SwiftPM graph the build compiles (not the
#                                                     root Package.resolved — see docs/BUILDING.md)
#   Vendor/*/REVISION, Vendor/*/SHA256SUMS            vendored engine pins and file digests
#   Scripts/fetch-mediapipe-frameworks.sh             MediaPipe archive URLs and sha256
#   Scripts/xcodegen-pin.env, Scripts/gitleaks-pin.env  verified build/scan tooling
#   OpenGlasses/Sources/Resources/LocalModelCatalog.json  GGUF models: revision + per-file sha256
#   ASRModelBundle.swift, KokoroModelBundle.swift,    model repositories declared in source
#   Config.swift, LocalModelCatalog.swift
#
# DETERMINISM is a property of this script, not an accident: the same commit produces a
# byte-identical SBOM, so two runs can be compared and a diff means an input actually moved.
# There is no wall-clock time and no random serial number anywhere in the output. The timestamp
# is HEAD's committer date (or $SOURCE_DATE_EPOCH if set) and the serial number is derived from
# the component list by hash. .github/workflows/tests.yml runs it twice and diffs.
#
# Usage:
#   ./Scripts/generate-sbom.sh [--output PATH]      # default: sbom.cdx.json
#
# Extraction from Swift sources is anchored and ASSERTED: a pattern that stops matching is a hard
# error, never a silently smaller SBOM. A manifest that quietly loses a component is worse than
# no manifest, because it is believed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$repo_root/sbom.cdx.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "generate-sbom: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# HEAD's committer date, so the SBOM for a given commit is the same document every time it is
# generated. SOURCE_DATE_EPOCH wins if the caller sets it (the reproducible-builds convention).
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH="$(git -C "$repo_root" log -1 --format=%ct 2>/dev/null || echo 0)"
fi
export SOURCE_DATE_EPOCH

SBOM_REPO_ROOT="$repo_root" SBOM_OUTPUT="$output" python3 - <<'PYEOF'
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

root = os.environ["SBOM_REPO_ROOT"]
out_path = os.environ["SBOM_OUTPUT"]


def die(message):
    sys.stderr.write("generate-sbom: %s\n" % message)
    raise SystemExit(1)


def read(relative, required=True):
    path = os.path.join(root, relative)
    if not os.path.exists(path):
        if required:
            die("missing input %s" % relative)
        return None
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def key_values(text):
    """`key=value` lines, `#` comments ignored — the Vendor/*/REVISION and *-pin.env shape."""
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    return values


def one(pattern, text, what):
    """Exactly-one anchored extraction. A pattern that stops matching is an error, not a shrug."""
    found = re.findall(pattern, text, re.MULTILINE)
    if not found:
        die("could not find %s — the source moved and this script must be updated, "
            "rather than quietly emitting an SBOM that is missing it" % what)
    return found


def git(*args):
    try:
        return subprocess.check_output(["git", "-C", root] + list(args),
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return None


components = []


def add(component):
    components.append(component)


# --- The subject of the SBOM ------------------------------------------------------------------

spec = read("project.base.yml")
marketing = one(r'^\s*MARKETING_VERSION:\s*"([^"]+)"', spec, "MARKETING_VERSION in project.base.yml")[0]
build_number = one(r'^\s*CURRENT_PROJECT_VERSION:\s*"([^"]+)"', spec, "CURRENT_PROJECT_VERSION in project.base.yml")[0]
commit = git("rev-parse", "HEAD") or "unknown"

subject = {
    "type": "application",
    "bom-ref": "openglasses",
    "name": "OpenGlasses",
    "version": "%s (%s)" % (marketing, build_number),
    "description": "iOS app for Meta smart glasses.",
    "properties": [
        {"name": "openglasses:commit", "value": commit},
        {"name": "openglasses:marketing-version", "value": marketing},
        {"name": "openglasses:build", "value": build_number},
    ],
}

# --- SwiftPM graph ----------------------------------------------------------------------------
#
# ci_scripts/Package.resolved, not the root one: this is the lockfile both CI paths copy into the
# generated project and compile against. The root pair is a secondary manifest that nothing
# builds, and is measurably behind — see docs/BUILDING.md.

resolved = json.loads(read("ci_scripts/Package.resolved"))
pins = resolved.get("pins", [])
if not pins:
    die("ci_scripts/Package.resolved has no pins")

for pin in pins:
    identity = pin["identity"]
    location = pin["location"].rstrip("/")
    state = pin.get("state", {})
    revision = state.get("revision")
    version = state.get("version")

    # purl requires a version. A revision-only pin (mlx-swift-lm is pinned to a commit on purpose;
    # see project.base.yml) gets the revision in the version field and no purl, rather than a purl
    # that asserts a release that does not exist.
    repo_path = re.sub(r"^https?://", "", location)
    repo_path = re.sub(r"\.git$", "", repo_path)
    purl = "pkg:swift/%s@%s" % (repo_path, version) if version else None

    component = {
        "type": "library",
        "bom-ref": "swiftpm/%s" % identity,
        "name": identity,
        "version": version or revision or "unpinned",
        "externalReferences": [{"type": "vcs", "url": location}],
        "properties": [{"name": "openglasses:source", "value": "ci_scripts/Package.resolved"}],
    }
    if purl:
        component["purl"] = purl
    if revision:
        component["properties"].append({"name": "openglasses:revision", "value": revision})
    if not version:
        component["properties"].append(
            {"name": "openglasses:pin-kind", "value": "revision (no released tag carries the fix)"})
    add(component)

# --- Vendored binaries ------------------------------------------------------------------------
#
# llama.cpp: built from a pinned commit, digests in SHA256SUMS. The static library's own digest is
# a real artifact hash and is recorded as one; the SHA256SUMS digest covers the rest.

llama_revision = key_values(read("Vendor/LlamaCpp/REVISION"))
llama_sums_text = read("Vendor/LlamaCpp/SHA256SUMS")
llama_entries = [line.split() for line in llama_sums_text.splitlines() if line.strip()]
device_lib = [digest for digest, path in llama_entries if path.endswith("ios-arm64/libllama.a")]
if not device_lib:
    die("Vendor/LlamaCpp/SHA256SUMS has no ios-arm64/libllama.a entry")

add({
    "type": "library",
    "bom-ref": "vendor/llama.cpp",
    "name": "llama.cpp",
    "version": llama_revision.get("tag", "unknown"),
    "externalReferences": [{"type": "vcs", "url": llama_revision.get("repository", "")}],
    "hashes": [{"alg": "SHA-256", "content": device_lib[0]}],
    "properties": [
        {"name": "openglasses:revision", "value": llama_revision.get("commit", "")},
        {"name": "openglasses:hashed-artifact", "value": "Frameworks/llama.xcframework/ios-arm64/libllama.a"},
        {"name": "openglasses:sha256sums-entries", "value": str(len(llama_entries))},
        {"name": "openglasses:sha256sums-digest",
         "value": hashlib.sha256(llama_sums_text.encode()).hexdigest()},
        {"name": "openglasses:acquisition", "value": "built from source; not committed"},
    ],
})

# sherpa-onnx + onnxruntime: committed binaries, so the digest of record is the git tree the
# commit carries. Recorded as a property, not as a `hashes` entry — a git tree object id is not a
# file hash and would be wrong under any of CycloneDX's algorithms.
sherpa = key_values(read("Vendor/SherpaOnnx/REVISION"))
sherpa_tree = git("rev-parse", "HEAD:Vendor/SherpaOnnx/Frameworks")
for name, version_key, license_key, url in [
    ("sherpa-onnx", "sherpa_onnx_version", "sherpa_onnx_license", "https://github.com/k2-fsa/sherpa-onnx"),
    ("onnxruntime", "onnxruntime_version", "onnxruntime_license", "https://github.com/microsoft/onnxruntime"),
]:
    if version_key not in sherpa:
        die("Vendor/SherpaOnnx/REVISION has no %s" % version_key)
    component = {
        "type": "library",
        "bom-ref": "vendor/%s" % name,
        "name": name,
        "version": sherpa[version_key],
        "externalReferences": [{"type": "vcs", "url": url}],
        "properties": [
            {"name": "openglasses:acquisition", "value": "prebuilt xcframework, committed"},
            {"name": "openglasses:source", "value": "Vendor/SherpaOnnx/REVISION"},
        ],
    }
    if license_key in sherpa:
        component["licenses"] = [{"license": {"id": sherpa[license_key]}}]
    if sherpa_tree:
        component["properties"].append(
            {"name": "openglasses:git-tree", "value": "Vendor/SherpaOnnx/Frameworks=%s" % sherpa_tree})
    add(component)

# MediaPipe Tasks: fetched, not committed. The two distribution archives and their sha256 are the
# pin, and they live in the fetch script — the only place they exist.
mediapipe = read("Scripts/fetch-mediapipe-frameworks.sh")
mp_version = one(r'^VERSION="([^"]+)"', mediapipe, "VERSION in fetch-mediapipe-frameworks.sh")[0]
for label, url_var, sha_var in [
    ("MediaPipeTasksVision", "VISION_URL", "VISION_SHA256"),
    ("MediaPipeTasksCommon", "COMMON_URL", "COMMON_SHA256"),
]:
    url = one(r'^%s="([^"]+)"' % url_var, mediapipe, "%s in fetch-mediapipe-frameworks.sh" % url_var)[0]
    digest = one(r'^%s="([0-9a-f]{64})"' % sha_var, mediapipe,
                 "%s in fetch-mediapipe-frameworks.sh" % sha_var)[0]
    add({
        "type": "library",
        "bom-ref": "vendor/%s" % label.lower(),
        "name": label,
        "version": mp_version,
        "externalReferences": [{"type": "distribution", "url": url.replace("${VERSION}", mp_version)}],
        "hashes": [{"alg": "SHA-256", "content": digest}],
        "properties": [
            {"name": "openglasses:acquisition", "value": "fetched at build time; not committed"},
            {"name": "openglasses:source", "value": "Scripts/fetch-mediapipe-frameworks.sh"},
        ],
    })

# --- Verified build and scan tooling ----------------------------------------------------------

xcodegen = key_values(read("Scripts/xcodegen-pin.env"))
add({
    "type": "application",
    "bom-ref": "tool/xcodegen",
    "name": "XcodeGen",
    "version": xcodegen["XCODEGEN_VERSION"],
    "externalReferences": [{"type": "distribution",
                            "url": xcodegen["XCODEGEN_URL"].replace(
                                "${XCODEGEN_VERSION}", xcodegen["XCODEGEN_VERSION"])}],
    "hashes": [{"alg": "SHA-256", "content": xcodegen["XCODEGEN_SHA256"]}],
    "properties": [{"name": "openglasses:role", "value": "build tool — writes the project every build compiles"}],
})

gitleaks = key_values(read("Scripts/gitleaks-pin.env"))
add({
    "type": "application",
    "bom-ref": "tool/gitleaks",
    "name": "gitleaks",
    "version": gitleaks["GITLEAKS_VERSION"],
    "externalReferences": [{"type": "distribution", "url": gitleaks["GITLEAKS_BASE_URL"].replace(
        "${GITLEAKS_VERSION}", gitleaks["GITLEAKS_VERSION"])}],
    "hashes": [
        {"alg": "SHA-256", "content": gitleaks["GITLEAKS_SHA256_linux_x64"]},
        {"alg": "SHA-256", "content": gitleaks["GITLEAKS_SHA256_darwin_arm64"]},
    ],
    "properties": [{"name": "openglasses:role", "value": "release gate — secret scanning"}],
})

# --- Models -----------------------------------------------------------------------------------
#
# Model weights are a supply chain like any other, and a less examined one: they are downloaded
# after install, from a third-party host, and they decide what the app says. Where a revision and
# per-file digests exist they are recorded; where they do not, the component says so rather than
# leaving the reader to assume.

catalog = json.loads(read("OpenGlasses/Sources/Resources/LocalModelCatalog.json"))
if not catalog.get("models"):
    die("LocalModelCatalog.json has no models")
for model in catalog["models"]:
    files = model.get("files", [])
    hashes = [{"alg": "SHA-256", "content": f["sha256"]} for f in files if f.get("sha256")]
    component = {
        "type": "machine-learning-model",
        "bom-ref": "model/gguf/%s" % model["id"],
        "name": model["repositoryID"],
        "version": model.get("revision", "unpinned"),
        "description": model.get("displayName", ""),
        "externalReferences": [{"type": "distribution",
                                "url": "https://huggingface.co/%s" % model["repositoryID"]}],
        "properties": [
            {"name": "openglasses:runtime", "value": "llama.cpp (GGUF)"},
            {"name": "openglasses:quantization", "value": model.get("quantization", "")},
            {"name": "openglasses:artifact", "value": ", ".join(f["relativePath"] for f in files)},
            {"name": "openglasses:source",
             "value": "OpenGlasses/Sources/Resources/LocalModelCatalog.json"},
        ],
    }
    if hashes:
        component["hashes"] = hashes
    licence = model.get("license", {}).get("displayName")
    if licence:
        component["licenses"] = [{"license": {"name": licence}}]
    add(component)

# Model repositories declared in Swift. These are fetched whole by repository id with no revision
# pinning and no recorded digests — LocalModelCatalog.swift says so in as many words — so the
# components record the gap instead of implying a pin that is not there.
unpinned = "no revision pin and no recorded digest; fetched from the repository head"

asr = read("OpenGlasses/Sources/Services/ASR/ASRModelBundle.swift")
asr_repo = one(r'huggingFaceRepo:\s*"([^"]+)"', asr, "huggingFaceRepo in ASRModelBundle.swift")[0]
add({
    "type": "machine-learning-model",
    "bom-ref": "model/asr/%s" % asr_repo,
    "name": asr_repo,
    "version": "unpinned",
    "description": "SenseVoice int8 speech recognition (zh/en/ja/ko/yue).",
    "externalReferences": [{"type": "distribution", "url": "https://huggingface.co/%s" % asr_repo}],
    "properties": [
        {"name": "openglasses:runtime", "value": "sherpa-onnx"},
        {"name": "openglasses:pin-gap", "value": unpinned},
        {"name": "openglasses:source", "value": "OpenGlasses/Sources/Services/ASR/ASRModelBundle.swift"},
    ],
})

kokoro = read("OpenGlasses/Sources/Services/TTS/KokoroModelBundle.swift")
kokoro_repo = one(r'huggingFaceRepo:\s*"([^"]+)"', kokoro, "huggingFaceRepo in KokoroModelBundle.swift")[0]
kokoro_archive = one(r'gitHubArchiveURL:\s*URL\(string:\s*"([^"]+)"',
                     kokoro, "gitHubArchiveURL in KokoroModelBundle.swift")[0]
add({
    "type": "machine-learning-model",
    "bom-ref": "model/tts/%s" % kokoro_repo,
    "name": kokoro_repo,
    "version": "unpinned",
    "description": "Kokoro int8 multilingual text-to-speech.",
    "externalReferences": [
        {"type": "distribution", "url": "https://huggingface.co/%s" % kokoro_repo},
        {"type": "distribution", "url": kokoro_archive},
    ],
    "properties": [
        {"name": "openglasses:runtime", "value": "sherpa-onnx"},
        {"name": "openglasses:pin-gap", "value": unpinned},
        {"name": "openglasses:source", "value": "OpenGlasses/Sources/Services/TTS/KokoroModelBundle.swift"},
    ],
})

config = read("OpenGlasses/Sources/Utils/Config.swift")
fingerspelling_repo = one(r'fingerspellingModelRepoDefault\s*=\s*"([^"]+)"',
                          config, "fingerspellingModelRepoDefault in Config.swift")[0]
add({
    "type": "machine-learning-model",
    "bom-ref": "model/fingerspelling/%s" % fingerspelling_repo,
    "name": fingerspelling_repo,
    "version": "unpinned",
    "description": "Fingerspelling CTC recogniser (Core ML) plus its hand landmarker task.",
    "externalReferences": [{"type": "distribution",
                            "url": "https://huggingface.co/%s" % fingerspelling_repo}],
    "properties": [
        {"name": "openglasses:runtime", "value": "Core ML + MediaPipe Tasks"},
        {"name": "openglasses:pin-gap", "value": unpinned},
        {"name": "openglasses:overridable",
         "value": "repository is a user setting; this is the shipped default"},
        {"name": "openglasses:source", "value": "OpenGlasses/Sources/Utils/Config.swift"},
    ],
})

mlx_source = read("OpenGlasses/Sources/Services/LocalInference/LocalModelCatalog.swift")
mlx_ids = sorted(set(one(r'entry\(id:\s*"([^"]+)"', mlx_source, "entry(id:) in LocalModelCatalog.swift")))
for model_id in mlx_ids:
    add({
        "type": "machine-learning-model",
        "bom-ref": "model/mlx/%s" % model_id,
        "name": model_id,
        "version": "unpinned",
        "externalReferences": [{"type": "distribution", "url": "https://huggingface.co/%s" % model_id}],
        "properties": [
            {"name": "openglasses:runtime", "value": "MLX"},
            {"name": "openglasses:pin-gap", "value": unpinned},
            {"name": "openglasses:source",
             "value": "OpenGlasses/Sources/Services/LocalInference/LocalModelCatalog.swift"},
        ],
    })

# --- Assemble ---------------------------------------------------------------------------------

components.sort(key=lambda c: (c["type"], c["bom-ref"]))

timestamp = datetime.fromtimestamp(int(os.environ["SOURCE_DATE_EPOCH"]), timezone.utc) \
    .strftime("%Y-%m-%dT%H:%M:%SZ")

# A random serialNumber would make every run differ, which would defeat the determinism check
# this document exists to support. Derive it from the component list instead: same inputs, same
# serial; changed inputs, changed serial.
digest = hashlib.sha256(
    json.dumps(components, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
serial = "urn:uuid:%s-%s-%s-%s-%s" % (
    digest[0:8], digest[8:12], digest[12:16], digest[16:20], digest[20:32])

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": serial,
    "version": 1,
    "metadata": {
        "timestamp": timestamp,
        "tools": {
            "components": [{
                "type": "application",
                "name": "generate-sbom.sh",
                "version": "1",
                "description": "Scripts/generate-sbom.sh — hand-assembled from in-repo pins, offline.",
            }],
        },
        "component": subject,
        "properties": [
            {"name": "openglasses:timestamp-source",
             "value": "SOURCE_DATE_EPOCH or HEAD committer date — never wall clock"},
            {"name": "openglasses:deterministic",
             "value": "byte-identical for a given commit; regenerate and diff to verify"},
        ],
    },
    "components": components,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(bom, handle, indent=2, sort_keys=True)
    handle.write("\n")

counts = {}
for component in components:
    counts[component["type"]] = counts.get(component["type"], 0) + 1
sys.stderr.write("generate-sbom: wrote %s\n" % out_path)
sys.stderr.write("generate-sbom: %d components — %s\n" % (
    len(components), ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items()))))
with_hashes = sum(1 for c in components if c.get("hashes"))
sys.stderr.write("generate-sbom: %d of %d carry a digest\n" % (with_hashes, len(components)))
PYEOF
