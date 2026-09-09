#!/usr/bin/env bash
#
# Stage the public website into _site/ from an explicit allowlist (W06.3).
#
# The Pages workflow used to upload `path: .` — the entire checkout. That publishes whatever
# happens to be in the tree at the time, which for this repository includes compliance evidence
# (plans/, docs/plans/), signing material (Config/), vendored binaries and every line of source.
# Nothing had leaked, but the artifact's contents were decided by `.gitignore` rather than by
# anyone's judgement, and the next internal file added to the repo would have been published
# without a diff to review.
#
# So: copy an explicit list, then *independently* refuse to publish a staged tree that contains
# anything from a denied path. The second half is the point. An allowlist alone fails silently
# when someone adds a directory to it without thinking; the denylist runs over the staged listing
# and knows nothing about how that listing was produced, so a future allowlist mistake still
# stops the deploy instead of shipping.
#
# Usage:
#   Scripts/stage-pages-site.sh [output-dir]     # default: <repo>/_site
#
# Exit status is nonzero if an allowlisted path is missing (the site is incomplete) or if the
# staged tree contains a denied path (the site is over-broad). Either way the deploy should stop.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo_root/_site}"

# --- allowlist ------------------------------------------------------------------------------------
#
# Derived from what the site actually serves:
#   index.html                          the Meta auth redirect page (self-contained: no external
#                                       CSS, script or image references — checked)
#   .well-known/apple-app-site-association   the Universal Link association iOS fetches
#   .nojekyll                           keeps the dot-directory above from being dropped
#   _config.yml                         retained from the pre-staging setup; inert while
#                                       .nojekyll is present, harmless, and one less difference
#   LICENSE, README*.md, docs/*         the public documentation the READMEs link to
#
# Deliberately absent: docs/plans/ and plans/ (internal planning and compliance evidence),
# skillpacks/ and vaultpacks/ (README links there will 404 — they are development material, not
# website), docs/webrtc/signaling-server.js (server source, not a page asset).
ALLOW=(
  index.html
  _config.yml
  .nojekyll
  .well-known/apple-app-site-association
  LICENSE
  README.md
  README.zh-CN.md
  docs/BUILDING.md
  docs/CAPABILITIES.md
  docs/cross-vendor-ai-glasses-research.md
  docs/field-assist-vault-guide.md
  docs/field-assist-vault-guide.pdf
  docs/opportunity-assessment.md
  docs/skillpack-authoring.md
  docs/webrtc/expert-client.html
)

# --- denylist -------------------------------------------------------------------------------------
#
# Globs matched against each staged path, relative to the output directory. Anything that matches
# fails the run. Kept broader than the allowlist needs so it stays meaningful as the allowlist
# grows: these are the shapes that must never reach a public artifact regardless of who added them.
DENY=(
  # Internal planning and compliance evidence
  'plans/*' 'docs/plans/*' '*/plans/*'
  # Credentials, signing material and configuration overlays
  'secrets/*' 'Config/*' '.env' '.env.*' '*/.env' '*/.env.*'
  '*.key' '*.crt' '*.pem' '*.p12' '*.p8' '*.cer' '*.mobileprovision'
  '*.keystore' '*.jks' 'id_rsa*' '*.entitlements'
  # Source, tests and project specification
  'OpenGlasses/*' 'OpenGlassesTests/*' 'OpenGlassesUITests/*'
  'OpenGlassesWatch/*' 'OpenGlassesWatchWidget/*' 'OpenGlassesShareExtension/*'
  'GlassesActivityWidget/*' 'Vendor/*' 'Scripts/*' 'ci_scripts/*'
  'examples/*' 'skillpacks/*' 'vaultpacks/*'
  '.github/*' '.claude/*' '.git/*'
  'project.yml' 'project.*.yml' 'Package.swift' 'Package.resolved' 'ExportOptions.plist'
  '*.swift' '*.pbxproj' '*.xcworkspacedata'
  # Build products
  '*.xcodeproj/*' '*.xcarchive/*' '*.app/*' '*.dSYM/*' '*.xcresult/*'
  'build/*' '.build/*' 'DerivedData/*' '.ci-tools/*' '.spm-checkouts/*'
  '*.ipa' '*.o' '*.a' '*.dylib' '*.framework/*' '*.xcframework/*'
)

# --- stage ----------------------------------------------------------------------------------------

echo "stage-pages-site: staging into $out"
rm -rf "$out"
mkdir -p "$out"

missing=0
for rel in "${ALLOW[@]}"; do
  src="$repo_root/$rel"
  if [ ! -e "$src" ]; then
    echo "stage-pages-site: MISSING allowlisted path '$rel'" >&2
    missing=1
    continue
  fi
  mkdir -p "$out/$(dirname "$rel")"
  cp -R "$src" "$out/$rel"
done

if [ "$missing" -ne 0 ]; then
  echo "stage-pages-site: FAIL — allowlist names paths that are not in the tree." >&2
  echo "  Either the file moved (update the allowlist) or the checkout is incomplete." >&2
  exit 1
fi

# --- gate -----------------------------------------------------------------------------------------
#
# Runs over what was actually staged, not over ALLOW. If the copy step above ever stages more than
# it should — a directory entry that pulled in siblings, an allowlist line added without thought —
# this is what notices.

violations=0
while IFS= read -r path; do
  rel="${path#"$out"/}"
  [ "$rel" = "$out" ] && continue
  for pat in "${DENY[@]}"; do
    # shellcheck disable=SC2053  # deliberate glob match, not a string comparison
    if [[ "$rel" == $pat ]]; then
      echo "stage-pages-site: DENIED '$rel' (matches '$pat')" >&2
      violations=$((violations + 1))
      break
    fi
  done
done < <(find "$out" -mindepth 1 \( -type f -o -type l \) | sort)

staged_count=$(find "$out" -mindepth 1 \( -type f -o -type l \) | wc -l | tr -d ' ')

if [ "$violations" -ne 0 ]; then
  echo "stage-pages-site: FAIL — $violations denied path(s) in the staged site." >&2
  echo "  Publishing is blocked. Remove them from the allowlist, or, if a path really is meant" >&2
  echo "  to be public, say so by narrowing the DENY entry deliberately in this script." >&2
  exit 1
fi

if [ "$staged_count" -eq 0 ]; then
  echo "stage-pages-site: FAIL — nothing staged." >&2
  exit 1
fi

echo "stage-pages-site: PASS — $staged_count file(s) staged, no denied paths."
find "$out" -mindepth 1 -maxdepth 2 | sed "s|^$out|  _site|" | sort
