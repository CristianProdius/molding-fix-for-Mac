#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# MoldSign ePass2003 Full Fix
#
# Deploys patched OpenSC/OpenSSL x86_64 binaries and configures MoldSign
# to use libcastle-only mode for reliable STISC ePass2003 signing.
#
# Usage:
#   bash fix-moldsign-libcastle.sh [--no-restart] [--config-only]
#
# Flags:
#   --no-restart    Skip restarting MoldSign after applying fixes
#   --config-only   Only apply PKCS11.properties config fix, skip binary deployment
# =============================================================================

MOLDSIGN_DIR="${MOLDSIGN_DIR:-/Applications/STISC/MoldSign}"
NATIVE_LIB="${MOLDSIGN_DIR}/native_lib"
CFG="${MOLDSIGN_DIR}/MoldSignData/Server/PKCS11.properties"
SERVER_APP="${MOLDSIGN_DIR}/MoldSign Server.app"
DESKTOP_APP="${MOLDSIGN_DIR}/MoldSign Desktop.app"
LOG_FILE="${MOLDSIGN_DIR}/log/err_MoldSign_Server.log"

RELEASE_TAG="${RELEASE_TAG:-v1.0.0}"
REPO="CristianProdius/molding-fix-for-Mac"
TARBALL_NAME="opensc-epass2003-macos-x86_64.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${TARBALL_NAME}"

EXPECTED_FILES=(
  "native_lib/opensc-pkcs11.so"
  "native_lib/libopensc.12.dylib"
  "native_lib/libcrypto.3.dylib"
  "native_lib/ossl-modules/legacy.dylib"
)

# -- Parse flags --------------------------------------------------------------

RESTART_APPS=1
CONFIG_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --no-restart)  RESTART_APPS=0 ;;
    --config-only) CONFIG_ONLY=1 ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Usage: $0 [--no-restart] [--config-only]" >&2
      exit 1
      ;;
  esac
done

# -- Helpers -------------------------------------------------------------------

require_path() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    echo "ERROR: ${label} not found at: $path" >&2
    exit 1
  fi
}

run_copy() {
  local src="$1"
  local dst="$2"
  if [[ -w "$dst" || -w "$(dirname "$dst")" ]]; then
    cp "$src" "$dst"
  else
    sudo cp "$src" "$dst"
  fi
}

# -- Validate prerequisites ----------------------------------------------------

require_path "$MOLDSIGN_DIR" "MoldSign installation"
require_path "$CFG" "PKCS11 config"
require_path "$SERVER_APP" "MoldSign Server.app"
require_path "$DESKTOP_APP" "MoldSign Desktop.app"

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is required but not found." >&2
  exit 1
fi

ts="$(date +%Y%m%d-%H%M%S)"

echo "== MoldSign ePass2003 Full Fix =="
echo "Release:  ${RELEASE_TAG}"
echo "MoldSign: ${MOLDSIGN_DIR}"
echo

# ==============================================================================
# Phase 1: Binary Deployment
# ==============================================================================

if [[ "$CONFIG_ONLY" -eq 0 ]]; then
  echo "--- Phase 1: Binary Deployment ---"

  TMPDIR_DL="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_DL"' EXIT

  tarball="${TMPDIR_DL}/${TARBALL_NAME}"

  echo "Downloading ${TARBALL_NAME} from release ${RELEASE_TAG}..."
  curl -fSL --progress-bar -o "$tarball" "$DOWNLOAD_URL"

  # Sanity check: tarball must be > 1 MB (catches HTML error pages)
  tarball_size=$(stat -f%z "$tarball" 2>/dev/null || stat -c%s "$tarball" 2>/dev/null)
  if [[ "$tarball_size" -lt 1048576 ]]; then
    echo "ERROR: Downloaded file is only ${tarball_size} bytes — expected >1 MB." >&2
    echo "       The download URL may be invalid or the release asset missing." >&2
    exit 1
  fi
  echo "Downloaded: $(( tarball_size / 1024 )) KB"

  # Extract
  echo "Extracting..."
  tar xzf "$tarball" -C "$TMPDIR_DL"

  # Verify all expected files are present
  for f in "${EXPECTED_FILES[@]}"; do
    if [[ ! -f "${TMPDIR_DL}/${f}" ]]; then
      echo "ERROR: Expected file missing from tarball: $f" >&2
      exit 1
    fi
  done
  echo "All 4 expected files present."

  # Verify x86_64 architecture
  echo "Verifying architectures..."
  for f in "${EXPECTED_FILES[@]}"; do
    arch_info="$(file "${TMPDIR_DL}/${f}")"
    if [[ "$arch_info" != *"x86_64"* ]]; then
      echo "ERROR: ${f} is not x86_64: ${arch_info}" >&2
      exit 1
    fi
  done
  echo "All binaries confirmed x86_64."

  # Backup existing binaries
  backup_dir="${NATIVE_LIB}/backup-${ts}"
  echo "Backing up existing binaries to: ${backup_dir}"
  if [[ -w "$NATIVE_LIB" ]]; then
    mkdir -p "$backup_dir/ossl-modules"
  else
    sudo mkdir -p "$backup_dir/ossl-modules"
  fi

  for f in "${EXPECTED_FILES[@]}"; do
    src="${MOLDSIGN_DIR}/${f}"
    dst="${backup_dir}/${f#native_lib/}"
    if [[ -f "$src" ]]; then
      run_copy "$src" "$dst"
    fi
  done
  echo "Backup complete."

  # Deploy new binaries
  echo "Deploying patched binaries..."
  if [[ ! -d "${NATIVE_LIB}/ossl-modules" ]]; then
    if [[ -w "$NATIVE_LIB" ]]; then
      mkdir -p "${NATIVE_LIB}/ossl-modules"
    else
      sudo mkdir -p "${NATIVE_LIB}/ossl-modules"
    fi
  fi

  for f in "${EXPECTED_FILES[@]}"; do
    run_copy "${TMPDIR_DL}/${f}" "${MOLDSIGN_DIR}/${f}"
  done
  echo "Binary deployment complete."
  echo
else
  echo "--- Phase 1: Skipped (--config-only) ---"
  echo
fi

# ==============================================================================
# Phase 2: Config Fix (PKCS11.properties)
# ==============================================================================

echo "--- Phase 2: Config Fix ---"
echo "Config: $CFG"

cfg_backup="${CFG}.bak.auto-${ts}"
tmp_file="$(mktemp)"

run_copy "$CFG" "$cfg_backup"
echo "Config backup: $cfg_backup"

awk '
BEGIN {
  default_set = 0;
  driver_set = 0;
}
{
  if ($0 ~ /^defaultDriverPath=/) {
    print "defaultDriverPath=/Applications/STISC/MoldSign/native_lib";
    default_set = 1;
    next;
  }
  if ($0 ~ /^driver_lib=/) {
    print "driver_lib=libcastle.1.0.0.dylib";
    driver_set = 1;
    next;
  }
  print $0;
}
END {
  if (!default_set) print "defaultDriverPath=/Applications/STISC/MoldSign/native_lib";
  if (!driver_set) print "driver_lib=libcastle.1.0.0.dylib";
}
' "$CFG" > "$tmp_file"

run_copy "$tmp_file" "$CFG"
rm -f "$tmp_file"

echo "Updated config:"
grep -E '^(defaultDriverPath|driver_lib)=' "$CFG" || true
echo

# ==============================================================================
# Phase 3: Restart MoldSign
# ==============================================================================

if [[ "$RESTART_APPS" -eq 1 ]]; then
  echo "--- Phase 3: Restart ---"
  echo "Restarting MoldSign (Server first, then Desktop)..."

  osascript -e 'quit app "MoldSign Desktop"' >/dev/null 2>&1 || true
  osascript -e 'quit app "MoldSign Server"' >/dev/null 2>&1 || true
  sleep 2
  pkill -f 'MoldSign_Desk|MoldSign Desktop|MoldSign_Server|MoldSign Server|ClientCardManager' >/dev/null 2>&1 || true
  sleep 2

  open -a "$SERVER_APP"
  sleep 4
  open -a "$DESKTOP_APP"
  sleep 6

  echo "Running processes:"
  pgrep -fal 'MoldSign|MoldSign_Server|MoldSign_Desk|ClientCard' || true
  echo
else
  echo "--- Phase 3: Skipped (--no-restart) ---"
  echo
fi

# ==============================================================================
# Phase 4: Verification
# ==============================================================================

echo "--- Phase 4: Verification ---"

if [[ "$CONFIG_ONLY" -eq 0 ]]; then
  echo "Deployed binary architectures:"
  for f in "${EXPECTED_FILES[@]}"; do
    target="${MOLDSIGN_DIR}/${f}"
    if [[ -f "$target" ]]; then
      echo "  $(basename "$target"): $(file -b "$target" | grep -o 'x86_64\|arm64\|universal' || echo 'unknown')"
    fi
  done
  echo
fi

echo "Config:"
grep -E '^(defaultDriverPath|driver_lib)=' "$CFG" || true
echo

echo "Verification hints:"
echo "- Expect 1 provider and 1 certificate in: $LOG_FILE"
echo "- Expected markers: 'providers.size() = 1', 'cert to show: 1'"
echo "- Expected absence: 'opensc-pkcs11.so-0', 'PrivateKey not found'"

if [[ -f "$LOG_FILE" ]]; then
  echo
  echo "Recent log check:"
  grep -nE 'providers.size\(\) =|providerId =|cert to show:|opensc-pkcs11\.so-0|PrivateKey not found' "$LOG_FILE" | tail -n 20 || true
fi

echo
echo "Done."
