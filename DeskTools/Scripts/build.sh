#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Use debug or release' >&2; exit 2 ;; esac
if [ "$#" -gt 0 ]; then shift; fi
if [ "$#" -eq 0 ]; then set -- EdgeNotes; fi
for name in "$@"; do
    case "$name" in EdgeNotes) ;; *) echo "Unknown app: $name" >&2; exit 2 ;; esac
done
read -r -a build_architectures <<< "${DESKTOOLS_ARCHS:-$(uname -m)}"
architecture_flags=()
for architecture in "${build_architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;; esac
    architecture_flags+=(--arch "$architecture")
done
for name in "$@"; do swift build -c "$configuration" "${architecture_flags[@]}" --product "$name"; done
binary_directory="$(swift build -c "$configuration" "${architecture_flags[@]}" --show-bin-path)"
mkdir -p dist
xcrun swift Scripts/make-icons.swift dist
python3 Scripts/package.py "$binary_directory" "$configuration" "$@"
for name in "$@"; do
    identity="-"
    if [ "$name" = CaptureText ]; then
        identity="${CAPTURETEXT_SIGN_IDENTITY:-}"
        if [ -z "$identity" ] && [ -f .local/capturetext-signing-identity ]; then
            identity="$(cat .local/capturetext-signing-identity)"
        fi
        if [ -z "$identity" ]; then identity="-"; fi
        if [ "$identity" != - ]; then
            identity="$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')"
            if ! [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
                echo 'CaptureText signing identity must be a certificate SHA-1 fingerprint.' >&2
                exit 1
            fi
            if ! security find-identity -v -p codesigning | /usr/bin/grep -F "$identity" >/dev/null; then
                echo 'Configured CaptureText signing certificate is unavailable; stopped to preserve its permission identity.' >&2
                exit 1
            fi
        fi
    fi
    if [ "$name" = EdgeNotes ]; then
        identity="${EDGENOTES_SIGN_IDENTITY:-}"
        if [ -z "$identity" ] && [ -f .local/edgenotes-signing-identity ]; then
            identity="$(cat .local/edgenotes-signing-identity)"
        fi
        if [ -z "$identity" ]; then identity="-"; fi
        if [ "$identity" != - ]; then
            identity="$(printf '%s' "$identity" | tr '[:lower:]' '[:upper:]')"
            if ! [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
                echo 'EdgeNotes signing identity must be a certificate SHA-1 fingerprint.' >&2
                exit 1
            fi
            if ! security find-identity -v -p codesigning | /usr/bin/grep -F "$identity" >/dev/null; then
                echo 'Configured EdgeNotes signing certificate is unavailable; stopped to preserve its login identity.' >&2
                exit 1
            fi
        fi
    fi
    codesign --force --sign "$identity" --timestamp=none "dist/$name.app"
    codesign --verify --deep --strict "dist/$name.app"
    lipo -archs "dist/$name.app/Contents/MacOS/$name"
    register_tool='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    "$register_tool" -u "$PWD/dist/$name.app" >/dev/null 2>&1 || true
    installed_app="/Applications/$name.app"
    if [ -L "$installed_app" ] && [ "$(readlink "$installed_app")" = "/Applications/$name.app" ]; then
        installed_app="/Applications/$name.app"
    fi
    if [ -d "$installed_app" ] &&
        [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed_app/Contents/Info.plist")" = "local.pakwingho.$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" ]; then
        "$register_tool" -f "$installed_app"
    fi
done
echo "Built $* in dist/"
