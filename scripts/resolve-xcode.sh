#!/usr/bin/env bash
set -euo pipefail

# Prefer the selected installation; hosted runners may default to an older SDK.
major="${1:-27}"
selected="${DEVELOPER_DIR:-$(xcode-select -p)}"
for developer_dir in "$selected" /Applications/Xcode*.app/Contents/Developer; do
  [[ -d "$developer_dir" ]] || continue
  version="$(DEVELOPER_DIR="$developer_dir" xcodebuild -version 2>/dev/null | awk '/^Xcode / {print $2}')" || continue
  if [[ "$version" == "$major" || "$version" == "$major".* ]]; then
    printf '%s\n' "$developer_dir"
    exit 0
  fi
done
echo "Xcode $major is required but no matching installation was found." >&2
exit 1
