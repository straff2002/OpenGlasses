#!/bin/bash
# Release listener containment — artefact check (roadmap W02.1).
#
# Usage: Scripts/check-release-listener-strings.sh <path to built .app>
#
# The composition tests prove the Release policy path never constructs a listener in *source*.
# This is the other half of the evidence: it inspects a built artefact and fails if a literal that
# can only be compiled into a build capable of opening the legacy cleartext LAN transport is
# present. It is deliberately two-sided — required literals as well as forbidden ones — so a check
# that finds nothing (wrong path, stripped binary, unexpected encoding) cannot pass silently.
#
# This is the headless half. Inspecting a signed artefact installed on a device is still owed.

set -u -o pipefail

app="${1:-}"
if [[ -z "$app" ]]; then
    echo "usage: $0 <path to built .app>" >&2
    exit 2
fi
if [[ ! -d "$app" ]]; then
    echo "not a bundle: $app" >&2
    exit 2
fi

name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist" 2>/dev/null || basename "$app" .app)"
binary="$app/$name"
if [[ ! -f "$binary" ]]; then
    echo "no Mach-O executable at $binary" >&2
    exit 2
fi

echo "artefact:  $binary"
echo "size:      $(stat -f%z "$binary") bytes"
echo "sha256:    $(shasum -a 256 "$binary" | awk '{print $1}')"
echo "arch:      $(lipo -archs "$binary" 2>/dev/null || echo unknown)"
echo

# Literals that must be ABSENT. Each one is only compiled into a build that can actually open the
# transport it names, so its presence in a Release artefact means the containment did not hold.
#
#  - mcp-glasses-legacy-cleartext-listener-debug-only / web-hud-mirror-...: carried on the
#    LocalListenerHandle the production factory returns, which only exists inside the `#if DEBUG`
#    branch of LocalListenerProvider.production. Present only if the socket-opening branch was
#    compiled in. One literal per service, so the check says which transport leaked.
#  - internalSkillPack: the Debug-only private-HTTP BoundedHTTPClient profile (the marker the
#    earlier W02.4 checkpoint already relies on). It is unrelated to the listeners, which is the
#    point: it independently confirms this really is a Release-configuration artefact, so an absent
#    listener marker is containment rather than a Debug build that happens to lack it.
forbidden=(
    "mcp-glasses-legacy-cleartext-listener-debug-only"
    "web-hud-mirror-legacy-cleartext-listener-debug-only"
    "internalSkillPack"
)

# Literals that must be PRESENT — positive controls.
#
#  - release-refuses-legacy-cleartext-listener: the marker on the refusal the Release-only branch of
#    LocalListenerProvider.production throws. Its presence proves the refusing branch is the one
#    that shipped, not that the whole feature was optimized away unnoticed.
#  - qrContext: a public BoundedHTTPClient profile compiled into every configuration. Proves the
#    string extraction itself works on this binary, so the absences above mean something.
required=(
    "release-refuses-legacy-cleartext-listener"
    "qrContext"
)

symbols="$(strings -a - "$binary" 2>/dev/null)"
status=0

for literal in "${forbidden[@]}"; do
    if grep -qF -- "$literal" <<< "$symbols"; then
        echo "FAIL  present but must be absent: $literal"
        status=1
    else
        echo "ok    absent: $literal"
    fi
done

for literal in "${required[@]}"; do
    if grep -qF -- "$literal" <<< "$symbols"; then
        echo "ok    present: $literal"
    else
        echo "FAIL  missing positive control: $literal"
        status=1
    fi
done

echo
if [[ $status -eq 0 ]]; then
    echo "PASS  no Debug-only listener literal in this artefact"
else
    echo "FAIL  Release listener containment not evidenced by this artefact"
fi
exit $status
