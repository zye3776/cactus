#!/usr/bin/env bash
#
# check-permission-boundaries.sh
#
# Architecture §E enforcement: only PermissionsCoordinator.swift may call
# AVCaptureDevice.requestAccess or URL.startAccessingSecurityScopedResource().
#
# Invocation (per user global rule, the script is NOT chmod +x'd):
#   bash apps/CactusVoice/Scripts/check-permission-boundaries.sh
#
# Exits 0 if the rule holds, 1 otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_ROOT="$APP_ROOT/CactusVoice"
ALLOWED_FILE="Permissions/PermissionsCoordinator.swift"

if [ ! -d "$SRC_ROOT" ]; then
  echo "check-permission-boundaries: source root not found at $SRC_ROOT" >&2
  exit 2
fi

# grep -rn for both forbidden identifiers across the source tree, exclude
# the single allowed file, and fail on any remaining hit.
hits="$(grep -rn -E 'AVCaptureDevice\.requestAccess|startAccessingSecurityScopedResource' \
  --include='*.swift' "$SRC_ROOT" \
  | grep -v "$ALLOWED_FILE" || true)"

if [ -n "$hits" ]; then
  echo "check-permission-boundaries: forbidden identifier(s) used outside $ALLOWED_FILE:" >&2
  echo "$hits" >&2
  exit 1
fi

exit 0
