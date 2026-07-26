#!/usr/bin/env bash
#
# packaging/build.sh inside a container, so the artifacts build anywhere Docker
# runs - no local zip/python3 needed.
#
#   ./packaging/build-docker.sh              # -> dist/
#   APP_VERSION=0.2.0 ./packaging/build-docker.sh
#
# This exists because a Windows checkout typically has neither `zip` nor a real
# `python3` (the WindowsApps one is a Microsoft Store stub that exits non-zero),
# and build.sh degrades quietly in that case: it still stages dist/claudeusage/
# but skips both the .zip and the .kpkg. Same script, same output, in a box that
# has the tools.
#
# Still needs packaging/fetch-runtime.sh to have run - the Kindle runtime is
# platform-specific and is downloaded, not built.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[ -d "$ROOT/runtime" ] || {
    echo "runtime/ missing - run packaging/fetch-runtime.sh first" >&2
    exit 1
}

cat > "$ROOT/.docker-build.sh" <<'INNER'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq zip python3 curl ca-certificates >/dev/null 2>&1
exec bash /repo/packaging/build.sh
INNER

echo "==> building in Docker"
# MSYS_NO_PATHCONV: git-bash would otherwise rewrite the container-side paths.
MSYS_NO_PATHCONV=1 docker run --rm \
    -e APP_VERSION="${APP_VERSION:-}" \
    -v "$ROOT:/repo" \
    -w /repo \
    debian:trixie-slim sh /repo/.docker-build.sh

rm -f "$ROOT/.docker-build.sh"
