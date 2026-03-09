#!/usr/bin/env bash
set -euo pipefail

MOLDSIGN_DIR="${MOLDSIGN_DIR:-/Applications/STISC/MoldSign}"
CFG="${MOLDSIGN_DIR}/MoldSignData/Server/PKCS11.properties"
SERVER_APP="${MOLDSIGN_DIR}/MoldSign Server.app"
DESKTOP_APP="${MOLDSIGN_DIR}/MoldSign Desktop.app"
LOG_FILE="${MOLDSIGN_DIR}/log/err_MoldSign_Server.log"

RESTART_APPS=1
if [[ "${1:-}" == "--no-restart" ]]; then
  RESTART_APPS=0
fi

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

require_path "$CFG" "PKCS11 config"
require_path "$SERVER_APP" "MoldSign Server.app"
require_path "$DESKTOP_APP" "MoldSign Desktop.app"

ts="$(date +%Y%m%d-%H%M%S)"
backup="${CFG}.bak.auto-${ts}"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

echo "== MoldSign libcastle-only fix =="
echo "Config: $CFG"

run_copy "$CFG" "$backup"
echo "Backup created: $backup"

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

echo "Updated config:"
grep -E '^(defaultDriverPath|driver_lib)=' "$CFG" || true

if [[ "$RESTART_APPS" -eq 1 ]]; then
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
fi

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
