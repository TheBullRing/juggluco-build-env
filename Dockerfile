FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    file \
    dos2unix \
    ca-certificates \
    openssh-server \
    git \
    wget \
    unzip \
    zip \
    curl \
    nano \
    vim \
    build-essential \
    ninja-build \
    pkg-config \
    cmake \
    libicu-dev \
    python3 \
    python3-pip \
    openjdk-21-jdk \
    sudo \
    locales \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# ── Android SDK ────────────────────────────────────────────────────────────────
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools

RUN wget -q \
    https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip \
    -O /tmp/cmdtools.zip && \
    unzip -q /tmp/cmdtools.zip -d /tmp && \
    mkdir -p ${ANDROID_HOME}/cmdline-tools/latest && \
    mv /tmp/cmdline-tools/* ${ANDROID_HOME}/cmdline-tools/latest && \
    rm -f /tmp/cmdtools.zip

ENV PATH=${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}

RUN yes | sdkmanager --licenses

RUN sdkmanager \
    "platform-tools" \
    "platforms;android-36" \
    "build-tools;36.0.0" \
    "cmake;4.1.2" \
    "ndk;30.0.14904198"

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

# ── Workspace ownership ────────────────────────────────────────────────────────
RUN mkdir -p /workspace && \
    chown -R juggluco:juggluco /workspace && \
    chown -R juggluco:juggluco /opt/android-sdk

# ── Clone Juggluco (baked into image for clone-mode) ──────────────────────────
USER juggluco
WORKDIR /workspace

RUN git clone --recurse-submodules https://github.com/j-kaltes/Juggluco.git

# Copy pre-built native libraries, extract them, and keep a baked reference copy
# at /workspace/jniLibs-baked/ so entrypoint.sh can inject them in volume mode
# (the bind-mount shadows /workspace/Juggluco entirely at runtime).
COPY --chown=juggluco:juggluco jniLibs.zip /workspace/Juggluco/
WORKDIR /workspace/Juggluco
RUN unzip -q jniLibs.zip && rm -f jniLibs.zip && \
    cp -r --parents Common/src/main/jniLibs /workspace/jniLibs-baked/ 2>/dev/null || \
    cp -r --parents jniLibs /workspace/jniLibs-baked/ 2>/dev/null || true

# Write local.properties pointing at the in-image SDK
RUN printf "sdk.dir=/opt/android-sdk\ncmake.dir=/opt/android-sdk/cmake/4.1.2\n" \
    > local.properties

# ── Build scripts (available inside the container) ────────────────────────────
COPY --chown=juggluco:juggluco scripts/ /workspace/juggluco-build-env/scripts/
RUN chmod +x /workspace/juggluco-build-env/scripts/*.sh

# ── Entrypoint (runs as root so it can remap uids / start sshd) ───────────────
USER root

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
