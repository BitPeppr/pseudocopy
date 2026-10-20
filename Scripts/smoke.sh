#!/usr/bin/env bash
#
# Headless smoke test for pseudocopy (§6, Phase 8).
#
# Builds the tool and runs full cycles in private sandbox directories against a
# private state store (PSEUDOCOPY_STATE_ROOT), so the live state is never
# touched. Checks clipping, reaping, the exclusion rules, the process lock, the
# state store and the safety paths (unreadable files, corrupt state, guards).
#
# NOTE: this test writes to the system pasteboard. The whole clipboard (every
#       representation, not just the text) is snapshotted first and restored
#       when the script finishes.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${ROOT_DIR}/.build/debug/pseudocopy"

FAILURES=0
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-smoke-logs.XXXXXX")"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-smoke.XXXXXX")"
RESET_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-smoke-reset.XXXXXX")"
CORRUPT_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-smoke-corrupt.XXXXXX")"

STATE_ROOT="${LOG_DIR}/state"
RESET_ROOT="${LOG_DIR}/reset-state"
CORRUPT_ROOT="${LOG_DIR}/corrupt-state"
STATE_FILE="${STATE_ROOT}/state.json"
export PSEUDOCOPY_STATE_ROOT="${STATE_ROOT}"

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

# Records of one watch folder that have been copied at least once.
state_clipped() {
    python3 - "$STATE_FILE" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
records = data.get("dirs", {}).get(sys.argv[2], {})
for path, record in records.items():
    if record.get("clippedFingerprint") is not None:
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

# --- clipboard inspector + backup ------------------------------------------
# `pbpaste` only sees text; the inspector reads every representation, so the
# test can assert what apps actually receive.
INSPECTOR="${LOG_DIR}/pasteboard-inspector"
CLIP_SNAPSHOT="${LOG_DIR}/clipboard.plist"

cleanup() {
    if [[ -x "${INSPECTOR}" && -f "${CLIP_SNAPSHOT}" ]]; then
        "${INSPECTOR}" restore "${CLIP_SNAPSHOT}" >/dev/null 2>&1 || true
    fi
    rm -rf "${LOG_DIR}" "${SANDBOX}" "${RESET_SANDBOX}" "${CORRUPT_SANDBOX}"
}
trap cleanup EXIT

if ! swiftc -O -o "${INSPECTOR}" "${SCRIPT_DIR}/pasteboard_inspector.swift" > "${LOG_DIR}/inspector.log" 2>&1; then
    echo "the pasteboard inspector failed to build:" >&2
    cat "${LOG_DIR}/inspector.log" >&2
    exit 1
fi
if "${INSPECTOR}" save "${CLIP_SNAPSHOT}" 2>/dev/null; then
    info "the clipboard is restored when the test finishes"
else
    fail "the clipboard could not be saved"
fi

pb_has() { "${INSPECTOR}" has "$1"; }
pb_size() { "${INSPECTOR}" size "$1"; }
pb_string() { "${INSPECTOR}" string "$1"; }
pb_file_urls() { "${INSPECTOR}" file-urls; }

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
# The tool canonicalises the watch folder with realpath(3), so the state key is
# the /private/... spelling that `pwd -P` prints.
NS_KEY="$(cd "${SANDBOX}" && pwd -P)"

# The first cycle of a new watch folder only establishes the store: files that
# were already there are treated as leftovers and are not copied. Warming the
# folder up first is what the agent does on its own, seconds after install.
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 >/dev/null 2>&1
check_eq "the warm-up cycle exits 0" "0" "$?"

if [[ -f "${STATE_FILE}" ]]; then
    pass "the state file exists after the first cycle"
else
    fail "the state file exists after the first cycle"
fi
check_eq "the state file is private (0600)" "600" "$(stat -f %Lp "${STATE_FILE}" 2>/dev/null)"
check_eq "the state folder is private (0700)" "700" "$(stat -f %Lp "${STATE_ROOT}" 2>/dev/null)"
if python3 - "${STATE_FILE}" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("version") == 1
assert "dirs" in data and "lastScan" in data and "seen" in data
PY
then
    pass "the state file is valid JSON with the expected keys"
else
    fail "the state file is valid JSON with the expected keys"
fi

printf 'pseudocopy smoke test\n' > "${SANDBOX}/sample.txt"
printf 'partial download in progress\n' > "${SANDBOX}/sample.still-downloading.crdownload"
printf 'partial download in progress\n' > "${SANDBOX}/sample.part"
printf 'dotfile\n' > "${SANDBOX}/.hidden.txt"
mkdir -p "${SANDBOX}/a-directory"
ln -sf "${SANDBOX}/sample.txt" "${SANDBOX}/a-symlink.txt"
OUTSIDE_TARGET="${LOG_DIR}/outside-target.txt"
printf 'do not touch me\n' > "${OUTSIDE_TARGET}"
ln -sf "${OUTSIDE_TARGET}" "${SANDBOX}/outside-link.txt"
printf 'pseudocopy-smoke-marker\n' | pbcopy

# --- cycle 1: the file is still settling ------------------------------------
echo "==> cycle 1 (settling)"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/run1.log" 2>&1
STATUS=$?
check_eq "cycle 1 exits 0" "0" "${STATUS}"
check_eq "cycle 1 does not clip yet" "pseudocopy-smoke-marker" "$(pbpaste)"
if grep -q "settling" "${LOG_DIR}/run1.log"; then
    pass "cycle 1 logs the file as settling"
else
    fail "cycle 1 logs the file as settling"
fi

# --- cycle 2: the file is clipped ------------------------------------------
echo "==> cycle 2 (clip)"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/run2.log" 2>&1
STATUS=$?
check_eq "cycle 2 exits 0" "0" "${STATUS}"
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
STATUS=$?
check_eq "cycle 3 exits 0" "0" "${STATUS}"
check_eq "cycle 3 leaves the clipboard alone" "pseudocopy-smoke-marker" "$(pbpaste)"
if grep -q "\[clip\]" "${LOG_DIR}/run3.log"; then
    fail "cycle 3 does not clip again"
else
    pass "cycle 3 does not clip again"
fi

# --- an idle cycle must not rewrite the state file -------------------------
echo "==> idle state"
sleep 1
BEFORE_HASH="$(shasum -a 256 "${STATE_FILE}" | cut -d' ' -f1)"
BEFORE_MTIME="$(stat -f %m "${STATE_FILE}")"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 >/dev/null 2>&1
AFTER_HASH="$(shasum -a 256 "${STATE_FILE}" | cut -d' ' -f1)"
AFTER_MTIME="$(stat -f %m "${STATE_FILE}")"
check_eq "an idle cycle does not rewrite the state file" "${BEFORE_HASH}" "${AFTER_HASH}"
check_eq "an idle cycle does not touch the state file" "${BEFORE_MTIME}" "${AFTER_MTIME}"

# --- exclusion rules --------------------------------------------------------
echo "==> exclusion rules"
check_eq "the partial download is not clipped" "pseudocopy-smoke-marker" "$(pbpaste)"
RECORDS="$(state_records "${NS_KEY}")"
if ! state_namespace_exists "${NS_KEY}"; then
    fail "the state store knows the sandbox folder"
else
    pass "the state store knows the sandbox folder"
    if [[ -z "${RECORDS}" ]] || ! grep -qE "crdownload|\.part|a-directory|a-symlink|outside-link|hidden" <<< "${RECORDS}"; then
        pass "no state record for partial downloads, dotfiles, directories or symlinks"
    else
        fail "no state record for partial downloads, dotfiles, directories or symlinks"
    fi
fi
if [[ -f "${OUTSIDE_TARGET}" ]]; then
    pass "a symlink pointing outside the folder does not affect its target"
else
    fail "a symlink pointing outside the folder does not affect its target"
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
STATUS=$?
check_eq "clean exits 0" "0" "${STATUS}"
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

# --- several files settling in one cycle are one pasteboard transaction -----
echo "==> multi-file batch"
printf 'multi A\n' > "${SANDBOX}/multi-a.txt"
printf 'multi B\n' > "${SANDBOX}/multi-b.txt"
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 >/dev/null 2>&1   # settling
"${BIN}" run --dir "${SANDBOX}" --ttl 3600 --verbose > "${LOG_DIR}/multi.log" 2>&1
STATUS=$?
check_eq "the batch cycle exits 0" "0" "${STATUS}"
CLIPPED="$(state_clipped "${NS_KEY}")"
if grep -q "multi-a.txt" <<< "${CLIPPED}" && grep -q "multi-b.txt" <<< "${CLIPPED}"; then
    pass "both files of the batch are marked as clipped"
else
    fail "both files of the batch are marked as clipped"
fi
BATCH_CLIPS="$(grep -c "\[clip\] text" "${LOG_DIR}/multi.log" || true)"
check_eq "the batch logs both files" "2" "${BATCH_CLIPS}"
CLIPBOARD="$(pbpaste)"
if [[ "${CLIPBOARD}" == "multi A" || "${CLIPBOARD}" == "multi B" ]]; then
    pass "the batch leaves one of its texts on the clipboard"
else
    fail "the batch leaves one of its texts on the clipboard (got '${CLIPBOARD}')"
fi

# --- an unreadable file is retried, not reaped -----------------------------
echo "==> unreadable file"
printf 'unreadable\n' > "${SANDBOX}/unreadable.txt"
chmod 000 "${SANDBOX}/unreadable.txt"
python3 - "${SANDBOX}/unreadable.txt" <<'PY'
import os, sys
os.utime(sys.argv[1], (1, 1))
PY
"${BIN}" run --dir "${SANDBOX}" --ttl 1 --no-trash >/dev/null 2>&1   # first sighting
printf 'unreadable-marker\n' | pbcopy
"${BIN}" run --dir "${SANDBOX}" --ttl 1 --no-trash --verbose > "${LOG_DIR}/unreadable.log" 2>&1
STATUS=$?
check_eq "the unreadable cycle exits 0" "0" "${STATUS}"
if [[ -f "${SANDBOX}/unreadable.txt" ]]; then
    pass "an unreadable file is not reaped"
else
    fail "an unreadable file is not reaped"
fi
check_eq "a failed clip leaves the clipboard alone" "unreadable-marker" "$(pbpaste)"
if grep -q "\[error\] clip" "${LOG_DIR}/unreadable.log"; then
    pass "the failed clip is reported"
else
    fail "the failed clip is reported"
fi
chmod 600 "${SANDBOX}/unreadable.txt"

# --- a file seen for the first time is not reaped ---------------------------
echo "==> first sighting"
printf 'old but new\n' > "${SANDBOX}/old-first.txt"
touch -t "${OLD_STAMP}" "${SANDBOX}/old-first.txt"
"${BIN}" run --dir "${SANDBOX}" --ttl 1 --no-trash >/dev/null 2>&1
if [[ -f "${SANDBOX}/old-first.txt" ]]; then
    pass "an expired file is not reaped before it was seen twice"
else
    fail "an expired file is not reaped before it was seen twice"
fi
rm -f "${SANDBOX}/old-first.txt"

# --- reset: existing files are leftovers, new files still work --------------
echo "==> fresh state / reset"
printf 'old leftover\n' > "${RESET_SANDBOX}/old.txt"
python3 - "${RESET_SANDBOX}/old.txt" <<'PY'
import os, sys
os.utime(sys.argv[1], (1, 1))
PY
printf 'reset-marker\n' | pbcopy
PSEUDOCOPY_STATE_ROOT="${RESET_ROOT}" "${BIN}" run --dir "${RESET_SANDBOX}" --ttl 1 --no-trash > "${LOG_DIR}/reset.log" 2>&1
STATUS=$?
check_eq "the reset cycle exits 0" "0" "${STATUS}"
if [[ ! -f "${RESET_SANDBOX}/old.txt" ]]; then
    pass "an expired leftover is reaped"
else
    fail "an expired leftover is reaped"
fi
check_eq "a leftover is not copied onto the clipboard" "reset-marker" "$(pbpaste)"
if grep -q "leftovers" "${LOG_DIR}/reset.log"; then
    pass "the reset is logged"
else
    fail "the reset is logged"
fi
printf 'new after reset\n' > "${RESET_SANDBOX}/new.txt"
PSEUDOCOPY_STATE_ROOT="${RESET_ROOT}" "${BIN}" run --dir "${RESET_SANDBOX}" --ttl 3600 >/dev/null 2>&1
PSEUDOCOPY_STATE_ROOT="${RESET_ROOT}" "${BIN}" run --dir "${RESET_SANDBOX}" --ttl 3600 >/dev/null 2>&1
check_eq "a file that arrives after the reset is copied" "new after reset" "$(pbpaste)"

# --- a damaged state file is moved aside and rebuilt ------------------------
echo "==> corrupt state"
mkdir -p "${CORRUPT_ROOT}"
printf '{ this is not json' > "${CORRUPT_ROOT}/state.json"
PSEUDOCOPY_STATE_ROOT="${CORRUPT_ROOT}" "${BIN}" run --dir "${CORRUPT_SANDBOX}" > "${LOG_DIR}/corrupt.log" 2>&1
STATUS=$?
check_eq "the corrupt-state cycle exits 0" "0" "${STATUS}"
if [[ -f "${CORRUPT_ROOT}/state.json.corrupt" ]]; then
    pass "the damaged state file is kept as state.json.corrupt"
else
    fail "the damaged state file is kept as state.json.corrupt"
fi
if python3 - "${CORRUPT_ROOT}/state.json" <<'PY' 2>/dev/null
import json, sys
json.load(open(sys.argv[1]))
PY
then
    pass "the state file is rebuilt as valid JSON"
else
    fail "the state file is rebuilt as valid JSON"
fi

# --- a partially damaged state file is recovered ---------------------------
echo "==> lenient state recovery"
LENIENT_SANDBOX="${LOG_DIR}/lenient-watch"
LENIENT_ROOT="${LOG_DIR}/lenient-state"
mkdir -p "${LENIENT_SANDBOX}" "${LENIENT_ROOT}"
LENIENT_KEY="$(cd "${LENIENT_SANDBOX}" && pwd -P)"
python3 - "${LENIENT_ROOT}/state.json" "${LENIENT_KEY}" <<'PY'
import json, sys, time
path, key = sys.argv[1], sys.argv[2]
data = {
    "version": 1,
    "dirs": {key: {"broken": "not a record"}},
    "lastScan": {key: {}},
    "seen": {key: time.time() - 978307200},
    "clipErrors": {},
}
with open(path, "w") as fh:
    json.dump(data, fh)
PY
PSEUDOCOPY_STATE_ROOT="${LENIENT_ROOT}" "${BIN}" run --dir "${LENIENT_SANDBOX}" > "${LOG_DIR}/lenient.log" 2>&1
STATUS=$?
check_eq "a partially damaged state file does not fail the cycle" "0" "${STATUS}"
if [[ -f "${LENIENT_ROOT}/state.json.corrupt" ]]; then
    pass "the partially damaged state file is kept"
else
    fail "the partially damaged state file is kept"
fi
python3 - "${LENIENT_ROOT}/state.json" "${LENIENT_KEY}" <<'PY'
import json, sys, time
data = json.load(open(sys.argv[1]))
key = sys.argv[2]
seen = data.get("seen", {}).get(key)
assert seen is not None, "seen is missing"
assert seen > 0, "seen is not a reference-date timestamp"
assert abs(seen - (time.time() - 978307200)) < 86400, "seen was shifted by the 1970/2001 epoch"
assert key in data.get("lastScan", {}), "lastScan was not recovered"
PY
if [[ $? -eq 0 ]]; then
    pass "the recovered timestamp keeps the reference-date epoch"
else
    fail "the recovered timestamp keeps the reference-date epoch"
fi

# --- a state file from a newer version is left alone ------------------------
echo "==> newer state"
NEWER_ROOT="${LOG_DIR}/newer-state"
mkdir -p "${NEWER_ROOT}"
printf '{"version":2,"dirs":{},"lastScan":{},"seen":{},"clipErrors":{}}\n' > "${NEWER_ROOT}/state.json"
BEFORE_HASH="$(shasum -a 256 "${NEWER_ROOT}/state.json" | cut -d' ' -f1)"
PSEUDOCOPY_STATE_ROOT="${NEWER_ROOT}" "${BIN}" run --dir "${CORRUPT_SANDBOX}" > "${LOG_DIR}/newer.log" 2>&1
STATUS=$?
check_eq "a newer state file does not fail the cycle" "0" "${STATUS}"
AFTER_HASH="$(shasum -a 256 "${NEWER_ROOT}/state.json" | cut -d' ' -f1)"
check_eq "a newer state file is not overwritten" "${BEFORE_HASH}" "${AFTER_HASH}"
if grep -q "newer than" "${LOG_DIR}/newer.log"; then
    pass "a newer state file is reported"
else
    fail "a newer state file is reported"
fi

# --- the settings file ------------------------------------------------------
echo "==> settings file"
CONFIG_FILE="${STATE_ROOT}/config.json"

"${BIN}" config list > "${LOG_DIR}/config-list.log" 2>&1
STATUS=$?
check_eq "config list exits 0" "0" "${STATUS}"
if grep -q "settings file:" "${LOG_DIR}/config-list.log"; then
    pass "config list prints the settings file"
else
    fail "config list prints the settings file"
fi
for key in dir ttl interval permanent verbose log-path state-dir \
           text-limit embed-limit materialise-limit; do
    if grep -q "$key" "${LOG_DIR}/config-list.log"; then
        pass "config list shows ${key}"
    else
        fail "config list shows ${key}"
    fi
done

"${BIN}" config set ttl 600 > "${LOG_DIR}/config-set.log" 2>&1
STATUS=$?
check_eq "config set exits 0" "0" "${STATUS}"
if python3 - "${CONFIG_FILE}" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("ttl") == 600, data
PY
then
    pass "the setting is stored in the settings file"
else
    fail "the setting is stored in the settings file"
fi
check_eq "the setting is used" "600s" "$("${BIN}" config get ttl)"
check_eq "the command line wins over the file" "42s" "$("${BIN}" --ttl 42 config get ttl)"

"${BIN}" config unset ttl >/dev/null 2>&1
check_eq "a setting can be unset" "3600s" "$("${BIN}" config get ttl)"

# A value that the guard refuses must not be stored.
"${BIN}" config set dir / >/dev/null 2>&1
check_eq "the watch-folder guard also applies to settings" "1" "$?"
"${BIN}" config set dir "$HOME" >/dev/null 2>&1
check_eq "the home folder is refused in the settings too" "1" "$?"
check_eq "the refused value was not stored" "$HOME/Temp" "$("${BIN}" config get dir)"

# A broken settings file must not stop the tool from working.
printf '{ not json' > "${CONFIG_FILE}"
"${BIN}" config list >/dev/null 2>&1
check_eq "a damaged settings file does not break config list" "0" "$?"
if [[ -f "${CONFIG_FILE}.corrupt" ]]; then
    pass "the damaged settings file is kept"
else
    fail "the damaged settings file is kept"
fi
"${BIN}" config reset >/dev/null 2>&1
check_eq "config reset removes the settings file" "0" "$?"
if [[ -f "${CONFIG_FILE}" ]]; then
    fail "config reset removes the settings file"
else
    pass "config reset removes the settings file"
fi

# --- watch directory guards -------------------------------------------------
echo "==> watch directory guards"
"${BIN}" run --dir "${HOME}" >/dev/null 2>&1
check_eq "the home folder is refused" "1" "$?"
"${BIN}" run --dir /tmp >/dev/null 2>&1
check_eq "the shared temp root is refused" "1" "$?"
"${BIN}" run --dir /var >/dev/null 2>&1
check_eq "the system var root is refused" "1" "$?"
"${BIN}" run --dir "/Users/pseudocopy-smoke-other-user-$$" >/dev/null 2>&1
check_eq "another user's home folder is refused" "1" "$?"
VOLUME_TEST="/Volumes/pseudocopy-smoke-no-such-volume-$$"
"${BIN}" run --dir "${VOLUME_TEST}" >/dev/null 2>&1
STATUS=$?
check_eq "a missing external volume is refused" "1" "${STATUS}"
if [[ ! -e "${VOLUME_TEST}" ]]; then
    pass "the refused volume path is not created"
else
    fail "the refused volume path is not created"
fi

# --- the pasteboard representation of every file type ----------------------
echo "==> clipboard representations"
TYPES="${LOG_DIR}/types"
mkdir -p "${TYPES}"
if python3 - "${TYPES}" <<'PY'
import base64, pathlib, sys

root = pathlib.Path(sys.argv[1])
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
(root / "pixel.png").write_bytes(png)
(root / "mislabelled.jpg").write_bytes(png)   # PNG bytes, .jpg name
(root / "photo.webp").write_bytes(png)        # PNG bytes, .webp name
(root / "notes.txt").write_text("first line\nsecond line\n")
(root / "Dockerfile").write_text("FROM alpine\nRUN echo hi\n")
(root / "payload.bin").write_bytes(b"binary\x00data\x01\x02")

objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 5 0 R >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 6 0 R >>",
    "<< /Length 0 >>\nstream\n\nendstream",
    "<< /Length 0 >>\nstream\n\nendstream",
]
pdf = "%PDF-1.4\n"
offsets = []
for index, body in enumerate(objects):
    offsets.append(len(pdf.encode()))
    pdf += f"{index + 1} 0 obj\n{body}\nendobj\n"
start = len(pdf.encode())
pdf += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n"
for offset in offsets:
    pdf += f"{offset:010d} 00000 n \n"
pdf += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n"
(root / "two-pages.pdf").write_bytes(pdf.encode())
PY
then
    pass "the type fixtures are written"
else
    fail "the type fixtures are written"
fi

# A PDF keeps all pages as document data, and carries the file itself so a
# target that cannot take PDF data still gets the whole document.
"${BIN}" clip "${TYPES}/two-pages.pdf" > "${LOG_DIR}/clip-pdf.log" 2>&1
STATUS=$?
check_eq "a PDF clip exits 0" "0" "${STATUS}"
check_eq "the whole PDF is on the pasteboard" "$(stat -f %z "${TYPES}/two-pages.pdf")" "$(pb_size com.adobe.pdf)"
if pb_file_urls | grep -q "two-pages.pdf"; then
    pass "a PDF carries a file reference for file-aware apps"
else
    fail "a PDF carries a file reference for file-aware apps"
fi
if grep -q "has 2 pages" "${LOG_DIR}/clip-pdf.log"; then
    pass "the multi-page warning is logged"
else
    fail "the multi-page warning is logged"
fi

# Text must be visible to both the legacy and the modern pasteboard clients.
"${BIN}" clip "${TYPES}/notes.txt" >/dev/null 2>&1
if pb_has public.utf8-plain-text; then
    pass "text is offered as UTF-8"
else
    fail "text is offered as UTF-8"
fi
if pb_has public.plain-text; then
    pass "text is offered under the modern UTI"
else
    fail "text is offered under the modern UTI"
fi
check_eq "the text is unchanged" "first line" "$(pb_string public.plain-text | head -1)"
if pb_has public.file-url; then
    fail "a single text clip carries no file reference"
else
    pass "a single text clip carries no file reference"
fi

# The bytes decide the type, not the name.
"${BIN}" clip "${TYPES}/mislabelled.jpg" >/dev/null 2>&1
check_eq "a PNG named .jpg is advertised as PNG" "70" "$(pb_size public.png)"
if pb_has public.jpeg; then
    fail "a PNG named .jpg is not advertised as JPEG"
else
    pass "a PNG named .jpg is not advertised as JPEG"
fi

"${BIN}" clip "${TYPES}/photo.webp" >/dev/null 2>&1
check_eq "a PNG named .webp is advertised as PNG" "70" "$(pb_size public.png)"
if pb_has public.file-url; then
    fail "an image outside the old extension list is not a file reference"
else
    pass "an image outside the old extension list is not a file reference"
fi

# A file with no extension is text when its bytes are text…
"${BIN}" clip "${TYPES}/Dockerfile" >/dev/null 2>&1
check_eq "an extensionless text file is pasted as text" "FROM alpine" "$(pb_string public.plain-text | head -1)"

# …and stays a file when its bytes are binary.
"${BIN}" clip "${TYPES}/payload.bin" >/dev/null 2>&1
if pb_file_urls | grep -q "payload.bin"; then
    pass "an extensionless binary file carries a file reference"
else
    fail "an extensionless binary file carries a file reference"
fi
if pb_has public.utf8-plain-text; then
    fail "an extensionless binary file is not pasted as text"
else
    pass "an extensionless binary file is not pasted as text"
fi

# --- result -----------------------------------------------------------------
echo
if [[ "${FAILURES}" -eq 0 ]]; then
    echo "smoke test passed"
    exit 0
fi
echo "smoke test failed: ${FAILURES} check(s) did not pass"
exit 1
