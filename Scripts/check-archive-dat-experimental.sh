#!/usr/bin/env bash
#
# Is this archive a store candidate, or a TestFlight-only build with Meta's experimental glasses
# APIs (Plan JV)? Check the artefact, not the source: a project regenerated after the archive was
# made says nothing about what the archive contains.
#
# Usage: Scripts/check-archive-dat-experimental.sh <path.xcarchive | path.app>
#
# Reads the archived app's Info.plist stamp (`AvenkinDATExperimental`, `YES` only in a project
# generated with AVENKIN_DAT_EXPERIMENTAL=1) and looks for Meta's experimental modules in the app:
# an embedded `Frameworks/MWDAT{Inputs,Motion,Speech}.framework`, or a load command for one in the
# main executable. `MWDATInputs` is what the experimental spec links, so it is the marker.
#
# Prints STORE-SAFE (stamp NO, no experimental module) or TESTFLIGHT ONLY — DO NOT SUBMIT (stamp
# YES, module present) and exits 0. Exits 1 when the two disagree or the stamp is neither YES nor
# NO, and 2 when the path is not an archive or app.
set -uo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <path.xcarchive | path.app>" >&2
  exit 2
fi
target="${1%/}"

if [[ "$target" == *.app ]]; then
  app="$target"
else
  apps=()
  for candidate in "$target"/Products/Applications/*.app; do
    [[ -d "$candidate" ]] && apps+=("$candidate")
  done
  if [[ ${#apps[@]} -ne 1 ]]; then
    echo "error: expected one app under $target/Products/Applications, found ${#apps[@]}" >&2
    exit 2
  fi
  app="${apps[0]}"
fi
if [[ ! -f "$app/Info.plist" ]]; then
  echo "error: $app has no Info.plist" >&2
  exit 2
fi

stamp="$(/usr/libexec/PlistBuddy -c "Print :AvenkinDATExperimental" "$app/Info.plist" 2>/dev/null || echo "absent")"

modules=()
for module in MWDATInputs MWDATMotion MWDATSpeech; do
  if [[ -d "$app/Frameworks/$module.framework" ]]; then
    modules+=("$module (embedded)")
  fi
done
executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Info.plist" 2>/dev/null || true)"
if [[ -n "$executable" && -f "$app/$executable" ]] && command -v otool >/dev/null 2>&1; then
  for module in MWDATInputs MWDATMotion MWDATSpeech; do
    if otool -L "$app/$executable" 2>/dev/null | grep -q "/$module.framework/"; then
      modules+=("$module (linked)")
    fi
  done
fi

echo "App: $app"
echo "Stamp (AvenkinDATExperimental): $stamp"
if [[ ${#modules[@]} -eq 0 ]]; then
  echo "Experimental modules: none"
else
  echo "Experimental modules: ${modules[*]}"
fi

case "$stamp" in
  NO)
    if [[ ${#modules[@]} -eq 0 ]]; then
      echo "STORE-SAFE"
      exit 0
    fi
    echo "error: the stamp says NO but the app carries an experimental module. Do not submit; regenerate without AVENKIN_DAT_EXPERIMENTAL and archive again." >&2
    exit 1
    ;;
  YES)
    if [[ ${#modules[@]} -gt 0 ]]; then
      echo "TESTFLIGHT ONLY — DO NOT SUBMIT"
      exit 0
    fi
    echo "error: the stamp says YES but no experimental module is in the app. Do not submit; the archive is not what its stamp says." >&2
    exit 1
    ;;
  *)
    echo "error: the stamp is '$stamp', not YES or NO: this archive was not made from a generated project that stamps it." >&2
    exit 1
    ;;
esac
