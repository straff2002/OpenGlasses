#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DEFAULT_COMMIT=e5bbe7946af05411c3081785b9893a9eac4a7381

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

write_project_local_yml() {
  local team="$1"
  local app_bundle="${2:-com.openglasses.app}"
  local widget_bundle="${3:-com.openglasses.app.GlassesActivityWidget}"
  cat > project.local.yml <<EOF
options:
  developmentTeam: ${team}

targets:
  OpenGlasses:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/OpenGlasses.entitlements
        DEVELOPMENT_TEAM: ${team}
        INFOPLIST_FILE: Config/Info/Info.personal.plist
        PRODUCT_BUNDLE_IDENTIFIER: ${app_bundle}

  GlassesActivityWidget:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/GlassesActivityWidget.entitlements
        DEVELOPMENT_TEAM: ${team}
        PRODUCT_BUNDLE_IDENTIFIER: ${widget_bundle}
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
  mkdir -p Config/Entitlements/Personal Config/Info

  git show "$commit:OpenGlasses/OpenGlasses.entitlements" > Config/Entitlements/Personal/OpenGlasses.entitlements
  git show "$commit:GlassesActivityWidget/GlassesActivityWidget.entitlements" > Config/Entitlements/Personal/GlassesActivityWidget.entitlements
  git show "$commit:OpenGlasses/Info.plist" > Config/Info/Info.personal.plist

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
  echo "  Config/Info/Info.personal.plist"
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
