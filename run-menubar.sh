#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${ROOT_DIR}/build-menubar-app.sh" >/dev/null
open "${ROOT_DIR}/dist/Codex Account Switch.app"
