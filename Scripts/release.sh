#!/usr/bin/env bash
#
# Build a universal release binary and publish it on GitHub.
#
#   Scripts/release.sh
#
# The version comes from `Constants.version`; bump it (and CHANGELOG.md)
# before running this. The script refuses to work on a dirty tree and on an
# existing tag, so a failed run can be repeated after the problem is fixed.
#
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

VERSION="$(sed -n 's/^    static let version = "\([^"]*\)"$/\1/p' Sources/pseudocopy/constants.swift)"
[[ -n "${VERSION}" ]] || fail "could not read Constants.version"
TAG="v${VERSION}"

[[ -z "$(git status --porcelain)" ]] || fail "the working tree is dirty — commit or stash first"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && fail "tag ${TAG} already exists"
git remote get-url origin >/dev/null 2>&1 || fail "no 'origin' remote"
command -v gh >/dev/null || fail "gh is not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

echo "==> pseudocopy ${VERSION}"

echo "==> building arm64"
swift build -c release --arch arm64

echo "==> building x86_64 (takes a minute)"
swift build -c release --arch x86_64

ARM_BINARY=".build/arm64-apple-macosx/release/pseudocopy"
X86_BINARY=".build/x86_64-apple-macosx/release/pseudocopy"
[[ -f "${ARM_BINARY}" ]] || fail "missing ${ARM_BINARY}"
[[ -f "${X86_BINARY}" ]] || fail "missing ${X86_BINARY}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-release.XXXXXX")"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pseudocopy-release-tests.XXXXXX")"
trap 'rm -rf "${STAGE}" "${SANDBOX}"' EXIT

cp README.md LICENSE "${STAGE}/"
lipo -create \
    "${ARM_BINARY}" \
    "${X86_BINARY}" \
    -output "${STAGE}/pseudocopy"

# lipo invalidates the linker's ad-hoc signature; sign the fat binary again.
codesign --force --sign - "${STAGE}/pseudocopy"
lipo -info "${STAGE}/pseudocopy"

echo "==> checking the binary"
[[ "$("${STAGE}/pseudocopy" version)" == "pseudocopy ${VERSION}" ]] \
    || fail "the binary reports a version other than ${VERSION}"
"${STAGE}/pseudocopy" gen-tests "${SANDBOX}" >/dev/null
FILES="$(find "${SANDBOX}" -type f | wc -l | tr -d ' ')"
[[ "${FILES}" == "8" ]] || fail "gen-tests wrote ${FILES} files, expected 8"

mkdir -p dist
TARBALL="pseudocopy-${VERSION}-macos-universal.tar.gz"
tar -czf "dist/${TARBALL}" -C "${STAGE}" pseudocopy README.md LICENSE
(cd dist && shasum -a 256 "${TARBALL}" > "${TARBALL}.sha256")
SHA="$(cut -d' ' -f1 "dist/${TARBALL}.sha256")"

# The tap formula points at the asset above.
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__SHA256__/${SHA}/g" \
    Distribution/homebrew/pseudocopy.rb.template > "dist/pseudocopy.rb"

echo "==> tagging ${TAG}"
git tag -a "${TAG}" -m "pseudocopy ${VERSION}"
git push origin HEAD
git push origin "${TAG}"

echo "==> publishing the release"
NOTES="$(mktemp "${TMPDIR:-/tmp}/pseudocopy-notes.XXXXXX")"
cat > "${NOTES}" <<EOF
Watches a folder, copies every new finished file to the clipboard (text,
image, PDF or file reference) and moves files older than an hour to the
Trash. A launchd LaunchAgent runs one cycle every five seconds; no daemon,
no menu bar icon, no dependencies.

## Install with Homebrew

    brew install BitPeppr/tap/pseudocopy
    brew services start pseudocopy

## Install the binary by hand

    tar -xzf pseudocopy-${VERSION}-macos-universal.tar.gz
    mkdir -p ~/bin && cp pseudocopy ~/bin/
    ~/bin/pseudocopy install --dir ~/Temp

The tarball is a universal binary (arm64 + x86_64) for macOS 13 or newer.
It is ad-hoc signed, not notarised: download it with \`curl\`, not with a
browser, or Gatekeeper will quarantine it.

See the README for the full manual, the caveats and the log format.
EOF
gh release create "${TAG}" \
    "dist/${TARBALL}" \
    "dist/${TARBALL}.sha256" \
    --title "pseudocopy ${VERSION}" \
    --notes-file "${NOTES}"
rm -f "${NOTES}"

cat <<EOF

Done.

  release : $(gh release view "${TAG}" --json url --jq .url)
  tap     : copy dist/pseudocopy.rb to Formula/pseudocopy.rb in
            https://github.com/BitPeppr/homebrew-tap and commit it.

EOF
