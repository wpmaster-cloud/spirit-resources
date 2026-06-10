#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.13.1}"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
    x86_64) N_ARCH="x64" ;;
    arm64|aarch64) N_ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

NODE_ARCH="${NODE_ARCH:-${OS}-${N_ARCH}}"
INSTALL_DIR="${NODE_INSTALL_DIR:-/usr/local}"

# Check for write permissions or use fallback
if [[ ! -d "$INSTALL_DIR" ]]; then
    PARENT_DIR=$(dirname "$INSTALL_DIR")
    if [[ ! -w "$PARENT_DIR" ]]; then
        INSTALL_DIR="$HOME/.dynamo/nodejs"
        echo "Warning: ${PARENT_DIR} is not writable. Using fallback: ${INSTALL_DIR}"
    fi
fi

mkdir -p "$INSTALL_DIR"

echo "Installing Node.js v${NODE_VERSION} (${NODE_ARCH}) into ${INSTALL_DIR}..."
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-${NODE_ARCH}.tar.xz" \
  | tar -xJ -C "$INSTALL_DIR" --strip-components=1

echo "Node.js v${NODE_VERSION} ready."
