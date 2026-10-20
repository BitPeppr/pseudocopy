#!/usr/bin/env bash
#
# Headless smoke test for pseudocopy (§6, Phase 8).
#
# Builds the tool, runs full cycles in a private sandbox directory and checks
# clipping, reaping, the exclusion rules and the process lock.
#
# NOTE: this test writes to the system pasteboard. The previous clipboard
#       content is restored when the script finishes.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${ROOT_DIR}/.build/debug/pseudocopy"
STATE_FILE="${HOME}/Library/Application Support/pseudocopy/state.json"

FAILURES=0
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-smoke-logs.XXXXXX")"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-smoke.XXXXXX")"

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

# Records of one watch folder inside the state store.
state_records() {
    python3 - "$STATE_FILE" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
records = data.get("dirs", {}).get(sys.argv[2], {})
for path in records:
    print(path)
PY
}

# True when the state store has a namespace for this watch folder.
state_namespace_exists() {
    python3 - "$STATE_FILE" "$1" <<'PY' 2>/dev/null || exit 1
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if sys.argv[2] in data.get("dirs", {}) else 1)
PY
}

# --- clipboard backup ------------------------------------------------------
CLIP_BACKUP="${LOG_DIR}/clipboard.txt"
if pbpaste > "${CLIP_BACKUP}" 2>/dev/null; then
    info "the clipboard is restored when the test finishes (text content only)"
else
    : > "${CLIP_BACKUP}"
fi
cleanup() {
    pbcopy < "${CLIP_BACKUP}" 2>/dev/null || true
    rm -rf "${LOG_DIR}" "${SANDBOX}"
}
trap cleanup EXIT

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
# The tool keys the state store with the resolved path, and Foundation maps
# /private/var back to /var — the lookup below has to use the same spelling,
# otherwise the assertions would pass because they find nothing.
NS_KEY="$(cd "${SANDBOX}" && pwd -P)"
NS_KEY="${NS_KEY#/private}"

# The first cycle of a new watch folder only establishes the store: files
# that were already there are treated as leftovers and are not copied onto
# the clipboard. Warming the folder up first is what the agent does on its
# own, seconds after it is installed.
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 >/dev/null 2>&1

printf 'pseudocopy smoke test\n' > "${SANDBOX}/sample.txt"
printf 'partial download in progress\n' > "${SANDBOX}/sample.still-downloading.crdownload"
printf 'partial download in progress\n' > "${SANDBOX}/sample.part"
printf 'dotfile\n' > "${SANDBOX}/.hidden.txt"
mkdir -p "${SANDBOX}/a-directory"
ln -sf "${SANDBOX}/sample.txt" "${SANDBOX}/a-symlink.txt"
printf 'pseudocopy-smoke-marker\n' | pbcopy

# --- cycle 1: the file is still settling ------------------------------------
echo "==> cycle 1 (settling)"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/run1.log" 2>&1
check_eq "cycle 1 exits 0" "0" "$?"
check_eq "cycle 1 does not clip yet" "pseudocopy-smoke-marker" "$(pbpaste)"
if grep -q "settling" "${LOG_DIR}/run1.log"; then
    pass "cycle 1 logs the file as settling"
else
    fail "cycle 1 logs the file as settling"
fi

# --- cycle 2: the file is clipped ------------------------------------------
echo "==> cycle 2 (clip)"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/run2.log" 2>&1
check_eq "cycle 2 exits 0" "0" "$?"
check_eq "cycle 2 puts the text on the clipboard" "pseudocopy smoke test" "$(pbpaste)"
if grep -q "\[clip\] text" "${LOG_DIR}/run2.log"; then
    pass "cycle 2 logs a clip event"
else
    fail "cycle 2 logs a clip event"
fi

# --- cycle 3: nothing is clipped twice --------------------------------------
echo "==> cycle 3 (no re-clip)"
printf 'pseudocopy-smoke-marker\n' | pbcopy
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/run3.log" 2>&1
check_eq "cycle 3 leaves the clipboard alone" "pseudocopy-smoke-marker" "$(pbpaste)"
if grep -q "\[clip\]" "${LOG_DIR}/run3.log"; then
    fail "cycle 3 does not clip again"
else
    pass "cycle 3 does not clip again"
fi

# --- exclusion rules --------------------------------------------------------
echo "==> exclusion rules"
check_eq "the partial download is not clipped" "pseudocopy-smoke-marker" "$(pbpaste)"
RECORDS="$(state_records "${NS_KEY}")"
if ! state_namespace_exists "${NS_KEY}"; then
    fail "the state store knows the sandbox folder"
else
    pass "the state store knows the sandbox folder"
    if [[ -z "${RECORDS}" ]] || ! grep -qE "crdownload|\.part|a-directory|a-symlink|hidden" <<< "${RECORDS}"; then
        pass "no state record for partial downloads, dotfiles, directories or symlinks"
    else
        fail "no state record for partial downloads, dotfiles, directories or symlinks"
    fi
fi

# --- the lock ---------------------------------------------------------------
echo "==> process lock"
printf 'lock test\n' > "${SANDBOX}/lock-test.txt"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 >/dev/null 2>&1   # first sighting: settling
# Two cycles at the same time: exactly one of them may clip the file.
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/lock1.log" 2>&1 &
PID1=$!
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/lock2.log" 2>&1 &
PID2=$!
wait "${PID1}" "${PID2}"
CLIPS="$(cat "${LOG_DIR}/lock1.log" "${LOG_DIR}/lock2.log" | grep -c "\[clip\]" || true)"
check_eq "two parallel cycles clip only once" "1" "${CLIPS}"

# --- reaping ----------------------------------------------------------------
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
if [[ -d "${SANDBOX}/a-directory" ]]; then
    pass "directories are left alone"
else
    fail "directories are left alone"
fi
if [[ -L "${SANDBOX}/a-symlink.txt" ]]; then
    pass "symlinks are left alone"
else
    fail "symlinks are left alone"
fi
if ! state_records "${NS_KEY}" | grep -q "sample.txt"; then
    pass "the state record of the reaped file is pruned"
else
    fail "the state record of the reaped file is pruned"
fi

# --- state store ------------------------------------------------------------
echo "==> state store"
if [[ -f "${STATE_FILE}" ]]; then
    pass "the state file exists"
else
    fail "the state file exists"
fi

# --- result -----------------------------------------------------------------
echo
if [[ "${FAILURES}" -eq 0 ]]; then
    echo "smoke test passed"
    exit 0
fi
echo "smoke test failed: ${FAILURES} check(s) did not pass"
exit 1
