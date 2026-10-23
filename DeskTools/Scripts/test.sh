#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export APP_UI_LANGUAGE="${APP_UI_LANGUAGE:-zh-Hant}"
swift test -j 4 "$@"
