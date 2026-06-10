#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.12.13}"
RELEASE_DATE="${PYTHON_RELEASE_DATE:-20260325}"
INSTALL_DIR="${PYTHON_INSTALL_DIR:-/python}"

# Check if INSTALL_DIR is writable or if we have permission to create it
if [[ ! -d "$INSTALL_DIR" ]]; then
    PARENT_DIR=$(dirname "$INSTALL_DIR")
    if [[ ! -w "$PARENT_DIR" ]]; then
        INSTALL_DIR="$HOME/.dynamo/python"
        echo "Warning: ${PARENT_DIR} is not writable. Using fallback: ${INSTALL_DIR}"
    fi
fi

if [[ -x "${INSTALL_DIR}/bin/python3" ]]; then
    echo "Python already installed in ${INSTALL_DIR}."
    # Ensure symlinks exist
    [[ ! -e "${INSTALL_DIR}/bin/python" ]] && ln -sf python3 "${INSTALL_DIR}/bin/python"
    [[ ! -e "${INSTALL_DIR}/bin/pip" ]] && ln -sf pip3 "${INSTALL_DIR}/bin/pip"
    # Final PATH configuration
    export PATH="/workspace:${INSTALL_DIR}/bin:$PATH"
    if [ -d "/usr/local/bin" ]; then
      export PATH="/usr/local/bin:$PATH"
    fi
    echo "Python binaries available at: ${INSTALL_DIR}/bin"
    exit 0
fi

OS=$(uname -s)
ARCH=$(uname -m)

case "$OS" in
    Darwin)
        case "$ARCH" in
            arm64|aarch64) PY_TRIPLE="aarch64-apple-darwin" ;;
            *)             PY_TRIPLE="x86_64-apple-darwin" ;;
        esac
        ;;
    Linux)
        # Detect libc (Wolfi uses glibc, Alpine uses musl)
        if ldd --version 2>&1 | grep -q "musl"; then
            LIBC="musl"
        else
            LIBC="gnu"
        fi
        
        case "$ARCH" in
            arm64|aarch64) PY_TRIPLE="aarch64-unknown-linux-${LIBC}" ;;
            *)             PY_TRIPLE="x86_64-unknown-linux-${LIBC}" ;;
        esac
        ;;
    *)
        echo "Unsupported OS: ${OS}"
        exit 1
        ;;
esac

FILENAME="cpython-${PYTHON_VERSION}+${RELEASE_DATE}-${PY_TRIPLE}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${RELEASE_DATE}/${FILENAME}"

echo "Installing Python ${PYTHON_VERSION} (${PY_TRIPLE}) into ${INSTALL_DIR}..."
curl -fsSL -o /tmp/python.tar.gz "$URL"
mkdir -p "$INSTALL_DIR"
tar -xzf /tmp/python.tar.gz -C "$INSTALL_DIR" --strip-components=1
rm -f /tmp/python.tar.gz

# Ensure symlinks exist
[[ ! -e "${INSTALL_DIR}/bin/python" ]] && ln -sf python3 "${INSTALL_DIR}/bin/python"
[[ ! -e "${INSTALL_DIR}/bin/pip" ]] && ln -sf pip3 "${INSTALL_DIR}/bin/pip"

# Final PATH configuration
export PATH="/workspace:${INSTALL_DIR}/bin:$PATH"
if [ -d "/usr/local/bin" ]; then
  export PATH="/usr/local/bin:$PATH"
fi

echo "Python ${PYTHON_VERSION} ready."
echo "Python binaries available at: ${INSTALL_DIR}/bin"
echo "python3: $(command -v python3 || echo "${INSTALL_DIR}/bin/python3")"
