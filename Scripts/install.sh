#!/usr/bin/env bash
#
# Build pseudocopy, install the binary and register the LaunchAgent (§5.1).
#
# Usage:
#   Scripts/install.sh [--prefix DIR] [--dir WATCHDIR] [--ttl SECONDS]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFIX="${HOME}/bin"
WATCHDIR="${HOME}/Temp"
TTL=""

usage() {
    cat <<EOF
Usage: Scripts/install.sh [--prefix DIR] [--dir WATCHDIR] [--ttl SECONDS]

  --prefix DIR   where the binary is installed (default: ${HOME}/bin)
  --dir PATH     the folder to watch (default: ${HOME}/Temp)
  --ttl SECONDS  reaper time-to-live (default: 3600)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --dir)    WATCHDIR="${2:?--dir needs a directory}"; shift 2 ;;
        --ttl)    TTL="${2:?--ttl needs a number of seconds}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install.sh: unknown option '$1'" >&2; usage >&2; exit 1 ;;
    esac
done

cd "${ROOT_DIR}"

echo "==> building (release)"
swift build -c release

echo "==> installing binary into ${PREFIX}"
mkdir -p "${PREFIX}"
cp -f "${ROOT_DIR}/.build/release/pseudocopy" "${PREFIX}/pseudocopy"
chmod 755 "${PREFIX}/pseudocopy"

echo "==> preparing watch dir ${WATCHDIR}"
if [[ ! -d "${WATCHDIR}" ]]; then
    mkdir -p "${WATCHDIR}"
    chmod 700 "${WATCHDIR}"
fi

INSTALL_ARGS=(install --dir "${WATCHDIR}")
if [[ -n "${TTL}" ]]; then
    INSTALL_ARGS+=(--ttl "${TTL}")
fi

echo "==> registering LaunchAgent"
"${PREFIX}/pseudocopy" "${INSTALL_ARGS[@]}"

echo
echo "Done."
case ":${PATH}:" in
    *":${PREFIX}:"*)
        echo "  ${PREFIX} is already on your PATH." ;;
    *)
        echo "  Note: ${PREFIX} is not on your PATH. Add this to your shell profile:"
        echo "      export PATH=\"${PREFIX}:\$PATH\"" ;;
esac
echo "  The agent runs every 5 seconds; logs go to ~/Library/Logs/pseudocopy.log"
echo "  Uninstall with: ${PREFIX}/pseudocopy uninstall"
