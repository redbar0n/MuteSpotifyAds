#!/usr/bin/env bash
set -euo pipefail

# Omit Finder extended-attribute sidecars (._*) from both portable archives.
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Use macOS's native Git; an old /usr/local/bin/git can be an incompatible Intel binary.
GIT_BIN="${GIT_BIN:-/usr/bin/git}"
SCHEME="${SCHEME:-MuteSpotifyAds}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/build-release}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/dist}"

# The Xcode target and project are still called MuteSpotifyAds; only the product was renamed
# (PRODUCT_NAME = Mutefy), so SCHEME and PROJECT_PATH keep the old name while the built app
# and the artifacts carry the new one.
PROJECT_PATH="${ROOT_DIR}/MuteSpotifyAds.xcodeproj"
APP_NAME="Mutefy.app"
APP_PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
APP_PATH="${APP_PRODUCTS_DIR}/${APP_NAME}"
BINARY_ARCHIVE_PATH="${OUTPUT_DIR}/Mutefy.app.tar.gz"
SOURCE_ARCHIVE_PATH="${OUTPUT_DIR}/Mutefy-source.tar.gz"
CHECKSUMS_PATH="${OUTPUT_DIR}/checksums.txt"

mkdir -p "${OUTPUT_DIR}" "${DERIVED_DATA_PATH}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
DERIVED_DATA_PATH="$(cd "${DERIVED_DATA_PATH}" && pwd)"
APP_PRODUCTS_DIR="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
APP_PATH="${APP_PRODUCTS_DIR}/${APP_NAME}"
BINARY_ARCHIVE_PATH="${OUTPUT_DIR}/Mutefy.app.tar.gz"
SOURCE_ARCHIVE_PATH="${OUTPUT_DIR}/Mutefy-source.tar.gz"
CHECKSUMS_PATH="${OUTPUT_DIR}/checksums.txt"

# Build the exact source we distribute, including pending changes and new source files.
# git archive HEAD would silently ship old source alongside a new working-tree binary.
SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mutefy-release.XXXXXX")"
trap 'rm -rf "${SNAPSHOT_DIR}"' EXIT
mkdir -p "${SNAPSHOT_DIR}/source"
"${GIT_BIN}" -C "${ROOT_DIR}" ls-files --cached --others --exclude-standard -z |
  while IFS= read -r -d '' relative_path; do
    if [[ -f "${ROOT_DIR}/${relative_path}" || -L "${ROOT_DIR}/${relative_path}" ]]; then
      if [[ "${relative_path}" == *.png ]] &&
        head -c 100 "${ROOT_DIR}/${relative_path}" | LC_ALL=C grep -q '^version https://git-lfs.github.com/spec/v1'; then
        echo "Unresolved Git LFS pointer: ${relative_path}. Run git lfs pull first." >&2
        exit 1
      fi
      printf '%s\0' "${relative_path}"
    fi
  done > "${SNAPSHOT_DIR}/files"
tar -C "${ROOT_DIR}" --null -T "${SNAPSHOT_DIR}/files" -czf "${SNAPSHOT_DIR}/source.tar.gz"
tar -xzf "${SNAPSHOT_DIR}/source.tar.gz" -C "${SNAPSHOT_DIR}/source"
PROJECT_PATH="${SNAPSHOT_DIR}/source/MuteSpotifyAds.xcodeproj"

echo "Building ${SCHEME} (${CONFIGURATION})..."
# `-destination generic/platform=macOS` is what makes this universal. Without it xcodebuild
# resolves the destination to this machine's own architecture and quietly produces a thin
# binary — verified: arm64 only on an Apple Silicon Mac, on a project whose README advertises
# a universal build. Check with `lipo -archs` after changing anything here.
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  clean build >/dev/null

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Build succeeded, but app not found at ${APP_PATH}" >&2
  exit 1
fi

ARCHS_BUILT="$(lipo -archs "${APP_PATH}/Contents/MacOS/${APP_NAME%.app}")"
echo "Built architectures: ${ARCHS_BUILT}"
if [[ "${ARCHS_BUILT}" != *"x86_64"* || "${ARCHS_BUILT}" != *"arm64"* ]]; then
  echo "Expected a universal binary, got: ${ARCHS_BUILT}" >&2
  exit 1
fi

echo "Creating binary archive: ${BINARY_ARCHIVE_PATH}"
tar -C "${APP_PRODUCTS_DIR}" -czf "${BINARY_ARCHIVE_PATH}" "${APP_NAME}"

echo "Creating source archive: ${SOURCE_ARCHIVE_PATH}"
cp "${SNAPSHOT_DIR}/source.tar.gz" "${SOURCE_ARCHIVE_PATH}"

echo "Generating checksums: ${CHECKSUMS_PATH}"
(cd "${OUTPUT_DIR}" && shasum -a 256 Mutefy.app.tar.gz Mutefy-source.tar.gz) > "${CHECKSUMS_PATH}"

cat <<EOF

Release artifacts created in ${OUTPUT_DIR}:
- Mutefy.app.tar.gz
- Mutefy-source.tar.gz
- checksums.txt

Upload these assets to a release at https://github.com/countnine/MuteSpotifyAds/releases.
The Homebrew cask is Casks/mutefy.rb and expects Mutefy.app.tar.gz.
EOF
