#!/usr/bin/env bash
#
# Headless smoke test for pseudocopy (§6, Phase 8).
#
# Builds the tool, runs a full cycle in a sandbox directory and checks
# clipping, reaping and the exclusion of partial downloads.
#
# NOTE: this test writes to the system pasteboard. The previous clipboard
#       content is restored when the script finishes.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SANDBOX="${PSEUDOCOPY_SMOKE_DIR:-/tmp/pseudocopy-smoke}"
BIN="${ROOT_DIR}/.build/debug/pseudocopy"
STATE_FILE="${HOME}/Library/Application Support/pseudocopy/state.json"

FAILURES=0
LOG_DIR="$(mktemp -d)"

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '  ..    %s\n' "$1"; }

check_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        pass "${label}"
    else
        fail "${label} (expected '${expected}', got '${actual}')"
    fi
}

# --- clipboard backup ------------------------------------------------------
CLIP_BACKUP="${LOG_DIR}/clipboard.txt"
if pbpaste > "${CLIP_BACKUP}" 2>/dev/null; then
    info "the clipboard is restored when the test finishes (text content only)"
else
    : > "${CLIP_BACKUP}"
fi
restore_clipboard() {
    pbcopy < "${CLIP_BACKUP}" 2>/dev/null || true
    rm -rf "${LOG_DIR}"
}
trap restore_clipboard EXIT

# --- build -----------------------------------------------------------------
echo "==> building"
cd "${ROOT_DIR}"
if ! swift build > "${LOG_DIR}/build.log" 2>&1; then
    echo "build failed:" >&2
    cat "${LOG_DIR}/build.log" >&2
    exit 1
fi
pass "swift build"

# --- sandbox ---------------------------------------------------------------
echo "==> sandbox: ${SANDBOX}"
rm -rf "${SANDBOX}"
mkdir -p "${SANDBOX}"
printf 'pseudocopy smoke test\n' > "${SANDBOX}/sample.txt"
printf 'partial download in progress\n' > "${SANDBOX}/sample.still-downloading.crdownload"
printf 'pseudocopy-smoke-marker\n' | pbcopy

# --- cycle 1: the file is still settling ------------------------------------
echo "==> cycle 1 (settling)"
"${BIN}" run --dir "${SANDBOX}" --ttl 1 --verbose > "${LOG_DIR}/run1.log" 2>&1
check_eq "cycle 1 exits 0" "0" "$?"
check_eq "cycle 1 does not clip yet" "pseudocopy-smoke-marker" "$(pbpaste)"
if grep -q "settling" "${LOG_DIR}/run1.log"; then
    pass "cycle 1 logs the file as settling"
else
    fail "cycle 1 logs the file as settling"
fi

# --- cycle 2: the file is clipped ------------------------------------------
echo "==> cycle 2 (clip)"
"${BIN}" run --dir "${SANDBOX}" --ttl 1 --verbose > "${LOG_DIR}/run2.log" 2>&1
check_eq "cycle 2 exits 0" "0" "$?"
check_eq "cycle 2 puts the text on the clipboard" "pseudocopy smoke test" "$(pbpaste)"
if grep -q "\[clip\] text" "${LOG_DIR}/run2.log"; then
    pass "cycle 2 logs a clip event"
else
    fail "cycle 2 logs a clip event"
fi

# --- partial downloads are ignored -----------------------------------------
echo "==> partial downloads"
check_eq "the partial download is not clipped" "pseudocopy smoke test" "$(pbpaste)"
if [[ -f "${STATE_FILE}" ]] && grep -q "crdownload" "${STATE_FILE}"; then
    fail "the partial download has no state record"
else
    pass "the partial download has no state record"
fi

# --- reaping ---------------------------------------------------------------
echo "==> reaping"
# macOS touch(1) has no relative offsets: build an absolute timestamp.
OLD_STAMP="$(date -v-2H +%Y%m%d%H%M.%S)"
touch -t "${OLD_STAMP}" "${SANDBOX}/sample.txt"
"${BIN}" clean --dir "${SANDBOX}" --ttl 1 --no-trash --verbose > "${LOG_DIR}/clean.log" 2>&1
check_eq "clean exits 0" "0" "$?"
if [[ -f "${SANDBOX}/sample.txt" ]]; then
    fail "the expired file is reaped"
else
    pass "the expired file is reaped"
fi
if [[ -f "${SANDBOX}/sample.still-downloading.crdownload" ]]; then
    pass "the partial download is left alone"
else
    fail "the partial download is left alone"
fi

# --- state store -----------------------------------------------------------
echo "==> state store"
if [[ -f "${STATE_FILE}" ]]; then
    pass "the state file exists"
else
    fail "the state file exists"
fi

# --- result ----------------------------------------------------------------
echo
if [[ "${FAILURES}" -eq 0 ]]; then
    echo "smoke test passed"
    exit 0
fi
echo "smoke test failed: ${FAILURES} check(s) did not pass"
exit 1
