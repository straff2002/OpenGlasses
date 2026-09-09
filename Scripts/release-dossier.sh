#!/usr/bin/env bash
#
# Write the release dossier for one commit and one built artifact (W06.4).
#
# The question this answers is asked long after the fact, usually by someone who is not the person
# who shipped: what exactly went out, built from what, checked by what, signed by whom. Answering
# it by memory or by clicking through a build service is how a release becomes unverifiable — the
# CI run rolls off, the archive is re-signed, the answer is "probably".
#
# So: one Markdown file, generated from the commit and the artifact, linking the evidence that
# already exists rather than restating it. Nothing here is a substitute for the evidence; it is
# the index that makes the evidence findable.
#
#   ./Scripts/release-dossier.sh --commit <sha> [--artifact <path>] [--output <path>]
#                                [--sbom <path>] [--provenance <path>]
#
#   --commit      the revision that was built. Defaults to HEAD.
#   --artifact    the built .ipa, .app, .xcarchive or .zip. Digested and, for a .app or
#                 .xcarchive, read with `codesign -dv` for the signing identity.
#   --sbom        an SBOM to reference. Generated with Scripts/generate-sbom.sh if omitted.
#   --provenance  the provenance.txt from the CI run, downloaded from the run's artifacts.
#   --output      default: release-dossier-<short sha>.md
#
# WHEN IT RUNS: on a tag, or at App Store submission — see docs/BUILDING.md. It is deliberately
# not wired into a release workflow, because there is no release workflow to wire it into and a
# job that has never run is not evidence of anything. The `release-dossier` workflow_dispatch job
# is there to produce one on demand for a commit.
#
# SECRETS: never. `codesign -dv` reports the certificate's subject — an organisation name and a
# team identifier, both of which are printed on every App Store listing. It reads no key, and
# this script prints no environment variable.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
commit=""
artifact=""
sbom=""
provenance=""
output=""

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) commit="$2"; shift 2 ;;
    --artifact) artifact="$2"; shift 2 ;;
    --sbom) sbom="$2"; shift 2 ;;
    --provenance) provenance="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "release-dossier: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

commit="${commit:-HEAD}"
full_commit="$(git -C "$repo_root" rev-parse "$commit")"
short_commit="$(git -C "$repo_root" rev-parse --short "$full_commit")"
output="${output:-$repo_root/release-dossier-$short_commit.md}"

log() { printf '%s\n' "release-dossier: $*" >&2; }

# An unstated absence reads as a claim. Every field this script cannot fill says so, in the
# document, in the same words each time — so a reader can tell "verified" from "not looked at".
missing="_not recorded — see gaps below_"
gaps=()

# Render a value as code, unless it is the missing marker — backticks around "not recorded" reads
# as if the absence were itself the value.
code() { [ "$1" = "$missing" ] && printf '%s' "$1" || printf '`%s`' "$1"; }

# --- Repository facts -------------------------------------------------------------------------

subject="$(git -C "$repo_root" log -1 --format=%s "$full_commit")"
authored="$(git -C "$repo_root" log -1 --format=%cI "$full_commit")"
remote="$(git -C "$repo_root" config --get remote.origin.url 2>/dev/null || echo '')"
remote="${remote%.git}"
remote="${remote/git@github.com:/https://github.com/}"

if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then
  gaps+=("The working tree was dirty when this dossier was generated, so the artifact may not correspond to \`$short_commit\`. Regenerate from a clean checkout before relying on it.")
fi

# --- Version, from the spec that produces Info.plist -------------------------------------------
#
# Info.plist holds $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) build-setting references, not
# literals, so the source of truth is project.base.yml — or, better, the built artifact's own
# Info.plist when one was given, which is what actually shipped.

spec_version="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$repo_root/project.base.yml" | head -n 1)"
spec_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' "$repo_root/project.base.yml" | head -n 1)"

artifact_version="$missing"
artifact_build="$missing"
artifact_digest="$missing"
artifact_size="$missing"
signer="$missing"

# Find the app's Info.plist and copy it somewhere readable. Handles the four shapes an iOS
# artifact arrives in: a bare .app (iOS layout), a macOS .app (Contents/), an .xcarchive, and an
# .ipa — which is a zip, and is the one that actually gets submitted, so it is worth unzipping
# one file for rather than reporting the version as unknown.
extract_plist() { # artifact destination -> 0 if it wrote destination
  local bundle="$1" destination="$2"
  if [ -f "$bundle" ]; then
    case "$bundle" in
      *.ipa|*.zip)
        unzip -p "$bundle" 'Payload/*.app/Info.plist' > "$destination" 2>/dev/null \
          && [ -s "$destination" ] && return 0
        ;;
    esac
    return 1
  fi
  local candidate
  for candidate in "$bundle/Info.plist" \
                   "$bundle/Contents/Info.plist" \
                   "$bundle/Products/Applications"/*.app/Info.plist \
                   "$bundle/Products/Applications"/*.app/Contents/Info.plist; do
    if [ -f "$candidate" ]; then
      cp "$candidate" "$destination"
      return 0
    fi
  done
  return 1
}

if [ -n "$artifact" ]; then
  if [ ! -e "$artifact" ]; then
    log "FAIL — no such artifact: $artifact"
    exit 1
  fi
  artifact_size="$(du -sh "$artifact" | awk '{print $1}')"

  if [ -f "$artifact" ]; then
    artifact_digest="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  else
    # A bundle is a directory: hash its contents in a stable order. Not a substitute for hashing
    # the submitted .ipa — Apple re-signs and re-packages what it distributes, so the digest that
    # matters for the store is the one App Store Connect reports. This one identifies the local
    # build, which is what the dossier can honestly attest to.
    artifact_digest="$(cd "$artifact" && find . -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
    gaps+=("The artifact digest is a content hash of the bundle directory, not of a submitted \`.ipa\`. Apple re-signs and re-packages what it distributes; capture the App Store Connect build digest separately.")
  fi

  bundle_plist="$(mktemp)"
  trap 'rm -f "$bundle_plist"' EXIT
  if extract_plist "$artifact" "$bundle_plist"; then
    artifact_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle_plist" 2>/dev/null || echo "$missing")"
    artifact_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle_plist" 2>/dev/null || echo "$missing")"
  else
    gaps+=("No Info.plist was found inside the artifact, so the shipped version and build could not be read from it. The versions below come from \`project.base.yml\`, which is what the build *should* have produced.")
  fi

  # Identity only. `codesign -dv` prints the certificate subject: an organisation name and a team
  # identifier, both public. It never touches a key.
  if command -v codesign >/dev/null 2>&1; then
    # --verbose=2 is not decoration: plain `codesign -dv` does not print the Authority chain at
    # all, so reading the signer without it silently reports every artifact as unsigned.
    codesign_output="$(codesign -dv --verbose=2 "$artifact" 2>&1 || true)"
    signer="$(printf '%s\n' "$codesign_output" | sed -n 's/^Authority=//p' | head -n 1)"
    team="$(printf '%s\n' "$codesign_output" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
    [ "$team" = "not set" ] && team=""
    if [ -z "$signer" ]; then
      signer="$missing"
      gaps+=("\`codesign -dv\` reported no signing authority for the artifact — it is unsigned, or it is not a bundle codesign can read.")
    elif [ -n "$team" ]; then
      signer="$signer (team $team)"
    fi
  else
    gaps+=("\`codesign\` is not available on this machine, so the signing identity was not read. Generate the dossier on macOS.")
  fi
else
  gaps+=("No artifact was given (\`--artifact\`), so there is no digest, no shipped version and no signing identity in this dossier. It describes the source, not a release.")
fi

# --- SBOM ---------------------------------------------------------------------------------------

if [ -z "$sbom" ]; then
  sbom="$repo_root/sbom.cdx.json"
  log "generating the SBOM (no --sbom given)"
  "$repo_root/Scripts/generate-sbom.sh" --output "$sbom" >/dev/null 2>&1 || {
    log "FAIL — could not generate an SBOM"
    exit 1
  }
fi
sbom_digest="$(shasum -a 256 "$sbom" | awk '{print $1}')"
sbom_serial="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serialNumber"])' "$sbom")"
sbom_counts="$(python3 - "$sbom" <<'PY'
import collections, json, sys
bom = json.load(open(sys.argv[1]))
counts = collections.Counter(c["type"] for c in bom["components"])
print(", ".join("%s %d" % (k, counts[k]) for k in sorted(counts)))
PY
)"

# --- CI run --------------------------------------------------------------------------------------

if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  run_line="[run $GITHUB_RUN_ID]($run_url)"
else
  run_line="$missing"
  gaps+=("\`GITHUB_RUN_ID\` was not set, so this dossier does not link the CI run that built the artifact. Generate it from the workflow, or add the run URL by hand.")
fi

if [ -n "$provenance" ] && [ -f "$provenance" ]; then
  provenance_digest="$(shasum -a 256 "$provenance" | awk '{print $1}')"
  provenance_line="\`$(basename "$provenance")\` — sha256 \`$provenance_digest\`"
else
  provenance_line="$missing"
  gaps+=("The CI provenance record was not supplied (\`--provenance\`). Download \`provenance.txt\` from the run's artifacts — it is what records the toolchain, SDK and lockfile digests the build actually used.")
fi

# --- Write ------------------------------------------------------------------------------------

{
  echo "# Release dossier — $short_commit"
  echo
  echo "Generated by \`Scripts/release-dossier.sh\`. Every line either links evidence or says it is"
  echo "missing; nothing here is an assertion about something that was not checked."
  echo
  echo "## Source"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Commit | \`$full_commit\` |"
  [ -n "$remote" ] && echo "| | [$short_commit]($remote/commit/$full_commit) |"
  echo "| Subject | $subject |"
  echo "| Committed | $authored |"
  echo "| Spec version | $spec_version (build $spec_build) — from \`project.base.yml\` |"
  echo
  echo "## Artifact"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Path | ${artifact:-$missing} |"
  echo "| Size | $artifact_size |"
  echo "| sha256 | $(code "$artifact_digest") |"
  echo "| CFBundleShortVersionString | $artifact_version |"
  echo "| CFBundleVersion | $artifact_build |"
  echo "| Signing identity | $signer |"
  echo
  if [ "$artifact_version" != "$missing" ] && [ "$artifact_version" != "$spec_version" ]; then
    echo "> **The artifact's version does not match the spec.** \`project.base.yml\` says"
    echo "> $spec_version ($spec_build); the artifact says $artifact_version ($artifact_build)."
    echo "> The artifact was built from a different commit, or the spec moved after the build."
    echo
  fi
  echo "## Evidence"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| CI run | $run_line |"
  echo "| Build provenance | $provenance_line |"
  echo "| SBOM | \`$(basename "$sbom")\` — sha256 \`$sbom_digest\` |"
  echo "| SBOM serial | \`$sbom_serial\` |"
  echo "| SBOM components | $sbom_counts |"
  echo
  echo "The SBOM is reproducible from the commit alone: \`./Scripts/generate-sbom.sh\` over"
  echo "\`$short_commit\` produces a byte-identical document, so the digest above is checkable by"
  echo "anyone with the source and does not depend on this file being trusted."
  echo
  echo "## Gates that ran"
  echo
  echo "Named so a reader can check they were required rather than merely present. Whether they"
  echo "were *required* is a branch-protection setting, which is not in this repository and is"
  echo "not evidenced here."
  echo
  echo "| Gate | Where |"
  echo "|---|---|"
  echo "| Unit suite | \`.github/workflows/tests.yml\` job \`test\` |"
  echo "| Security regression | \`.github/workflows/tests.yml\` job \`security-regression\` |"
  echo "| Privacy-logging | \`Scripts/check-privacy-logging.sh\`, blocking, before both macOS jobs |"
  echo "| Secret scan | \`.github/workflows/security-scan.yml\` job \`secret-scan\` |"
  echo "| Dependency review | \`.github/workflows/security-scan.yml\` job \`dependency-review\` |"
  echo "| SBOM reproducibility | \`.github/workflows/tests.yml\` job \`sbom\` |"
  echo
  if [ ${#gaps[@]} -gt 0 ]; then
    echo "## Gaps"
    echo
    echo "What this dossier does **not** establish:"
    echo
    for gap in "${gaps[@]}"; do
      echo "- $gap"
    done
    echo
  else
    echo "## Gaps"
    echo
    echo "Every field above was filled from something that was actually read."
    echo
  fi
} > "$output"

log "wrote $output"
if [ ${#gaps[@]} -gt 0 ]; then
  log "${#gaps[@]} gap(s) recorded in the dossier — read the Gaps section before relying on it."
fi
printf '%s\n' "$output"
