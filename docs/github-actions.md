# GitHub Actions Integration

This document explains how the Juggluco build environment integrates with
GitHub Actions — what the workflow does, why it is structured the way it is,
how to enable it, how to read its output, and how to extend or customise it.

---

## Table of contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Enabling the workflow](#3-enabling-the-workflow)
4. [Workflow file walkthrough](#4-workflow-file-walkthrough)
   - [Triggers](#41-triggers)
   - [Concurrency control](#42-concurrency-control)
   - [Step 1 — Checkout](#43-step-1--checkout)
   - [Step 2 — Docker Buildx](#44-step-2--docker-buildx)
   - [Step 3 — Layer cache](#45-step-3--layer-cache)
   - [Step 4 — Build the image](#46-step-4--build-the-image)
   - [Step 5 — Cache rotation](#47-step-5--cache-rotation)
   - [Step 6 — Artifact directory](#48-step-6--artifact-directory)
   - [Step 7 — Validate prerequisites](#49-step-7--validate-prerequisites)
   - [Step 8 — Build the APK](#410-step-8--build-the-apk)
   - [Step 9 — Upload APK](#411-step-9--upload-apk)
   - [Step 10 — Upload build log](#412-step-10--upload-build-log)
5. [Reading workflow results](#5-reading-workflow-results)
6. [Downloading build artifacts](#6-downloading-build-artifacts)
7. [Adding the status badge to README](#7-adding-the-status-badge-to-readme)
8. [Customising the workflow](#8-customising-the-workflow)
   - [Building a different variant](#81-building-a-different-variant)
   - [Building multiple variants in parallel](#82-building-multiple-variants-in-parallel)
   - [Changing the trigger branches](#83-changing-the-trigger-branches)
   - [Persisting the Gradle cache across runs](#84-persisting-the-gradle-cache-across-runs)
   - [Publishing the Docker image to GHCR](#85-publishing-the-docker-image-to-ghcr)
9. [Troubleshooting](#9-troubleshooting)
10. [Security notes](#10-security-notes)

---

## 1. Overview

The workflow file at [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
automates the following pipeline on every pull request and every push to
`main` or `master`:

```
checkout repo
    │
    ▼
restore Docker layer cache
    │
    ▼
docker build  ←── Dockerfile
    │               (Ubuntu 24.04 + JDK 21 + Android SDK/NDK/CMake
    │                + git clone Juggluco + jniLibs + build scripts)
    ▼
docker run → validate.sh   (checks SDK, NDK, CMake, Java, gradlew …)
    │
    ▼
docker run → build.sh MobileLibre3SiDexNogoogleRelease
    │             (git submodule update → gradlew assemble → collect APK)
    │
    ▼
upload APK artifact  (14-day retention)
upload build log     (14-day retention)
```

The build runs entirely inside the container — the GitHub Actions runner only
needs Docker. No SDK, NDK, or Java installation is required on the runner itself.

---

## 2. Prerequisites

| Requirement | Detail |
|---|---|
| **GitHub repository** | The `juggluco-build-env` repository must be hosted on GitHub. |
| **GitHub Actions enabled** | Actions are on by default for public repos; for private repos go to **Settings → Actions → General** and set *"Allow all actions and reusable workflows"*. |
| **No secrets required** | The build clones Juggluco from a public repository. No tokens, signing keys, or environment secrets are needed for the default workflow. |
| **Runner** | The workflow uses `ubuntu-latest` (a GitHub-hosted runner). No self-hosted runner is required. |

---

## 3. Enabling the workflow

The workflow file is already present at `.github/workflows/ci.yml`. GitHub
Actions picks it up automatically the moment it is pushed to the default branch.

**Step 1 — Push this repository to GitHub.**

```bash
git remote add origin https://github.com/TheBullRing/juggluco-build-env.git
git push -u origin main
```

**Step 2 — Verify Actions are enabled.**

Go to your repository on GitHub → **Actions** tab. If you see
*"Get started with GitHub Actions"* or the workflow listed, Actions are active.
If you see a banner saying Actions are disabled, click **"I understand my
workflows, go ahead and enable them"** (or enable via Settings as above).

**Step 3 — Trigger the first run.**

The workflow triggers automatically on the next push or pull request. To trigger
it immediately without a code change, use the GitHub CLI:

```bash
gh workflow run ci.yml --ref main
```

Or push any trivial change:

```bash
git commit --allow-empty -m "ci: trigger first run"
git push
```

**Step 4 — Watch the run.**

Navigate to **Actions → Juggluco CI → (latest run)**. Each step is listed with
its duration and log output.

---

## 4. Workflow file walkthrough

Full file: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)

### 4.1 Triggers

```yaml
on:
  pull_request:
    branches: ["**"]
  push:
    branches:
      - main
      - master
```

- **`pull_request`** — runs on every PR targeting any branch. This catches
  regressions before merge.
- **`push`** — runs on direct pushes to `main` / `master`. This catches
  regressions introduced by merges or direct commits.
- `branches: ["**"]` on the PR trigger means the workflow runs regardless of
  which branch the PR targets. Restrict this if needed (see
  [§ 8.3](#83-changing-the-trigger-branches)).

---

### 4.2 Concurrency control

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

If a new push is made to a branch while a CI run is already in progress for
that branch, the old run is cancelled automatically. This saves runner minutes
and keeps the Actions queue clean during rapid development.

---

### 4.3 Step 1 — Checkout

```yaml
- name: Checkout juggluco-build-env
  uses: actions/checkout@v4
```

Checks out the `juggluco-build-env` repository into the runner's workspace.
This makes `Dockerfile`, `jniLibs.zip`, `scripts/`, and `entrypoint.sh`
available as the Docker build context.

---

### 4.4 Step 2 — Docker Buildx

```yaml
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v3
```

Installs Docker Buildx, the extended Docker build client. Buildx is required
for `docker/build-push-action` and enables the local filesystem layer cache
used in the next step.

---

### 4.5 Step 3 — Layer cache

```yaml
- name: Cache Docker layers
  uses: actions/cache@v4
  with:
    path: /tmp/.buildx-cache
    key: ${{ runner.os }}-buildx-${{ hashFiles('Dockerfile') }}
    restore-keys: |
      ${{ runner.os }}-buildx-
```

**Why this matters:** The Docker image is ~6 GB and takes 10–20 minutes to
build from scratch. The layer cache stores the Buildx build output on the
Actions cache service so that unchanged layers are reused on subsequent runs.

**Cache key strategy:**

| Key | When it hits |
|---|---|
| `Linux-buildx-<sha256 of Dockerfile>` | Exact hit — `Dockerfile` has not changed since the last run. All layers are reused; the build step completes in seconds. |
| `Linux-buildx-` (prefix fallback) | Partial hit — `Dockerfile` changed but a prior cache entry exists. Changed layers are rebuilt; unchanged early layers (e.g. the `apt-get` layer) are reused. |
| No hit | Cold start — full rebuild (~10–20 min on first run or after major Dockerfile changes). |

The cache is stored per operating system and keyed to the `Dockerfile` content
hash, so a `Dockerfile` change automatically invalidates the cache.

---

### 4.6 Step 4 — Build the image

```yaml
- name: Build Docker image
  uses: docker/build-push-action@v5
  with:
    context: .
    file: Dockerfile
    tags: juggluco-build-env:ci
    load: true
    cache-from: type=local,src=/tmp/.buildx-cache
    cache-to: type=local,dest=/tmp/.buildx-cache-new,mode=max
```

Builds the image from the `Dockerfile` at the repository root. Key options:

| Option | Effect |
|---|---|
| `context: .` | Uses the repository root as the build context, so `COPY jniLibs.zip` and `COPY scripts/` resolve correctly. |
| `tags: juggluco-build-env:ci` | Names the image `juggluco-build-env:ci` in the runner's local Docker daemon. |
| `load: true` | Loads the built image into the Docker daemon (required to use it with `docker run` in later steps). |
| `cache-from` / `cache-to` | Reads from and writes to the local Buildx cache. `mode=max` caches all intermediate layers, not just the final one. |

What the image contains after this step:

- Ubuntu 24.04 base with build tools, `dos2unix`, `git`, JDK 21
- Android SDK at `/opt/android-sdk` with platform-tools, build-tools 36.0.0,
  platform android-36, NDK 30.0.14904198, CMake 4.1.2
- A full `git clone --recurse-submodules` of Juggluco at `/workspace/Juggluco`
- Extracted jniLibs inside `/workspace/Juggluco` and a reference copy at
  `/workspace/jniLibs-baked/`
- `local.properties` pointing at `/opt/android-sdk`
- Build scripts at `/workspace/juggluco-build-env/scripts/`
- `juggluco` user with passwordless sudo

---

### 4.7 Step 5 — Cache rotation

```yaml
- name: Rotate build cache
  run: |
    rm -rf /tmp/.buildx-cache
    mv /tmp/.buildx-cache-new /tmp/.buildx-cache
```

The Buildx cache grows indefinitely if new layers are appended to the old
cache directory. This step replaces the old cache directory with the freshly
written one (`-new`), keeping the cache size bounded to the layers used by
the current `Dockerfile`.

---

### 4.8 Step 6 — Artifact directory

```yaml
- name: Prepare artifact output directory
  run: mkdir -p "${{ github.workspace }}/ci-artifacts"
```

Creates `ci-artifacts/` on the runner host. This directory is bind-mounted
into the container in the build step so that the APK and build log can be
written there and subsequently uploaded as GitHub Actions artifacts.

---

### 4.9 Step 7 — Validate prerequisites

```yaml
- name: Validate prerequisites
  run: |
    docker run --rm \
      -e ANDROID_HOME=/opt/android-sdk \
      -e WORKSPACE=/workspace/Juggluco \
      --user juggluco \
      --entrypoint /bin/bash \
      juggluco-build-env:ci \
      -c "
        ANDROID_HOME=/opt/android-sdk \
        WORKSPACE=/workspace/Juggluco \
        bash /workspace/juggluco-build-env/scripts/validate.sh
      "
```

Runs [`scripts/validate.sh`](../scripts/validate.sh) inside the container
**as a separate step** before the build. This produces a clearly labelled
failure in the Actions UI if a required tool is missing — rather than a
cryptic Gradle error deep inside the build log.

Checks performed by `validate.sh`:

| Check | Expected value |
|---|---|
| `java -version` | 21.x |
| `ANDROID_HOME` | `/opt/android-sdk` (set, non-empty, directory exists) |
| `sdkmanager` binary | Present at `$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager` |
| platform-tools | `$ANDROID_HOME/platform-tools/` exists |
| build-tools | `$ANDROID_HOME/build-tools/36.0.0/` exists |
| platform SDK | `$ANDROID_HOME/platforms/android-36/` exists |
| NDK | `$ANDROID_HOME/ndk/30.0.14904198/` exists |
| CMake | `$ANDROID_HOME/cmake/4.1.2/` exists |
| `gradlew` | Present and executable at `$WORKSPACE/gradlew` |
| `local.properties` | Present; contains `sdk.dir` |
| `git` | Present in `PATH` |
| `dos2unix` | Present in `PATH` |

The step exits with code 0 only when all checks pass. Any failure produces a
message in the form `[validate] ✗ <description>` to stderr and stops the job
immediately.

---

### 4.10 Step 8 — Build the APK

```yaml
- name: Build Juggluco APK
  run: |
    docker run --rm \
      -e ANDROID_HOME=/opt/android-sdk \
      -e ANDROID_SDK_ROOT=/opt/android-sdk \
      -e GRADLE_USER_HOME=/home/juggluco/.gradle \
      -e WORKSPACE=/workspace/Juggluco \
      -e ARTIFACTS_DIR=/tmp/artifacts \
      -v "${{ github.workspace }}/ci-artifacts:/tmp/artifacts" \
      --user juggluco \
      --entrypoint /bin/bash \
      juggluco-build-env:ci \
      -c "
        set -e
        WORKSPACE=/workspace/Juggluco
        ARTIFACTS_DIR=/tmp/artifacts
        bash /workspace/juggluco-build-env/scripts/build.sh \
          MobileLibre3SiDexNogoogleRelease
      "
```

Runs [`scripts/build.sh`](../scripts/build.sh) inside the container.

**Environment variables passed to the container:**

| Variable | Value | Purpose |
|---|---|---|
| `ANDROID_HOME` | `/opt/android-sdk` | Points Gradle and the NDK at the SDK. |
| `ANDROID_SDK_ROOT` | `/opt/android-sdk` | Legacy alias required by some Gradle plugins. |
| `GRADLE_USER_HOME` | `/home/juggluco/.gradle` | Isolates the Gradle cache inside the container's home directory. |
| `WORKSPACE` | `/workspace/Juggluco` | Root of the Juggluco source tree. |
| `ARTIFACTS_DIR` | `/tmp/artifacts` | Where `build.sh` writes the APK and `build.log`. |

**Volume mount:**

```
${{ github.workspace }}/ci-artifacts  →  /tmp/artifacts (inside container)
```

The container writes the APK and build log to `/tmp/artifacts`. Because that
path is bind-mounted from the runner host at `ci-artifacts/`, those files are
immediately available to the upload steps that follow — even after the
container is removed (`--rm`).

**What `build.sh` does inside the container:**

1. Re-runs `validate.sh` (fast double-check).
2. `git submodule update --init --recursive` — ensures all Juggluco submodules
   are up to date. The clone was done at image build time; this refresh brings
   in any submodule changes made since then. In CI, the Juggluco source is
   frozen to the commit cloned when the image was built — the submodule update
   applies to that specific tree.
3. `./gradlew assembleMobileLibre3SiDexNogoogleRelease --no-daemon --stacktrace`
   — the full Gradle build. `--no-daemon` prevents Gradle from spawning a
   background daemon (unnecessary in a one-shot container). `--stacktrace`
   ensures the full stack trace appears in `build.log` on failure.
4. Copies `Common/build/outputs/apk/mobilelibre3sidexnogoogle/release/*.apk`
   to `$ARTIFACTS_DIR`.
5. Copies `build.log` to `$ARTIFACTS_DIR`.

On Gradle failure the last 40 lines of `build.log` are printed to stderr
(visible in the Actions step log) and the container exits with code 2, failing
the job.

---

### 4.11 Step 9 — Upload APK

```yaml
- name: Upload APK artifact
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: juggluco-apk-${{ github.run_number }}
    path: ci-artifacts/*.apk
    if-no-files-found: warn
    retention-days: 14
```

Uploads any `.apk` files from `ci-artifacts/` as a downloadable GitHub
Actions artifact.

| Option | Effect |
|---|---|
| `if: always()` | Runs even if the build step failed. Ensures a partial APK is not silently discarded. |
| `name: juggluco-apk-<run_number>` | Each run's artifact has a unique name, preventing collisions across runs. |
| `if-no-files-found: warn` | Emits a warning (rather than failing the job) if no APK was produced — e.g. the build failed before the APK was created. |
| `retention-days: 14` | Artifacts are automatically deleted after 14 days. Adjust as needed. |

---

### 4.12 Step 10 — Upload build log

```yaml
- name: Upload build log
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: build-log-${{ github.run_number }}
    path: ci-artifacts/build.log
    if-no-files-found: warn
    retention-days: 14
```

Uploads the full Gradle build log, including stdout from every Gradle task.
This is the primary diagnostic artifact when a build fails — the Actions step
log shows the last 40 lines, but the uploaded file contains the complete output.

---

## 5. Reading workflow results

Navigate to **GitHub → Actions → Juggluco CI** to see the list of runs.

Each run shows:

| Icon | Meaning |
|---|---|
| 🟡 Yellow spinner | In progress |
| ✅ Green check | All steps passed; APK produced |
| ❌ Red X | At least one step failed |
| ⚠️ Orange warning | Steps passed but an expected file was not found (e.g. no APK uploaded) |

Click any run to see the step-by-step breakdown. Click a step name to expand
its log. The most important steps for diagnosing failures are:

- **Validate prerequisites** — fails here if the image is broken or missing a tool.
- **Build Juggluco APK** — fails here on Gradle/CMake/resource errors. The last
  40 lines of the build log are printed inline; download the full log artifact
  for complete context.

---

## 6. Downloading build artifacts

1. Open the Actions run (via the **Actions** tab or the PR checks panel).
2. Scroll to the **Artifacts** section at the bottom of the run summary.
3. Click the artifact name to download a `.zip` containing the file(s).

| Artifact name | Contents |
|---|---|
| `juggluco-apk-<N>` | The `.apk` file produced by the build |
| `build-log-<N>` | The full Gradle build log (`build.log`) |

Artifacts are retained for **14 days** by default. After that they are
automatically deleted by GitHub.

---

## 7. Adding the status badge to README

Replace `TheBullRing` in the badge at the top of [`README.md`](../README.md) with
your actual GitHub username or organisation name:

```markdown
[![CI](https://github.com/TheBullRing/juggluco-build-env/actions/workflows/ci.yml/badge.svg)](https://github.com/TheBullRing/juggluco-build-env/actions/workflows/ci.yml)
```

The badge shows the status of the most recent run on the default branch:

| Badge | Meaning |
|---|---|
| ![passing](https://img.shields.io/badge/CI-passing-brightgreen) | Last run on default branch succeeded |
| ![failing](https://img.shields.io/badge/CI-failing-red) | Last run on default branch failed |

To show the status of a specific branch, append `?branch=<name>` to the badge URL:

```markdown
[![CI](https://github.com/TheBullRing/juggluco-build-env/actions/workflows/ci.yml/badge.svg?branch=develop)](...)
```

---

## 8. Customising the workflow

### 8.1 Building a different variant

Change the variant argument passed to `build.sh` in Step 8:

```yaml
bash /workspace/juggluco-build-env/scripts/build.sh MobileLibre3SiDexGoogleRelease
```

Available variants:

| Argument | Description |
|---|---|
| `MobileLibre3SiDexNogoogleRelease` | Mobile, no Google Play Services (default) |
| `MobileLibre3SiDexGoogleRelease` | Mobile, with Google Play Services |
| `WearLibre3SiDexNogoogleRelease` | Wear OS |

---

### 8.2 Building multiple variants in parallel

Use a matrix strategy to build all variants in parallel jobs:

```yaml
jobs:
  build:
    name: Build ${{ matrix.variant }}
    runs-on: ubuntu-latest
    timeout-minutes: 60

    strategy:
      fail-fast: false          # continue other variants if one fails
      matrix:
        variant:
          - MobileLibre3SiDexNogoogleRelease
          - MobileLibre3SiDexGoogleRelease
          - WearLibre3SiDexNogoogleRelease

    steps:
      # ... (all existing steps unchanged until Step 8) ...

      - name: Build Juggluco APK
        run: |
          docker run --rm \
            -e ANDROID_HOME=/opt/android-sdk \
            -e ANDROID_SDK_ROOT=/opt/android-sdk \
            -e GRADLE_USER_HOME=/home/juggluco/.gradle \
            -e WORKSPACE=/workspace/Juggluco \
            -e ARTIFACTS_DIR=/tmp/artifacts \
            -v "${{ github.workspace }}/ci-artifacts:/tmp/artifacts" \
            --user juggluco \
            --entrypoint /bin/bash \
            juggluco-build-env:ci \
            -c "
              set -e
              WORKSPACE=/workspace/Juggluco
              ARTIFACTS_DIR=/tmp/artifacts
              bash /workspace/juggluco-build-env/scripts/build.sh \
                ${{ matrix.variant }}
            "

      - name: Upload APK artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: juggluco-apk-${{ matrix.variant }}-${{ github.run_number }}
          path: ci-artifacts/*.apk
          if-no-files-found: warn
          retention-days: 14
```

Each variant runs as an independent job. The Docker image is shared from cache,
so the 6 GB build step is not repeated.

---

### 8.3 Changing the trigger branches

To restrict PR runs to PRs targeting `main` only:

```yaml
on:
  pull_request:
    branches:
      - main
  push:
    branches:
      - main
```

To also run on tags (e.g. for release builds):

```yaml
on:
  pull_request:
    branches: ["**"]
  push:
    branches:
      - main
      - master
    tags:
      - "v*"
```

---

### 8.4 Persisting the Gradle cache across runs

By default the Gradle cache lives inside the container and is discarded when
the container exits. Downloads are re-done on every run from the Gradle
distribution server and Maven Central.

To persist the cache between runs, mount a named host directory and cache it
via `actions/cache`:

```yaml
- name: Cache Gradle dependencies
  uses: actions/cache@v4
  with:
    path: ~/.gradle-ci-cache
    key: ${{ runner.os }}-gradle-${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties') }}
    restore-keys: |
      ${{ runner.os }}-gradle-

- name: Build Juggluco APK
  run: |
    mkdir -p ~/.gradle-ci-cache
    docker run --rm \
      -e ANDROID_HOME=/opt/android-sdk \
      -e ANDROID_SDK_ROOT=/opt/android-sdk \
      -e GRADLE_USER_HOME=/gradle-cache \
      -e WORKSPACE=/workspace/Juggluco \
      -e ARTIFACTS_DIR=/tmp/artifacts \
      -v "${{ github.workspace }}/ci-artifacts:/tmp/artifacts" \
      -v "$HOME/.gradle-ci-cache:/gradle-cache" \
      --user juggluco \
      --entrypoint /bin/bash \
      juggluco-build-env:ci \
      -c "
        set -e
        WORKSPACE=/workspace/Juggluco
        ARTIFACTS_DIR=/tmp/artifacts
        bash /workspace/juggluco-build-env/scripts/build.sh \
          MobileLibre3SiDexNogoogleRelease
      "
```

With a warm Gradle cache, subsequent builds are significantly faster because
Gradle does not re-download the distribution zip or dependency JARs.

---

### 8.5 Publishing the Docker image to GHCR

To push the built image to the GitHub Container Registry so other workflows
or contributors can pull it without rebuilding:

```yaml
- name: Log in to GitHub Container Registry
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

- name: Build and push Docker image
  uses: docker/build-push-action@v5
  with:
    context: .
    file: Dockerfile
    tags: |
      ghcr.io/${{ github.repository_owner }}/juggluco-build-env:latest
      ghcr.io/${{ github.repository_owner }}/juggluco-build-env:${{ github.sha }}
    push: ${{ github.ref == 'refs/heads/main' }}   # only push on main branch
    load: ${{ github.ref != 'refs/heads/main' }}   # load locally on PRs
    cache-from: type=local,src=/tmp/.buildx-cache
    cache-to: type=local,dest=/tmp/.buildx-cache-new,mode=max
```

`GITHUB_TOKEN` is provided automatically by GitHub Actions and has write
permission to the repository's container registry. No additional secret
configuration is needed.

---

## 9. Troubleshooting

### The first run takes 15–20 minutes

Expected. The Docker image is ~6 GB and must be built from scratch on the
first run (no cache exists yet). Subsequent runs that don't change
`Dockerfile` complete in 2–5 minutes using the layer cache.

### `Cache Docker layers` step shows "Cache not found"

The cache is keyed to the `Dockerfile` content hash. A new cache is created
after the first successful build and reused from the second run onward.

### `Build Docker image` fails with a network error

The Dockerfile downloads the Android Command Line Tools during `docker build`.
Transient network failures on the GitHub Actions runner are rare but possible.
Re-running the workflow from the **Actions** tab (click **"Re-run all jobs"**)
resolves most cases.

### `Validate prerequisites` fails with "NDK 30.0.14904198 not found"

The Docker image was not rebuilt after a `Dockerfile` change, or the cache
restored an old image layer. Force a full rebuild by deleting the cache entry:

```bash
gh cache delete --all           # requires GitHub CLI
```

or by adding a `cache-bust` build argument to the `Dockerfile`:

```yaml
- name: Build Docker image
  uses: docker/build-push-action@v5
  with:
    build-args: CACHE_BUST=${{ github.run_id }}
```

### `Build Juggluco APK` fails with "Permission denied" on `build.log`

The `ci-artifacts/` directory on the runner is created by the runner user but
the container writes as `juggluco` (uid 1000). Ensure the directory is world-
writable before mounting:

```yaml
- name: Prepare artifact output directory
  run: |
    mkdir -p "${{ github.workspace }}/ci-artifacts"
    chmod 777 "${{ github.workspace }}/ci-artifacts"
```

### Build fails with a Gradle or CMake error

1. Download the `build-log-<N>` artifact from the run's **Artifacts** section.
2. Search for `BUILD FAILED`, `FAILURE:`, or `error:` in the log.
3. The last 40 lines are also printed inline in the **Build Juggluco APK**
   step log in the Actions UI.

### The APK artifact is not uploaded (warning on the upload step)

The build step failed before producing an APK. The `build.log` artifact is
still uploaded (via `if: always()`) and will contain the Gradle error.

---

## 10. Security notes

- **No secrets are required** for the default workflow. Juggluco is cloned
  from a public repository; no authentication tokens are stored or passed.
- The `GITHUB_TOKEN` used in the optional GHCR push (§ 8.5) is scoped to the
  repository and expires at the end of the workflow run. It is never logged.
- The `juggluco` container user has `NOPASSWD` sudo inside the container.
  This is intentional for the local SSH workflow. In the CI workflow the
  container is always started with `--user juggluco` and `--rm`; it is
  discarded immediately after the build step completes.
- Pull request workflows from **forked** repositories run with a read-only
  `GITHUB_TOKEN` by default and cannot write artifacts to the upstream
  repository. This is the correct GitHub default and requires no special
  configuration.
