#!/bin/bash
# entrypoint.sh
#
# Handles two operating modes, selected by the MODE env var:
#
#   MODE=clone  (default)
#       Sources were baked into the image via `git clone` at build time.
#       Nothing to do — just start sshd.
#
#   MODE=volume
#       The project folder is bind-mounted from the host (Windows/Mac/Linux).
#       On Windows/Mac (Docker Desktop) files appear owned by uid 0.
#       On Linux hosts they appear owned by the host user's uid (typically 1000).
#       This script detects the actual uid of the mounted files and re-maps the
#       `juggluco` user to that uid so it can read/write the mount freely.
#       It also:
#         - Injects jniLibs if not already present (extracted from the baked copy)
#         - Fixes CRLF line endings and marks gradlew executable
#         - Restores git symlinks that Windows git checked out as plain text files
#         - Writes local.properties if it does not exist
#
set -e

WORKSPACE=/workspace/Juggluco
MODE="${MODE:-clone}"

# ── helpers ───────────────────────────────────────────────────────────────────

ensure_local_properties() {
    if [ ! -f "$WORKSPACE/local.properties" ]; then
        printf "sdk.dir=/opt/android-sdk\ncmake.dir=/opt/android-sdk/cmake/4.1.2\n" \
            > "$WORKSPACE/local.properties"
        echo "[entrypoint] Created local.properties"
    fi
}

# In volume mode the host bind-mount shadows /workspace/Juggluco entirely, so
# the jniLibs that were extracted there at image build time are gone.
# The Dockerfile preserves a copy at /workspace/jniLibs-baked/ (outside the
# mount point).  Copy them into the appropriate location inside the mount so
# the build can find them.
inject_jni_libs() {
    local BAKED_ROOT="/workspace/jniLibs-baked"
    # Try the most common extraction layout first; fall back to a flat jniLibs dir.
    local SRC=""
    if [ -d "$BAKED_ROOT/Common/src/main/jniLibs" ]; then
        SRC="$BAKED_ROOT/Common/src/main/jniLibs"
        local TARGET_JNI="$WORKSPACE/Common/src/main/jniLibs"
    elif [ -d "$BAKED_ROOT/jniLibs" ]; then
        SRC="$BAKED_ROOT/jniLibs"
        local TARGET_JNI="$WORKSPACE/jniLibs"
    fi

    if [ -n "$SRC" ] && [ ! -d "$TARGET_JNI" ]; then
        echo "[entrypoint] Injecting jniLibs from baked image copy ($SRC)..."
        mkdir -p "$(dirname "$TARGET_JNI")"
        cp -r "$SRC" "$TARGET_JNI"
        echo "[entrypoint] jniLibs injected."
    elif [ -z "$SRC" ]; then
        echo "[entrypoint] WARNING: /workspace/jniLibs-baked/ not found — jniLibs not injected."
    else
        echo "[entrypoint] jniLibs already present at $TARGET_JNI — skipping injection."
    fi
}

fix_text_files() {
    echo "[entrypoint] Fixing CRLF line endings and execute bits..."
    find "$WORKSPACE" -type f \( \
        -name "gradlew"        -o \
        -name "*.sh"           -o \
        -name "*.bash"         -o \
        -name "*.gradle"       -o \
        -name "*.kts"          -o \
        -name "*.py"           -o \
        -name "*.mk"           -o \
        -name "Makefile"       -o \
        -name "*.cmake"        -o \
        -name "*.properties"   \
    \) -exec dos2unix -q {} \; 2>/dev/null || true

    find "$WORKSPACE" -name "gradlew" -exec chmod a+x {} \; 2>/dev/null || true
}

# Restore git symlinks that Windows checked out as plain text files.
# Git stores symlinks with mode 120000; on Windows without core.symlinks=true
# they become regular files whose content is the link target path.
# Inside the Linux container we can recreate them properly.
restore_symlinks() {
    echo "[entrypoint] Restoring git symlinks..."
    cd "$WORKSPACE"

    # Tell git that symlinks are supported in this environment
    git config core.symlinks true

    # List every blob git tracks as a symlink (mode 120000), then for each one:
    #   - read the target path (the file's text content)
    #   - replace the plain-text stub with a real symlink
    git ls-files -s | awk '/^120000/ {print $4}' | while IFS= read -r path; do
        target=$(cat "$path" 2>/dev/null) || continue
        # Only act if the current entry is a plain file (not already a symlink)
        if [ -f "$path" ] && [ ! -L "$path" ]; then
            echo "[entrypoint]   $path -> $target"
            rm -f "$path"
            ln -s "$target" "$path"
        fi
    done

    echo "[entrypoint] Symlink restore done."
}

# ── main ──────────────────────────────────────────────────────────────────────

case "$MODE" in

  clone)
    echo "[entrypoint] Mode: clone — using sources baked into the image."
    ensure_local_properties
    ;;

  volume)
    echo "[entrypoint] Mode: volume — bind-mount at $WORKSPACE"

    if [ ! -d "$WORKSPACE" ]; then
        echo "[entrypoint] ERROR: $WORKSPACE not found. Did you forget to set HOST_SRC?"
        exit 1
    fi

    # Detect the uid that owns the mounted files.
    # Docker Desktop (Windows & Mac) presents them as uid 0.
    # Linux hosts present them as the actual host uid.
    MOUNT_UID=$(stat -c '%u' "$WORKSPACE")
    MOUNT_GID=$(stat -c '%g' "$WORKSPACE")
    echo "[entrypoint] Mounted files owned by uid=$MOUNT_UID gid=$MOUNT_GID"

    JUGGLUCO_UID=$(id -u juggluco)
    JUGGLUCO_GID=$(id -g juggluco)

    if [ "$MOUNT_UID" = "0" ]; then
        # Docker Desktop (Windows / Mac): files appear as root.
        # juggluco already has passwordless sudo, so it can write them.
        echo "[entrypoint] Docker Desktop mode detected (uid 0 mount)."
        echo "[entrypoint] juggluco can use 'sudo' to write to the mount."
    elif [ "$MOUNT_UID" != "$JUGGLUCO_UID" ]; then
        # Linux host with a different uid: re-map juggluco to match.
        echo "[entrypoint] Remapping juggluco uid $JUGGLUCO_UID → $MOUNT_UID"
        usermod -u "$MOUNT_UID" juggluco
        groupmod -g "$MOUNT_GID" juggluco 2>/dev/null || true
        # Fix ownership of juggluco's home and the SDK (baked in as old uid)
        find /home/juggluco /opt/android-sdk -xdev \
            \( -uid "$JUGGLUCO_UID" -o -gid "$JUGGLUCO_GID" \) \
            -exec chown "$MOUNT_UID:$MOUNT_GID" {} \; 2>/dev/null || true
    else
        echo "[entrypoint] uid already matches ($MOUNT_UID) — no remapping needed."
    fi

    inject_jni_libs
    restore_symlinks
    fix_text_files
    ensure_local_properties
    ;;

  *)
    echo "[entrypoint] Unknown MODE='$MODE'. Valid values: clone | volume"
    exit 1
    ;;
esac

echo "[entrypoint] Starting sshd..."
exec /usr/sbin/sshd -D -e
