#!/bin/bash
# One-shot build: sync the slirpnetstack checkout (clone/pull + package
# rename + overlay glue), then build gvswitch.
#
#   ./build.sh            host build            -> ./gvswitch
#   ./build.sh android    static linux/arm64    -> ./gvswitch-android-arm64
#   ./build.sh amd64      static linux/amd64    -> ./gvswitch-linux-amd64
#   ./build.sh all        all of the above
set -euo pipefail
cd "$(dirname "$0")"

./sync-slirpnetstack.sh

target="${1:-host}"
case "$target" in
host)
    make build
    echo "[+] built ./gvswitch"
    ;;
android)
    make build-android
    ;;
amd64)
    make build-linux-amd64
    ;;
all)
    make build build-android build-linux-amd64
    echo "[+] built ./gvswitch"
    ;;
*)
    echo "usage: $0 [host|android|amd64|all]" >&2
    exit 2
    ;;
esac
