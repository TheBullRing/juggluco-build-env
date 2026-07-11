# Juggluco — Docker Build Environment

[![CI](https://github.com/TheBullRing/juggluco-build-env/actions/workflows/ci.yml/badge.svg)](https://github.com/TheBullRing/juggluco-build-env/actions/workflows/ci.yml)

Building Juggluco requires the Android SDK, NDK, CMake, Java 21, and several native
libraries. Setting all of this up natively on Windows is not viable due to missing
Linux toolchain dependencies. This repository provides a ready-made Linux Docker build
environment that works identically on Windows, Mac, and Linux host machines.

---

## Repository layout

```
juggluco-build-env/
├── Dockerfile                  # Image definition
├── docker-compose.yml          # Service profiles (clone + volume)
├── entrypoint.sh               # Container startup script
├── jniLibs.zip                 # Pre-built native libraries
├── scripts/
│   ├── build.sh                # Builds an APK variant; collects artifacts
│   └── validate.sh             # Checks all prerequisites before building
├── .github/
│   └── workflows/
│       └── ci.yml              # GitHub Actions CI (PR + push)
├── .devcontainer/
│   └── devcontainer.json       # VS Code Dev Containers config
└── README.md                   # This file
```

---

## Prerequisites

- A Docker runtime — **Docker Desktop** or **Rancher Desktop** on Windows/Mac;
  **Docker Engine** on Linux. See the platform-specific section below.
- Docker Compose v2 (`docker compose` — note: no hyphen).
- An SSH client (`ssh` is built into Windows 10+, Mac, and all Linux distros) —
  only needed for the SSH workflow; not required for Dev Containers.

---

## Two operating modes

### Mode 1 — Clone (self-contained)

The image bakes a full `git clone` of Juggluco at **image build time**. The container
is entirely self-contained — no host files are needed.

**When to use:**
- You want to build the project and get an APK without any local checkout.
- You do not need to edit sources between builds.
- CI / GitHub Actions.

**Limitation:** Source changes require rebuilding the image (`docker compose build`).

---

### Mode 2 — Volume (edit on host, build in container)

Your local clone of Juggluco is **bind-mounted** into the container at
`/workspace/Juggluco`. You edit files with your normal editor on the host; the
container compiles them. Changes are visible instantly — no image rebuild needed.

**When to use:**
- Active development with your preferred editor.
- VS Code Dev Containers.

**Platform behaviour of bind-mounts:**

| Platform | How Docker presents mounted files inside the container |
|---|---|
| **Windows** | All files appear owned by `uid 0` (root). Use `sudo ./gradlew ...` inside the container. |
| **Mac** (Docker Desktop / VirtioFS) | Same as Windows — files appear as `uid 0`. |
| **Linux** | Files appear with the actual host uid. The entrypoint remaps `juggluco` to match automatically. |

The entrypoint script runs at every container start and automatically:
- Injects pre-built jniLibs from the baked image copy (if not already present).
- Restores **git symlinks** that Windows git checked out as plain text files.
- Converts **CRLF line endings** to LF on shell/Gradle/CMake scripts.
- Makes `gradlew` executable.
- Creates `local.properties` pointing at the SDK if it does not already exist.

---

## Quick start

All commands below are run from the **repository root**
(the folder that contains `Dockerfile`, `docker-compose.yml`, and `scripts/`).

---

### Step 1 — Build the Docker image (one-time, ~10–20 min)

Downloads Android SDK, NDK, CMake, Java 21, and clones the full Juggluco repository
inside the image. The resulting image is approximately 6 GB.

```bash
docker compose build
```

Wait for this to complete before proceeding.

---

### Step 2 — Choose a mode

| | Clone mode | Volume mode |
|---|---|---|
| **Sources** | Baked into the image | Mounted live from host |
| **Edit files on host?** | No — rebuild image for changes | Yes — instantly visible |
| **Best for** | Just getting an APK / CI | Active development |
| **VS Code Dev Containers** | Attach manually | One-click via `.devcontainer/` ✓ |

---

### Step 2A — Start in Clone mode

```bash
docker compose up -d
```

---

### Step 2B — Start in Volume mode

Set `HOST_SRC` to the absolute path of your local Juggluco clone, then:

```bash
# bash (Mac / Linux):
HOST_SRC=$HOME/path/to/Juggluco docker compose --profile volume up -d

# PowerShell (Windows):
$env:HOST_SRC = "C:\Users\you\Juggluco"
docker compose --profile volume up -d
```

---

### Step 3 — Verify the container started

```bash
docker ps
# Expect: juggluco-dev (clone) or juggluco-dev-volume (volume)
```

Watch the entrypoint output (useful on first start):

```bash
docker logs -f juggluco-dev
# or:
docker logs -f juggluco-dev-volume
```

Wait until you see `Starting sshd...` before connecting.

---

### Step 4 — Connect via SSH

```bash
ssh -p 2222 juggluco@localhost
# password: juggluco
```

The container exposes SSH on port **2222**.

---

### Step 5 — Build inside the container

Once connected via SSH:

```bash
cd /workspace/Juggluco
```

**Clone mode** (juggluco owns the files):
```bash
bash /workspace/juggluco-build-env/scripts/build.sh MobileLibre3SiDexNogoogleRelease
```

**Volume mode on Windows / Mac** (files owned by root):
```bash
sudo bash /workspace/juggluco-build-env/scripts/build.sh MobileLibre3SiDexNogoogleRelease
```

**Volume mode on Linux** (`juggluco` uid is remapped automatically — no sudo needed):
```bash
bash /workspace/juggluco-build-env/scripts/build.sh MobileLibre3SiDexNogoogleRelease
```

Or run Gradle directly:
```bash
./gradlew assembleMobileLibre3SiDexNogoogleRelease
```

**APK output location:**
```
Common/build/outputs/apk/<variant-lowercase>/release/*.apk
```

**Collected artifacts** (APK + build log) are written to `/workspace/artifacts/` by default.

---

### Available build variants

Pass any of the following as the argument to `build.sh` (or append to `./gradlew assemble`):

| Variant argument | Description |
|---|---|
| `MobileLibre3SiDexNogoogleRelease` | Mobile, no Google Play Services (**default**) |
| `MobileLibre3SiDexGoogleRelease` | Mobile, with Google Play Services |
| `WearLibre3SiDexNogoogleRelease` | Wear OS |

---

## Scripts

### `scripts/validate.sh`

Checks that every prerequisite is present before attempting a build:
- Java 21+
- `ANDROID_HOME` set and populated
- `sdkmanager`, platform-tools, build-tools `36.0.0`
- Platform SDK `android-36`
- NDK `30.0.14904198`
- CMake `4.1.2`
- `gradlew` present and executable
- `local.properties` containing `sdk.dir`
- `git`, `dos2unix`

```bash
WORKSPACE=/workspace/Juggluco bash /workspace/juggluco-build-env/scripts/validate.sh
```

Exit code 0 means all checks passed. Non-zero exits with a descriptive error.

---

### `scripts/build.sh`

Full build pipeline:
1. Runs `validate.sh`.
2. Runs `git submodule update --init --recursive`.
3. Invokes `./gradlew assemble<VARIANT> --no-daemon --stacktrace`.
4. Copies the APK and build log to `$ARTIFACTS_DIR` (default `/workspace/artifacts`).

```bash
# Usage:
bash /workspace/juggluco-build-env/scripts/build.sh [VARIANT]

# Environment overrides:
WORKSPACE=/workspace/Juggluco \
ARTIFACTS_DIR=/tmp/my-artifacts \
  bash /workspace/juggluco-build-env/scripts/build.sh MobileLibre3SiDexGoogleRelease
```

On build failure the last 40 lines of the log are printed to stderr for quick triage.

---

## CI / GitHub Actions

The workflow in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every
**pull request** and on every **push** to `main`/`master`.

**What it does:**
1. Checks out this repository.
2. Builds the Docker image (with layer cache to avoid redundant re-downloads).
3. Validates prerequisites inside the container.
4. Builds `MobileLibre3SiDexNogoogleRelease` inside the container.
5. Uploads the APK as a downloadable artifact (retained 14 days).
6. Uploads the full build log as a downloadable artifact (retained 14 days).

**To enable CI** for your fork: update the badge URL at the top of this README with
your GitHub organisation/user name.

For the complete step-by-step guide — enabling the workflow, reading results,
downloading artifacts, adding the status badge, customising variants, persisting
the Gradle cache, and troubleshooting — see
**[docs/github-actions.md](docs/github-actions.md)**.

---

## Platform-specific notes

### Windows

Building natively on Windows is very complex and not recommended (missing Linux
toolchain dependencies). Docker or WSL2 are strongly preferred.

#### Option A — Docker Desktop (easiest)

Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).
Enable the **WSL2 backend** during installation (recommended over Hyper-V).

#### Option B — Rancher Desktop (free, open-source)

[Rancher Desktop](https://rancherdesktop.io/) — choose **dockerd (moby)** as the
container engine. Uses WSL2 under the hood; behaviour is identical to Docker Desktop.

#### Option C — WSL2 directly (no Docker)

```powershell
wsl --install -d Ubuntu-24.04
```

Clone the repository **inside WSL** (`/home/<user>/`), **not** on the Windows
filesystem (`/mnt/c/...`). Install dependencies as per the `Dockerfile` and build
with `./gradlew` directly — no Docker needed.

#### Common Windows notes

- Git symlinks checked out as plain text files are repaired automatically by the
  entrypoint in Volume mode.
- CRLF line endings are fixed automatically.
- Files mounted from Windows appear as `uid 0` — prefix Gradle commands with `sudo`.
- Port 2222 is managed automatically by Docker Desktop / Rancher Desktop.

---

### Mac

- [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/) works
  on both Apple Silicon and Intel.
- [Rancher Desktop](https://rancherdesktop.io/) is a free alternative — choose
  **dockerd (moby)**.
- VirtioFS (default since Docker Desktop 4.6) presents mounted files as `uid 0`,
  same as Windows. The entrypoint handles this identically.
- No symlink or CRLF issues on Mac.

---

### Linux

```bash
# Ubuntu / Debian:
sudo apt-get install docker.io docker-compose-v2
sudo usermod -aG docker $USER   # log out and back in
```

- Mounted files appear with your real host uid. The entrypoint calls `usermod` to
  remap `juggluco` — no `sudo` is needed for builds.
- No symlink or CRLF issues.

---

## IDE integration

### VS Code — Remote SSH (works with both modes)

Install [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh).
Add a host:

```
ssh juggluco@localhost -p 2222
```

Open `/workspace/Juggluco` as the remote folder. Terminal, IntelliSense, build
tasks, and debugger all run inside the container.

---

### VS Code — Dev Containers (volume mode — recommended for development)

The [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
extension attaches VS Code directly to the running container — no SSH needed.

1. Install the Dev Containers extension.
2. Start the volume-mode container:
   ```bash
   HOST_SRC=$HOME/path/to/Juggluco docker compose --profile volume up -d
   ```
3. **Ctrl+Shift+P → "Dev Containers: Attach to Running Container"** → select
   `juggluco-dev-volume`.

   **Or** open this repository folder in VS Code and click **"Reopen in Container"**
   when prompted — VS Code starts and attaches to the container automatically.

4. Open `/workspace/Juggluco` as the workspace folder.
5. Build from the integrated terminal:
   ```bash
   # Windows / Mac (uid 0 mount):
   sudo bash /workspace/juggluco-build-env/scripts/build.sh

   # Linux (uid remapped automatically):
   bash /workspace/juggluco-build-env/scripts/build.sh
   ```

Recommended extensions (Kotlin, Java, Gradle, C/C++, CMake Tools, GitLens) are
installed automatically from `.devcontainer/devcontainer.json`.

---

### JetBrains Gateway (IntelliJ IDEA, Android Studio)

1. Open JetBrains Gateway → **Connect via SSH**.
2. Host: `localhost`, Port: `2222`, User: `juggluco`, Password: `juggluco`.
3. Choose the IDE and open `/workspace/Juggluco`.

---

## Container management

```bash
# Stop (keeps container state):
docker compose stop

# Remove container (image is kept; next `up` recreates it):
docker compose down

# Remove container + image (forces full rebuild next time):
docker compose down --rmi local
```

---

## Gradle cache

The Gradle cache lives at `/home/juggluco/.gradle` inside the container. It persists
as long as the container exists but is lost on `docker compose down`. To preserve it
across container rebuilds, add a named volume to `docker-compose.yml`:

```yaml
volumes:
  gradle-cache:

services:
  juggluco-dev:
    volumes:
      - gradle-cache:/home/juggluco/.gradle
```

---

## SSH key authentication (optional)

```bash
ssh-copy-id -p 2222 juggluco@localhost
```

---

## Updating build dependencies

| Dependency | Where to change | Current version |
|---|---|---|
| Android Command Line Tools | `Dockerfile` — `wget` URL | 13114758 |
| Android Platform SDK | `Dockerfile` — `sdkmanager` + `validate.sh` | android-36 |
| Android Build Tools | `Dockerfile` — `sdkmanager` + `validate.sh` | 36.0.0 |
| Android NDK | `Dockerfile` — `sdkmanager` + `validate.sh` | 30.0.14904198 |
| CMake (Android SDK) | `Dockerfile` — `sdkmanager` + `validate.sh` + `local.properties` | 4.1.2 |
| JDK | `Dockerfile` — `apt-get` + `validate.sh` | 21 |
| Ubuntu base | `Dockerfile` — `FROM` | 24.04 |

After changing `Dockerfile`, rebuild the image:
```bash
docker compose build
```
