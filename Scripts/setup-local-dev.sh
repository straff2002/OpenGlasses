#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Last commit that still tracked OpenGlasses.xcodeproj (with DEVELOPMENT_TEAM + entitlements),
# i.e. the merge right before the XcodeGen migration. `--from-commit` recovers personal
# signing config from here. Stays valid permanently (git history is immutable).
DEFAULT_COMMIT=4a7011f70ab74c2ad5924aadb39b1cae357243be

development_team_from_commit() {
  local commit="$1"
  git show "$commit:OpenGlasses.xcodeproj/project.pbxproj" 2>/dev/null \
    | grep 'DEVELOPMENT_TEAM =' \
    | sed 's/.*= //;s/;//' \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -1 \
    | awk '{print $2}'
}

# Read a build setting's value out of the EXISTING project.local.yml so rewriting the file
# never destroys it. The Meta DAT credentials live only here (gitignored); losing them on a
# re-run silently stalls registration below state 3, which presents as "Connect does nothing"
# and a camera permission prompt that never fires — a full debugging session, twice.
existing_local_setting() {
  local key="$1"
  [ -f project.local.yml ] || return 0
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" project.local.yml | head -1 | tr -d '"'
}

write_project_local_yml() {
  local team="$1"
  local app_bundle="${2:-com.openglasses.app}"
  local widget_bundle="${3:-com.openglasses.app.GlassesActivityWidget}"

  # Carry existing credentials across the rewrite; fall back to a commented template.
  local meta_app_id client_token_hash mwdat_block
  meta_app_id="$(existing_local_setting MWDAT_META_APP_ID)"
  client_token_hash="$(existing_local_setting MWDAT_CLIENT_TOKEN_HASH)"
  if [ -n "$meta_app_id" ] && [ -n "$client_token_hash" ]; then
    mwdat_block="        MWDAT_META_APP_ID: \"${meta_app_id}\"
        MWDAT_CLIENT_TOKEN_HASH: \"${client_token_hash}\""
    echo "  Preserved existing Meta DAT credentials (MWDAT_META_APP_ID / MWDAT_CLIENT_TOKEN_HASH)"
  else
    mwdat_block="        # Meta DAT credentials from developers.meta.com. Without these the app builds
        # and launches, but registration never reaches the state that unlocks the camera
        # permission prompt — uncomment and fill in, then re-run generate-xcodeproj.sh:
        #   MWDAT_META_APP_ID: \"<your Meta app id>\"
        #   MWDAT_CLIENT_TOKEN_HASH: \"<hash after the second | of your client token>\""
    echo "  No Meta DAT credentials found — project.local.yml has a commented template to fill in"
  fi

  cat > project.local.yml <<EOF
options:
  developmentTeam: ${team}

targets:
  OpenGlasses:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/OpenGlasses.entitlements
        DEVELOPMENT_TEAM: ${team}
        PRODUCT_BUNDLE_IDENTIFIER: ${app_bundle}
        # The app always builds from the committed OpenGlasses/Info.plist, so new
        # usage-description keys can never go stale in a personal copy (that caused an
        # App Store ITMS-90683 "missing NSLocationAlwaysAndWhenInUseUsageDescription").
        # Secrets ride in as build settings substituted into that plist's MWDAT dict, so
        # there is no personal-plist copy to drift. Never override INFOPLIST_FILE here.
${mwdat_block}

  GlassesActivityWidget:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/GlassesActivityWidget.entitlements
        DEVELOPMENT_TEAM: ${team}
        PRODUCT_BUNDLE_IDENTIFIER: ${widget_bundle}

  # The remaining signed targets need a team as well, or a command-line device build fails on
  # them ("Signing for X requires a development team"). Xcode's GUI hides this by filling the
  # team in automatically, so the gap only surfaces in CI or a headless
  # \`xcodebuild -destination 'platform=iOS,...'\`. They keep the committed entitlements —
  # their only capability is the shared app group, which any team can sign.
  OpenGlassesShareExtension:
    settings:
      base:
        DEVELOPMENT_TEAM: ${team}

  OpenGlassesWatch:
    settings:
      base:
        DEVELOPMENT_TEAM: ${team}

  OpenGlassesWatchWidget:
    settings:
      base:
        DEVELOPMENT_TEAM: ${team}
EOF
}

bundle_ids_from_commit() {
  local commit="$1"
  local pbx
  pbx="$(git show "$commit:OpenGlasses.xcodeproj/project.pbxproj" 2>/dev/null)" || return 1
  local app widget
  app="$(printf '%s\n' "$pbx" | grep 'PRODUCT_BUNDLE_IDENTIFIER = com\.' | grep -v watchkitapp | grep -v '\.tests' | grep -v GlassesActivityWidget | head -1 | sed 's/.*= //;s/;//')"
  widget="$(printf '%s\n' "$pbx" | grep 'GlassesActivityWidget' | grep PRODUCT_BUNDLE_IDENTIFIER | head -1 | sed 's/.*= //;s/;//')"
  printf '%s\n%s\n' "$app" "$widget"
}

restore_from_commit() {
  local commit="$1"
  mkdir -p Config/Entitlements/Personal

  git show "$commit:OpenGlasses/OpenGlasses.entitlements" > Config/Entitlements/Personal/OpenGlasses.entitlements
  git show "$commit:GlassesActivityWidget/GlassesActivityWidget.entitlements" > Config/Entitlements/Personal/GlassesActivityWidget.entitlements
  # No personal Info.plist is seeded any more. Overriding INFOPLIST_FILE to a snapshot was the
  # ITMS-90683 cause (the copy went stale and dropped newly added usage descriptions), and it
  # later swallowed the Meta credentials when the override was withdrawn. Rebranding needs no
  # plist copy either — PRODUCT_BUNDLE_IDENTIFIER and INFOPLIST_KEY_CFBundleDisplayName are
  # build settings. Everything personal now rides in as a build setting.

  local team
  team="$(development_team_from_commit "$commit")"
  if [[ -z "$team" ]]; then
    echo "Could not read DEVELOPMENT_TEAM from $commit" >&2
    exit 1
  fi
  local app_bundle widget_bundle
  read -r app_bundle widget_bundle < <(bundle_ids_from_commit "$commit")
  write_project_local_yml "$team" "$app_bundle" "$widget_bundle"

  echo "Restored from $commit:"
  echo "  project.local.yml (team ${team})"
  echo "  Config/Entitlements/Personal/*.entitlements"
}

if [[ "${1:-}" == "--from-commit" ]]; then
  restore_from_commit "${2:-$DEFAULT_COMMIT}"
else
  if [[ ! -f project.local.yml ]]; then
    cp project.local.yml.example project.local.yml
    echo "Created project.local.yml — set developmentTeam to your Apple Team ID"
  fi

  mkdir -p Config/Entitlements/Personal
  for f in Config/Entitlements/Personal/*.entitlements.example; do
    [[ -f "$f" ]] || continue
    out="${f%.example}"
    if [[ ! -f "$out" ]]; then
      cp "$f" "$out"
      echo "Created $out"
    fi
  done
fi

./Scripts/generate-xcodeproj.sh
