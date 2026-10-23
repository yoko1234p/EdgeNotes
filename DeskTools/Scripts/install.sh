#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
parent="${DESKTOOLS_INSTALL_DIR:-/Applications}"
if [ "$#" -eq 0 ]; then set -- EdgeNotes; fi
for name in "$@"; do
    case "$name" in EdgeNotes) ;; *) echo "Unknown app: $name" >&2; exit 2 ;; esac
done
mkdir -p "$parent"
for name in "$@"; do
    source_app="dist/$name.app"
    target="$parent/$name.app"
    if [ -L "$target" ]; then
        canonical_target="$(readlink "$target")"
        if [ "$canonical_target" != "/Applications/$name.app" ]; then
            echo "Unrecognised application shortcut at $target; stopped." >&2; exit 1
        fi
        target="$canonical_target"
    fi
    target_parent="$(dirname "$target")"
    staging="$target_parent/.$name.installing.app"
    backup="$target_parent/.$name.previous.app"
    identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")
    expected_identifier="local.pakwingho.$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    if [ "$identifier" != "$expected_identifier" ]; then echo "Unexpected source application; stopped." >&2; exit 1; fi
    codesign --verify --deep --strict "$source_app"
    if [ -e "$target" ]; then
        installed_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
        if [ "$installed_id" != "$identifier" ]; then echo "Unrelated app at $target; stopped." >&2; exit 1; fi
    fi
    if [ -e "$staging" ]; then rm -rf "$staging"; fi
    ditto "$source_app" "$staging"
    codesign --verify --deep --strict "$staging"
    /usr/bin/osascript -e "if application id \"$identifier\" is running then tell application id \"$identifier\" to quit" >/dev/null 2>&1 || true
    for attempt in {1..30}; do
        if ! pgrep -x "$name" >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x "$name" >/dev/null; then echo "$name is still running; installation stopped." >&2; exit 1; fi
    if [ -e "$backup" ]; then rm -rf "$backup"; fi
    if [ -e "$target" ]; then mv "$target" "$backup"; fi
    if ! mv "$staging" "$target"; then
        if [ -d "$backup" ]; then mv "$backup" "$target"; fi
        exit 1
    fi
    if ! codesign --verify --deep --strict "$target" ||
        ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"; then
        rm -rf "$target"
        if [ -d "$backup" ]; then
            mv "$backup" "$target"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" || true
        fi
        echo "$name registration failed; restored the previous installation." >&2
        exit 1
    fi
    echo "Installed $target"
done
