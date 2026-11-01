#!/bin/sh
set -eu
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

# App Store and TestFlight archives are separate builds. Inspect the actual artifact,
# rather than inferring its contents from workflow names or installation receipts.
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] && [ -n "${CI_ARCHIVE_PATH:-}" ]; then
  for app in "$CI_ARCHIVE_PATH"/Products/Applications/*.app; do
    variant=$(/usr/libexec/PlistBuddy -c 'Print :AvenkinBuildVariant' "$app/Info.plist")
    case "$variant" in
      phone-only)
        python3 Scripts/check-phone-only-artifact.py --require-signed "$CI_ARCHIVE_PATH"
        ;;
      glasses-beta)
        if [ "${OPENGLASSES_PHONE_ONLY:-${OPENGLASSES_NO_GLASSES_SDK:-0}}" = "1" ]; then
          echo 'Phone-only workflow produced a glasses-beta archive; refusing artifact.' >&2
          exit 1
        fi
        echo 'Glasses beta archive: distribute to TestFlight; do not select for phone-only App Review.'
        ;;
      *) echo 'Archive has no recognized build variant; refusing artifact.' >&2; exit 1 ;;
    esac
  done
fi
