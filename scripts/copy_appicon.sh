#!/usr/bin/env zsh
# Copy generated icon PNGs from .tmp/appicon into the asset catalog.
# Run from repo root or any dir; script resolves paths relative to itself.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"  # scripts/ parent
SRC_DIR="${REPO_ROOT}/.tmp/appicon"
DST_DIR="${REPO_ROOT}/HavenUI/Sources/HavenUI/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Source icon directory missing: $SRC_DIR" >&2
  exit 1
fi
if [[ ! -d "$DST_DIR" ]]; then
  echo "Destination appiconset missing: $DST_DIR" >&2
  exit 1
fi

print_copy() {
  local f="$1"
  cp "$SRC_DIR/$f" "$DST_DIR/$f"
  echo "→ Copied $f"
}

for f in icon_16.png icon_16@2x.png \
          icon_32.png icon_32@2x.png \
          icon_128.png icon_128@2x.png \
          icon_256.png icon_256@2x.png \
          icon_512.png icon_512@2x.png icon_1024.png; do
  if [[ -f "$SRC_DIR/$f" ]]; then
    print_copy "$f"
  else
    echo "(missing) $f" >&2
  fi
done

echo "Done. Verify in Xcode or run a build to ensure the Dock icon updates."
