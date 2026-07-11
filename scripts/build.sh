#!/bin/bash
# scripts/build.sh
#
# Builds a Juggluco APK variant inside the build container.
#
# Usage (inside the container):
#   ./scripts/build.sh [VARIANT]
#
# VARIANT defaults to: MobileLibre3SiDexNogoogleRelease
# Other common variants (append to ./gradlew assemble...):
#   MobileLibre3SiDexGoogleRelease
#   MobileLibre3SiDexNogoogleRelease
#   WearLibre3SiDexNogoogleRelease
#
# The APK is written to:
#   Common/build/outputs/apk/<variant-lower>/release/*.apk
#
# Artifacts (APK + build log) are copied to:
#   /workspace/artifacts/
#
# Exit codes:
#   0 — build succeeded
#   1 — prerequisite check failed
#   2 — Gradle build failed
#
set -e

WORKSPACE="${WORKSPACE:-/workspace/Juggluco}"
VARIANT="${1:-MobileLibre3SiDexNogoogleRelease}"
TASK="assemble${VARIANT}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/workspace/artifacts}"
LOG_FILE="$ARTIFACTS_DIR/build.log"

echo "[build] ============================================"
echo "[build] Juggluco build — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "[build] Workspace:  $WORKSPACE"
echo "[build] Variant:    $VARIANT"
echo "[build] Task:       ./gradlew $TASK"
echo "[build] Artifacts:  $ARTIFACTS_DIR"
echo "[build] ============================================"
echo

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
echo "[build] Running prerequisite validation..."
WORKSPACE="$WORKSPACE" bash "$(dirname "$0")/validate.sh" || {
    echo "[build] ERROR: Prerequisite check failed." >&2
    exit 1
}
echo

# ── 2. Navigate to workspace ──────────────────────────────────────────────────
cd "$WORKSPACE"

# ── 3. Submodules ─────────────────────────────────────────────────────────────
echo "[build] Initialising git submodules..."
git submodule update --init --recursive
echo "[build] Submodules ready."
echo

# ── 4. Prepare artifacts directory ───────────────────────────────────────────
mkdir -p "$ARTIFACTS_DIR"

# ── 5. Run Gradle build ───────────────────────────────────────────────────────
echo "[build] Starting Gradle build..."
set +e
./gradlew "$TASK" \
    --no-daemon \
    --stacktrace \
    2>&1 | tee "$LOG_FILE"
BUILD_EXIT=${PIPESTATUS[0]}
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
    echo
    echo "[build] ERROR: Gradle build failed (exit $BUILD_EXIT)." >&2
    echo "[build] Build log: $LOG_FILE"
    # Show the last 40 lines of the log for quick triage in CI
    echo
    echo "[build] ── Last 40 lines of build log ──────────────────"
    tail -n 40 "$LOG_FILE" >&2
    exit 2
fi

# ── 6. Collect APK artifacts ──────────────────────────────────────────────────
echo
echo "[build] Collecting APK artifacts..."
# Gradle puts APKs under Common/build/outputs/apk/<variant-lowercase>/release/
VARIANT_LOWER=$(echo "$VARIANT" | tr '[:upper:]' '[:lower:]')
APK_DIR="$WORKSPACE/Common/build/outputs/apk/$VARIANT_LOWER/release"

if [ -d "$APK_DIR" ]; then
    cp "$APK_DIR"/*.apk "$ARTIFACTS_DIR/" 2>/dev/null || true
    echo "[build] APKs:"
    ls -lh "$ARTIFACTS_DIR"/*.apk 2>/dev/null || echo "[build]   (no .apk files found in $APK_DIR)"
else
    echo "[build] WARNING: Expected APK dir not found: $APK_DIR"
    echo "[build] Searching for APKs under Common/build/outputs/..."
    find "$WORKSPACE/Common/build/outputs" -name "*.apk" -exec cp {} "$ARTIFACTS_DIR/" \; 2>/dev/null || true
    ls -lh "$ARTIFACTS_DIR"/*.apk 2>/dev/null || echo "[build]   (no APKs found)"
fi

echo
echo "[build] ============================================"
echo "[build] Build SUCCEEDED"
echo "[build] Artifacts in: $ARTIFACTS_DIR"
echo "[build] ============================================"
