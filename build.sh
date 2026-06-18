#!/bin/bash
# One-shot build. slirpnetstack is now a regular Go module dependency
# (pinned in go.mod), so the build is a plain `go build` — no checkout
# sync or package rename. The first build fetches the module; afterwards
# it comes from the Go module cache.
#
#   ./build.sh            host build              -> ./build/gvswitch
#   ./build.sh arm64      static linux/arm64      -> ./dist/gvswitch-android-arm64
#   ./build.sh amd64      static linux/amd64      -> ./dist/gvswitch-linux-amd64
#   ./build.sh all        host + both static targets
set -euo pipefail
cd "$(dirname "$0")"

target="${1:-host}"
case "$target" in
host)
    make build
    echo "[+] built ./build/gvswitch"
    ;;
arm64|aarch64|android)
    make build-android BUILDDIR=dist
    ;;
amd64|x64)
    make build-linux-amd64 BUILDDIR=dist
    ;;
all)
    make build
    make build-android BUILDDIR=dist
    make build-linux-amd64 BUILDDIR=dist
    echo "[+] built ./build/gvswitch"
    ;;
*)
    echo "usage: $0 [host|arm64|amd64|all]" >&2
    exit 2
    ;;
esac
