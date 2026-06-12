#!/usr/bin/env bash
set -euo pipefail

# Cross-compile admin-ui release binaries (web UI embedded) into dist/.
# Publish them so admin-ui.sh can self-download on machines without Go:
#   gh release create admin-ui-v1 -R wpmaster-cloud/spirit-resources dist/admin-ui-*

cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p dist
for t in linux/arm64 linux/amd64 darwin/arm64 darwin/amd64; do
  out="dist/admin-ui-${t%/*}-${t#*/}"
  GOOS="${t%/*}" GOARCH="${t#*/}" CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w" -o "$out" .
  echo "built $out"
done
