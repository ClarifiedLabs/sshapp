#!/usr/bin/env bash
set -euo pipefail

default_repository_url="https://github.com/ClarifiedLabs/sshapp"
info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
source_root="${SRCROOT:-${PROJECT_DIR:-}}"

if [ ! -f "$info_plist" ]; then
    echo "warning: built Info.plist not found at $info_plist"
    exit 0
fi

repository_url="$(git -C "$source_root" config --get remote.origin.url 2>/dev/null || true)"
if [ -z "$repository_url" ]; then
    repository_url="$default_repository_url"
fi

case "$repository_url" in
    git@github.com:*)
        repository_url="https://github.com/${repository_url#git@github.com:}"
        repository_url="${repository_url%.git}"
        ;;
    ssh://git@github.com/*)
        repository_url="https://github.com/${repository_url#ssh://git@github.com/}"
        repository_url="${repository_url%.git}"
        ;;
    https://github.com/*.git)
        repository_url="${repository_url%.git}"
        ;;
esac

source_commit="$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$source_commit" ]; then
    source_commit="unknown"
fi

source_version="$(git -C "$source_root" tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | head -n 1 || true)"
if [ -z "$source_version" ]; then
    source_version="dev"
fi

set_plist_value() {
    local key="$1"
    local value="$2"

    /usr/libexec/PlistBuddy -c "Set :$key $value" "$info_plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$info_plist"
}

set_plist_value "SSHAppSourceRepositoryURL" "$repository_url"
set_plist_value "SSHAppSourceCommit" "$source_commit"
set_plist_value "SSHAppSourceVersion" "$source_version"
