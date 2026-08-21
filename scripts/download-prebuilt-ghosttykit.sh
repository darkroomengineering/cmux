#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${GHOSTTY_SHA:-}" ]; then
  GHOSTTY_SHA="$GHOSTTY_SHA"
else
  if [ ! -d "$REPO_ROOT/ghostty" ] || ! git -C "$REPO_ROOT/ghostty" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Missing ghostty submodule. Run ./scripts/setup.sh or git submodule update --init --recursive first." >&2
    exit 1
  fi
  GHOSTTY_SHA="$(git -C "$REPO_ROOT/ghostty" rev-parse HEAD)"
fi

TAG="xcframework-$GHOSTTY_SHA"
ARCHIVE_NAME="${GHOSTTYKIT_ARCHIVE_NAME:-GhosttyKit.xcframework.tar.gz}"
OUTPUT_DIR="${GHOSTTYKIT_OUTPUT_DIR:-GhosttyKit.xcframework}"
CHECKSUMS_FILE="${GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
DOWNLOAD_URL="${GHOSTTYKIT_URL:-https://github.com/darkroomengineering/ghostty/releases/download/$TAG/$ARCHIVE_NAME}"
DOWNLOAD_RETRIES="${GHOSTTYKIT_DOWNLOAD_RETRIES:-2}"
DOWNLOAD_RETRY_DELAY="${GHOSTTYKIT_DOWNLOAD_RETRY_DELAY:-20}"
PLIST_BUDDY="${GHOSTTYKIT_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"

if [ ! -f "$CHECKSUMS_FILE" ]; then
  echo "Missing checksum file: $CHECKSUMS_FILE" >&2
  exit 1
fi

EXPECTED_SHA256="$(
  awk -v sha="$GHOSTTY_SHA" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CHECKSUMS_FILE" || true
)"

if [ -z "$EXPECTED_SHA256" ]; then
  echo "Missing pinned GhosttyKit checksum for ghostty $GHOSTTY_SHA in $CHECKSUMS_FILE." >&2
  echo "The Build GhosttyKit workflow publishes release xcframework-$GHOSTTY_SHA; add its sha256 to $CHECKSUMS_FILE." >&2
  exit 1
fi

OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
OUTPUT_BASENAME="$(basename "$OUTPUT_DIR")"
case "$OUTPUT_DIR" in
  ""|*/)
    echo "Unsafe GhosttyKit output path: $OUTPUT_DIR" >&2
    exit 1
    ;;
esac
case "$OUTPUT_BASENAME" in
  ""|.|..|/|*[!A-Za-z0-9._+@-]*)
    echo "Unsafe GhosttyKit output path: $OUTPUT_DIR" >&2
    exit 1
    ;;
esac
mkdir -p "$OUTPUT_PARENT"
if [ -e "$OUTPUT_DIR" ] || [ -L "$OUTPUT_DIR" ]; then
  OUTPUT_EXISTED=1
else
  OUTPUT_EXISTED=0
fi

TEMP_ROOT="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_BASENAME}.download.XXXXXX")"
TEMP_ARCHIVE="$TEMP_ROOT/archive.tar.gz"
EXTRACT_DIR="$TEMP_ROOT/extracted"
ARCHIVE_NAMES="$TEMP_ROOT/archive-names.txt"
ARCHIVE_TYPES="$TEMP_ROOT/archive-types.txt"
INSTALL_HELPER_SOURCE="$TEMP_ROOT/install-helper.c"
INSTALL_HELPER="$TEMP_ROOT/install-helper"

cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$TEMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Downloading $ARCHIVE_NAME for ghostty $GHOSTTY_SHA"
if ! curl --fail --show-error --location \
  --retry "$DOWNLOAD_RETRIES" \
  --retry-delay "$DOWNLOAD_RETRY_DELAY" \
  --retry-all-errors \
  -o "$TEMP_ARCHIVE" \
  "$DOWNLOAD_URL"; then
  echo "curl download failed for $DOWNLOAD_URL" >&2
  echo "Run the Build GhosttyKit workflow for ghostty $GHOSTTY_SHA and retry." >&2
  exit 1
fi

ACTUAL_SHA256="$(shasum -a 256 "$TEMP_ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "$ARCHIVE_NAME checksum mismatch" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

if ! TAR_OPTIONS= LC_ALL=C /usr/bin/tar -tzf "$TEMP_ARCHIVE" > "$ARCHIVE_NAMES" ||
    ! TAR_OPTIONS= LC_ALL=C /usr/bin/tar -tvzf "$TEMP_ARCHIVE" > "$ARCHIVE_TYPES"; then
  echo "Unable to inspect $ARCHIVE_NAME" >&2
  exit 1
fi

# bsdtar escapes control characters in list output. Accepting only the narrow
# filename grammar used by GhosttyKit keeps this line-oriented preflight
# unambiguous, including for entries containing newlines or backslashes.
if ! /usr/bin/awk -v expected_root="$OUTPUT_BASENAME" '
  NR == FNR {
    entry_type[FNR] = substr($0, 1, 1)
    entry_is_hardlink[FNR] = index($0, " link to ") != 0
    type_count = FNR
    next
  }

  {
    name_count++
    path = $0
    type = entry_type[FNR]

    if (path == "" || path !~ /^[A-Za-z0-9._+@\/-]+$/ ||
        substr(path, 1, 1) == "/" || index(path, "//") != 0) {
      exit 1
    }

    normalized = path
    if (substr(normalized, length(normalized), 1) == "/") {
      normalized = substr(normalized, 1, length(normalized) - 1)
    }
    if (normalized == "") {
      exit 1
    }

    component_count = split(normalized, component, "/")
    if (component[1] != expected_root) {
      exit 1
    }
    for (component_index = 1; component_index <= component_count; component_index++) {
      if (component[component_index] == "" || component[component_index] == "." || component[component_index] == "..") {
        exit 1
      }
    }

    if ((type != "d" && type != "-") || entry_is_hardlink[FNR]) {
      exit 1
    }
    if (normalized == expected_root) {
      root_count++
      if (type != "d") {
        exit 1
      }
    }
  }

  END {
    if (name_count == 0 || name_count != type_count || root_count != 1) {
      exit 1
    }
  }
' "$ARCHIVE_TYPES" "$ARCHIVE_NAMES"; then
  echo "$ARCHIVE_NAME contains unsafe or unexpected archive entries" >&2
  exit 1
fi

mkdir "$EXTRACT_DIR"
TAR_OPTIONS= LC_ALL=C /usr/bin/tar -xzf "$TEMP_ARCHIVE" \
  --no-same-owner \
  --no-same-permissions \
  -C "$EXTRACT_DIR"
EXTRACTED_FRAMEWORK="$EXTRACT_DIR/$OUTPUT_BASENAME"

is_safe_relative_path() {
  case "$1" in
    ""|/*|*//*|.|..|./*|*/./*|*/.|../*|*/../*|*/..)
      return 1
      ;;
  esac
}

cat > "$INSTALL_HELPER_SOURCE" <<'EOF'
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#elif defined(__linux__)
#define _GNU_SOURCE 1
#else
#error "The atomic GhosttyKit installer supports only Apple and Linux platforms"
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int validate_path(const char *root, const char *path, int require_directory) {
    struct stat root_status;
    struct stat path_status;
    char canonical_root[PATH_MAX];
    char canonical_path[PATH_MAX];
    size_t root_length;

    if (lstat(root, &root_status) != 0 || !S_ISDIR(root_status.st_mode)) {
        fprintf(stderr, "Invalid validation root: %s\n", root);
        return 1;
    }
    if (lstat(path, &path_status) != 0 ||
        (require_directory ? !S_ISDIR(path_status.st_mode) : !S_ISREG(path_status.st_mode))) {
        fprintf(stderr, "Required %s is missing or has the wrong type: %s\n",
                require_directory ? "directory" : "file", path);
        return 1;
    }
    if (realpath(root, canonical_root) == NULL || realpath(path, canonical_path) == NULL) {
        fprintf(stderr, "Unable to resolve required path: %s\n", path);
        return 1;
    }

    root_length = strlen(canonical_root);
    if (strncmp(canonical_root, canonical_path, root_length) != 0 ||
        canonical_path[root_length] != '/') {
        fprintf(stderr, "Required path escapes the extraction directory: %s\n", path);
        return 1;
    }
    return 0;
}

static int rename_exclusively(const char *source, const char *destination) {
#if defined(__APPLE__)
    return renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, RENAME_EXCL);
#elif defined(__linux__)
    return renameat2(AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE);
#endif
}

static int rename_exchange(const char *source, const char *destination) {
#if defined(__APPLE__)
    return renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, RENAME_SWAP);
#elif defined(__linux__)
    return renameat2(AT_FDCWD, source, AT_FDCWD, destination, RENAME_EXCHANGE);
#endif
}

static int install_exclusively(const char *source, const char *destination) {
    if (rename_exclusively(source, destination) == 0) {
        return 0;
    }

    fprintf(stderr, "Unable to install %s exclusively: %s\n", destination, strerror(errno));
    return 1;
}

static int replace_atomically(const char *source, const char *destination) {
    int attempt;

    for (attempt = 0; attempt < 8; attempt++) {
        if (rename_exchange(source, destination) == 0) {
            return 0;
        }
        if (errno != ENOENT) {
            fprintf(stderr, "Unable to replace %s atomically: %s\n", destination, strerror(errno));
            return 1;
        }

        if (rename_exclusively(source, destination) == 0) {
            return 0;
        }
        if (errno != EEXIST) {
            fprintf(stderr, "Unable to install %s after it disappeared: %s\n", destination, strerror(errno));
            return 1;
        }
    }

    fprintf(stderr, "Destination changed repeatedly during installation: %s\n", destination);
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "validate-file") == 0) {
        return validate_path(argv[2], argv[3], 0);
    }
    if (argc == 4 && strcmp(argv[1], "validate-directory") == 0) {
        return validate_path(argv[2], argv[3], 1);
    }
    if (argc == 4 && strcmp(argv[1], "install-new") == 0) {
        return install_exclusively(argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "replace") == 0) {
        return replace_atomically(argv[2], argv[3]);
    }

    fprintf(stderr, "Usage: %s validate-file|validate-directory|install-new|replace SOURCE DESTINATION\n", argv[0]);
    return 2;
}
EOF

case "$(uname -s)" in
  Darwin)
    INSTALL_COMPILER=(xcrun --sdk macosx clang)
    ;;
  Linux)
    INSTALL_COMPILER=("${CC:-cc}")
    ;;
  *)
    echo "Unable to compile the atomic GhosttyKit installer on this platform" >&2
    exit 1
    ;;
esac

if ! "${INSTALL_COMPILER[@]}" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -O2 \
  "$INSTALL_HELPER_SOURCE" \
  -o "$INSTALL_HELPER"; then
  echo "Unable to compile the atomic GhosttyKit installer" >&2
  exit 1
fi

validate_xcframework() {
  local framework="$1"
  local info="$framework/Info.plist"
  local package_type library_count index identifier binary_path headers_path

  "$INSTALL_HELPER" validate-directory "$EXTRACT_DIR" "$framework" || return 1
  "$INSTALL_HELPER" validate-file "$EXTRACT_DIR" "$info" || return 1
  plutil -lint "$info" >/dev/null
  package_type="$("$PLIST_BUDDY" -c 'Print :CFBundlePackageType' "$info")"
  [ "$package_type" = "XFWK" ] || return 1

  library_count="$("$PLIST_BUDDY" -c 'Print :AvailableLibraries' "$info" | grep -c 'LibraryIdentifier = ' || true)"
  [ "$library_count" -gt 0 ] || return 1

  index=0
  while [ "$index" -lt "$library_count" ]; do
    identifier="$("$PLIST_BUDDY" -c "Print :AvailableLibraries:$index:LibraryIdentifier" "$info")"
    binary_path="$("$PLIST_BUDDY" -c "Print :AvailableLibraries:$index:BinaryPath" "$info")"
    headers_path="$("$PLIST_BUDDY" -c "Print :AvailableLibraries:$index:HeadersPath" "$info")"
    is_safe_relative_path "$identifier" || return 1
    is_safe_relative_path "$binary_path" || return 1
    is_safe_relative_path "$headers_path" || return 1
    "$INSTALL_HELPER" validate-file "$EXTRACT_DIR" "$framework/$identifier/$binary_path" || return 1
    "$INSTALL_HELPER" validate-file "$EXTRACT_DIR" "$framework/$identifier/$headers_path/ghostty.h" || return 1
    "$INSTALL_HELPER" validate-file "$EXTRACT_DIR" "$framework/$identifier/$headers_path/module.modulemap" || return 1
    [ -s "$framework/$identifier/$binary_path" ] || return 1
    [ -s "$framework/$identifier/$headers_path/ghostty.h" ] || return 1
    [ -s "$framework/$identifier/$headers_path/module.modulemap" ] || return 1
    index=$((index + 1))
  done
}

if ! validate_xcframework "$EXTRACTED_FRAMEWORK"; then
  echo "Downloaded archive does not contain a complete $OUTPUT_BASENAME" >&2
  exit 1
fi

if [ "$OUTPUT_EXISTED" -eq 1 ]; then
  INSTALL_OPERATION=replace
else
  INSTALL_OPERATION=install-new
fi
if ! "$INSTALL_HELPER" "$INSTALL_OPERATION" "$EXTRACTED_FRAMEWORK" "$OUTPUT_DIR"; then
  echo "Failed to install $OUTPUT_BASENAME without disturbing the existing output" >&2
  exit 1
fi

# On replacement, the atomic exchange leaves the old framework at the staged
# path. A first install leaves no staged entry.
rm -rf "$EXTRACTED_FRAMEWORK"

echo "Verified and extracted $OUTPUT_DIR"
