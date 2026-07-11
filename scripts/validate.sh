#!/bin/bash
# scripts/validate.sh
#
# Validates that all prerequisites for building Juggluco are present inside
# the container.  Exits with a non-zero status and a clear message for the
# first missing requirement found.
#
# Usage:
#   ./scripts/validate.sh
#
# Environment variables (all have working defaults inside the image):
#   ANDROID_HOME  — path to the Android SDK root
#   JAVA_HOME     — path to JDK 21 (auto-detected via `java` if unset)
#
set -e

PASS="[validate] ✓"
FAIL="[validate] ✗"

ok()   { echo "$PASS $*"; }
fail() { echo "$FAIL $*" >&2; exit 1; }

echo "[validate] Checking build prerequisites..."
echo

# ── Java ──────────────────────────────────────────────────────────────────────
if ! command -v java &>/dev/null; then
    fail "java not found. Install openjdk-21-jdk."
fi

JAVA_VERSION=$(java -version 2>&1 | head -1)
if ! echo "$JAVA_VERSION" | grep -qE '"(21|22|23)'; then
    fail "JDK 21+ required. Found: $JAVA_VERSION"
fi
ok "Java: $JAVA_VERSION"

# ── Android SDK ───────────────────────────────────────────────────────────────
if [ -z "$ANDROID_HOME" ]; then
    fail "ANDROID_HOME is not set."
fi
if [ ! -d "$ANDROID_HOME" ]; then
    fail "ANDROID_HOME=$ANDROID_HOME does not exist."
fi
ok "ANDROID_HOME: $ANDROID_HOME"

# sdkmanager
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
    fail "sdkmanager not found at $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
fi
ok "sdkmanager: present"

# platform-tools (adb)
if [ ! -d "$ANDROID_HOME/platform-tools" ]; then
    fail "platform-tools not found. Run: sdkmanager 'platform-tools'"
fi
ok "platform-tools: present"

# Build tools
EXPECTED_BUILD_TOOLS="36.0.0"
if [ ! -d "$ANDROID_HOME/build-tools/$EXPECTED_BUILD_TOOLS" ]; then
    fail "build-tools;$EXPECTED_BUILD_TOOLS not found. Run: sdkmanager 'build-tools;$EXPECTED_BUILD_TOOLS'"
fi
ok "build-tools: $EXPECTED_BUILD_TOOLS"

# Android platform
EXPECTED_PLATFORM="android-36"
if [ ! -d "$ANDROID_HOME/platforms/$EXPECTED_PLATFORM" ]; then
    fail "platforms;$EXPECTED_PLATFORM not found. Run: sdkmanager 'platforms;$EXPECTED_PLATFORM'"
fi
ok "platform: $EXPECTED_PLATFORM"

# NDK
EXPECTED_NDK="30.0.14904198"
if [ ! -d "$ANDROID_HOME/ndk/$EXPECTED_NDK" ]; then
    fail "NDK $EXPECTED_NDK not found. Run: sdkmanager 'ndk;$EXPECTED_NDK'"
fi
ok "NDK: $EXPECTED_NDK"

# CMake (via sdkmanager)
EXPECTED_CMAKE="4.1.2"
if [ ! -d "$ANDROID_HOME/cmake/$EXPECTED_CMAKE" ]; then
    fail "cmake;$EXPECTED_CMAKE not found. Run: sdkmanager 'cmake;$EXPECTED_CMAKE'"
fi
ok "CMake: $EXPECTED_CMAKE"

# ── Gradle wrapper ────────────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-/workspace/Juggluco}"
if [ ! -f "$WORKSPACE/gradlew" ]; then
    fail "gradlew not found at $WORKSPACE/gradlew. Is the repository cloned?"
fi
if [ ! -x "$WORKSPACE/gradlew" ]; then
    fail "gradlew at $WORKSPACE/gradlew is not executable. Run: chmod +x $WORKSPACE/gradlew"
fi
ok "gradlew: present and executable"

# ── local.properties ──────────────────────────────────────────────────────────
if [ ! -f "$WORKSPACE/local.properties" ]; then
    fail "local.properties missing at $WORKSPACE/local.properties"
fi
if ! grep -q "sdk.dir" "$WORKSPACE/local.properties"; then
    fail "local.properties does not contain sdk.dir"
fi
ok "local.properties: present"

# ── git ───────────────────────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    fail "git not found."
fi
ok "git: $(git --version)"

# ── dos2unix ──────────────────────────────────────────────────────────────────
if ! command -v dos2unix &>/dev/null; then
    fail "dos2unix not found. Install: apt-get install dos2unix"
fi
ok "dos2unix: present"

echo
echo "[validate] All prerequisites satisfied."
