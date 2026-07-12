# =============================================================================
# Stage 1 — sdk
#   Installs the Android SDK/NDK/CMake as root so sdkmanager can run freely.
#   The SDK tree is then transferred to the final stage via COPY --chown,
#   meaning it arrives already owned by `juggluco` without any chown -R layer.
# =============================================================================
FROM ubuntu:24.04 AS sdk

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    unzip \
    ca-certificates \
    openjdk-21-jre-headless \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    wget -q \
        https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip \
        -O /tmp/cmdtools.zip && \
    unzip -q /tmp/cmdtools.zip -d /tmp && \
    mkdir -p ${ANDROID_HOME}/cmdline-tools/latest && \
    mv /tmp/cmdline-tools/* ${ANDROID_HOME}/cmdline-tools/latest && \
    rm -rf /tmp/cmdtools.zip /tmp/cmdline-tools

RUN yes | sdkmanager --licenses && \
    sdkmanager \
        "platform-tools" \
        "platforms;android-36" \
        "build-tools;36.0.0" \
        "cmake;4.1.2" \
        "ndk;30.0.14904198" && \
    # Remove NDK components not needed for a headless APK build:
    #   simpleperf   — on-device profiler     (~41 MB)
    #   shader-tools — GLSL/SPIR-V compiler   (~19 MB)
    #   sources      — NDK C library headers  (~21 MB)
    rm -rf \
        ${ANDROID_HOME}/ndk/30.0.14904198/simpleperf \
        ${ANDROID_HOME}/ndk/30.0.14904198/shader-tools \
        ${ANDROID_HOME}/ndk/30.0.14904198/sources && \
    # sdkmanager leaves an XML repository cache and JVM perf-data
    rm -rf /root/.android/cache /tmp/hsperfdata_root

# =============================================================================
# Stage 2 — final
#   Assembles the runtime image. All large trees arrive via COPY --chown so
#   they are owned correctly from the first write — no chown -R layers.
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ────────────────────────────────────────────────────────────
# build-essential / ninja-build / cmake are required: the Juggluco build has a
# host-tools step (rtlpp_host) that compiles a small native binary to run on
# the host Linux machine using the system compiler — not the Android NDK.
# We still do NOT install:
#   - python3 / pip   (not required by Gradle or the NDK build)
#   - vim / nano      (editors add ~60 MB; use `docker exec` from host)
RUN apt-get update && apt-get install -y --no-install-recommends \
    file \
    dos2unix \
    ca-certificates \
    openssh-server \
    git \
    unzip \
    curl \
    openjdk-21-jdk-headless \
    sudo \
    locales \
    build-essential \
    ninja-build \
    cmake \
    libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# Strip JDK module definitions — only needed to build JDK modules, not to run
# Gradle. Saves ~82 MB. Done in the same layer as apt to avoid a metadata copy.
RUN rm -rf /usr/lib/jvm/java-21-openjdk-amd64/jmods /tmp/hsperfdata_root

RUN locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# ── Non-root build user ────────────────────────────────────────────────────────
RUN useradd -ms /bin/bash juggluco && \
    echo "juggluco ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    echo 'juggluco:juggluco' | chpasswd

# ── SSH ────────────────────────────────────────────────────────────────────────
RUN mkdir /var/run/sshd && \
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes"  >> /etc/ssh/sshd_config && \
    echo "PermitRootLogin no"        >> /etc/ssh/sshd_config && \
    ssh-keygen -A

# ── Android SDK (transferred from stage 1, owned by juggluco from the start) ──
# COPY --chown writes files with the correct owner in a single layer.
# No chown -R is ever needed — that would duplicate 2.7 GB of metadata.
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}

COPY --from=sdk --chown=juggluco:juggluco /opt/android-sdk /opt/android-sdk

# ── Baked assets (patches + jniLibs) ──────────────────────────────────────────
# The Juggluco source is NOT cloned here. entrypoint.sh clones it on first
# container start if /workspace/Juggluco is empty. This keeps the image smaller
# and ensures clone mode always gets the latest commit.
#
# These assets are stored outside /workspace/Juggluco so they survive a volume
# bind-mount shadowing that directory. entrypoint.sh injects them after cloning
# or mounting.
USER juggluco
RUN mkdir -p /workspace/Juggluco

COPY --chown=juggluco:juggluco jniLibs.zip     /workspace/jniLibs.zip
COPY --chown=juggluco:juggluco patches/        /workspace/patches-baked/

# ── Build scripts ──────────────────────────────────────────────────────────────
COPY --chown=juggluco:juggluco scripts/ /workspace/juggluco-build-env/scripts/
RUN chmod +x /workspace/juggluco-build-env/scripts/*.sh

# ── Entrypoint (runs as root to remap uids and start sshd) ────────────────────
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
