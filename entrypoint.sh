#!/bin/bash
# entrypoint.sh
#
# Single entry point for all three use cases:
#
#   1. Clone mode (default, no volume mount)
#        /workspace/Juggluco is empty on first start.
#        This script clones Juggluco, injects jniLibs + patches, writes
#        local.properties, then starts sshd.
#        On subsequent starts the directory is already populated — setup is
#        skipped and sshd starts immediately.
#
#   2. Volume mode (host directory bind-mounted)
#        /workspace/Juggluco is populated by the mount before this script runs.
#        This script injects jniLibs, fixes uid/CRLF/symlinks, writes
#        local.properties, then starts sshd.
#        NOTE: patch files must be applied manually by the contributor.
#        See README for the list of required patches.
#
#   3. CI mode (j-kaltes/Juggluco workflow)
#        entrypoint.sh is not called — the CI workflow uses --entrypoint /bin/bash
#        and applies patches explicitly before running build.sh.
#
set -e

WORKSPACE=/workspace/Juggluco
JUGGLUCO_REPO="https://github.com/j-kaltes/Juggluco.git"

# ── helpers ───────────────────────────────────────────────────────────────────

ensure_local_properties() {
    if [ ! -f "$WORKSPACE/local.properties" ]; then
        printf "sdk.dir=/opt/android-sdk\ncmake.dir=/opt/android-sdk/cmake/4.1.2\n" \
            > "$WORKSPACE/local.properties"
        echo "[entrypoint] Created local.properties"
    fi
}

# Extract jniLibs from the baked zip into the workspace, then keep a copy
# outside the Juggluco tree so volume-mode re-mounts can get them too.
inject_jni_libs() {
    local BAKED_ROOT="/workspace/jniLibs-baked"

    # Build the baked copy the first time (zip lives at /workspace/jniLibs.zip).
    if [ ! -d "$BAKED_ROOT" ] && [ -f "/workspace/jniLibs.zip" ]; then
        echo "[entrypoint] Extracting jniLibs from zip..."
        local TMP
        TMP=$(mktemp -d)
        unzip -q /workspace/jniLibs.zip -d "$TMP"
        if [ -d "$TMP/Common/src/main/jniLibs" ]; then
            mkdir -p "$BAKED_ROOT/Common/src/main"
            cp -r "$TMP/Common/src/main/jniLibs" "$BAKED_ROOT/Common/src/main/"
        elif [ -d "$TMP/jniLibs" ]; then
            cp -r "$TMP/jniLibs" "$BAKED_ROOT/"
        fi
        rm -rf "$TMP"
        echo "[entrypoint] jniLibs baked copy ready at $BAKED_ROOT"
    fi

    # Inject into the workspace.
    local SRC DST
    if [ -d "$BAKED_ROOT/Common/src/main/jniLibs" ]; then
        SRC="$BAKED_ROOT/Common/src/main/jniLibs"
        DST="$WORKSPACE/Common/src/main/jniLibs"
    elif [ -d "$BAKED_ROOT/jniLibs" ]; then
        SRC="$BAKED_ROOT/jniLibs"
        DST="$WORKSPACE/jniLibs"
    fi

    if [ -n "$SRC" ] && [ ! -d "$DST" ]; then
        echo "[entrypoint] Injecting jniLibs ($SRC → $DST)..."
        mkdir -p "$(dirname "$DST")"
        cp -r "$SRC" "$DST"
        echo "[entrypoint] jniLibs injected."
    elif [ -z "$SRC" ]; then
        echo "[entrypoint] WARNING: jniLibs source not found — skipping injection."
    else
        echo "[entrypoint] jniLibs already present — skipping."
    fi
}

# Inject patch files that are required to build but are not (yet) in upstream
# j-kaltes/Juggluco. Only used in clone mode; volume-mode contributors apply
# patches manually (see README).
inject_patches() {
    local BAKED="/workspace/patches-baked"

    if [ ! -d "$BAKED" ]; then
        echo "[entrypoint] WARNING: $BAKED not found — patches not injected."
        return
    fi

    find "$BAKED" -type f | while IFS= read -r src; do
        local rel="${src#$BAKED/}"
        local dst="$WORKSPACE/$rel"
        if [ ! -f "$dst" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            echo "[entrypoint] Injected patch: $rel"
        else
            echo "[entrypoint] Patch already present, skipping: $rel"
        fi
    done
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
restore_symlinks() {
    echo "[entrypoint] Restoring git symlinks..."
    cd "$WORKSPACE"
    git config core.symlinks true
    git ls-files -s | awk '/^120000/ {print $4}' | while IFS= read -r path; do
        target=$(cat "$path" 2>/dev/null) || continue
        if [ -f "$path" ] && [ ! -L "$path" ]; then
            echo "[entrypoint]   $path -> $target"
            rm -f "$path"
            ln -s "$target" "$path"
        fi
    done
    echo "[entrypoint] Symlink restore done."
}

# ── main ──────────────────────────────────────────────────────────────────────

# Determine whether the workspace already has Juggluco source.
# An empty directory (just mkdir'd by the Dockerfile) has no files.
if [ -z "$(ls -A "$WORKSPACE" 2>/dev/null)" ]; then
    # ── Clone mode: workspace is empty, clone Juggluco now ──────────────────
    echo "[entrypoint] /workspace/Juggluco is empty — cloning Juggluco..."
    # Run clone as juggluco so files are owned correctly.
    su -c "git clone --depth=1 --recurse-submodules --shallow-submodules \
        $JUGGLUCO_REPO $WORKSPACE" juggluco
    echo "[entrypoint] Clone complete."

    inject_jni_libs
    inject_patches
    ensure_local_properties

else
    # ── Volume mode: workspace is populated by the host bind-mount ───────────
    echo "[entrypoint] /workspace/Juggluco is populated — using mounted sources."

    # Detect the uid that owns the mounted files.
    # Docker Desktop (Windows & Mac) presents them as uid 0.
    # Linux hosts present them as the actual host uid.
    MOUNT_UID=$(stat -c '%u' "$WORKSPACE")
    MOUNT_GID=$(stat -c '%g' "$WORKSPACE")
    echo "[entrypoint] Mounted files owned by uid=$MOUNT_UID gid=$MOUNT_GID"

    JUGGLUCO_UID=$(id -u juggluco)
    JUGGLUCO_GID=$(id -g juggluco)

    if [ "$MOUNT_UID" = "0" ]; then
        echo "[entrypoint] Docker Desktop mode (uid 0 mount) — use sudo for writes."
    elif [ "$MOUNT_UID" != "$JUGGLUCO_UID" ]; then
        echo "[entrypoint] Remapping juggluco uid $JUGGLUCO_UID → $MOUNT_UID"
        usermod -u "$MOUNT_UID" juggluco
        groupmod -g "$MOUNT_GID" juggluco 2>/dev/null || true
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
fi

echo "[entrypoint] Starting sshd..."
exec /usr/sbin/sshd -D -e
