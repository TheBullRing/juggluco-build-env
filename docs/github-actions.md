# GitHub Actions Integration

This document explains the two-repo CI architecture for Juggluco.

---

## Two-repo architecture

There are two separate repositories with separate responsibilities:

| Repository | Responsibility | Workflow |
|---|---|---|
| **`TheBullRing/juggluco-build-env`** (this repo) | Owns the Docker build environment (Dockerfile, scripts). Its CI only verifies that the Docker image builds successfully on every PR. | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |
| **`j-kaltes/Juggluco`** | The Juggluco source code. Its CI compiles the APK using the Docker image from this repo. | [`docs/juggluco-ci.yml`](./juggluco-ci.yml) ← copy this into `j-kaltes/Juggluco` |

> **Important:** the APK build workflow does **not** live here. It lives in
> `j-kaltes/Juggluco`. The file [`docs/juggluco-ci.yml`](./juggluco-ci.yml)
> is the ready-to-use workflow to copy to
> `j-kaltes/Juggluco/.github/workflows/ci.yml`.

---

## Table of contents

1. [This repo — Docker image build check](#1-this-repo--docker-image-build-check)
2. [Juggluco repo — APK build workflow](#2-juggluco-repo--apk-build-workflow)
3. [How the two repos interact](#3-how-the-two-repos-interact)
4. [Setting up the APK workflow in j-kaltes/Juggluco](#4-setting-up-the-apk-workflow-in-j-kaltesJuggluco)
5. [Reading workflow results](#5-reading-workflow-results)
6. [Downloading build artifacts](#6-downloading-build-artifacts)
7. [Customising the APK workflow](#7-customising-the-apk-workflow)
8. [Troubleshooting](#8-troubleshooting)
9. [Security notes](#9-security-notes)

---

## 1. This repo — Docker image build check

**File:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)

**Trigger:** pull requests to any branch of `TheBullRing/juggluco-build-env`.  
**Does NOT trigger on push to `master`/`main`** — setup commits do not waste runner minutes.

**Pipeline:**

```
checkout juggluco-build-env
        │
        ▼
docker build  ←── Dockerfile
        │           (verify image builds without errors)
        ▼
      done — no APK compilation
```

The only question this workflow answers is: *"Does the Dockerfile still build
cleanly after this PR?"*

---

## 2. Juggluco repo — APK build workflow

**File:** [`docs/juggluco-ci.yml`](./juggluco-ci.yml) — copy to
`j-kaltes/Juggluco/.github/workflows/ci.yml`

**Trigger:** pull requests to any branch of `j-kaltes/Juggluco`.

**Pipeline:**

```
checkout j-kaltes/Juggluco  (→ Juggluco/)
checkout TheBullRing/juggluco-build-env  (→ juggluco-build-env/)
        │
        ▼
restore Docker layer cache
        │
        ▼
docker build juggluco-build-env/Dockerfile  →  juggluco-build-env:ci
        │
        ▼
docker run → validate.sh   (checks SDK, NDK, CMake, Java, gradlew …)
        │
        ▼
docker run → build.sh MobileLibre3SiDexNogoogleRelease
        │         (gradlew assemble → collect APK)
        │
        ▼
upload APK artifact  (14-day retention)
upload build log     (14-day retention)
```

The build runs entirely inside the container — the GitHub Actions runner only
needs Docker. No Android SDK, NDK, or Java is installed on the runner.

---

## 3. How the two repos interact

During the APK workflow the runner checks out **both** repositories side by side:

```
$GITHUB_WORKSPACE/
├── Juggluco/             ← j-kaltes/Juggluco source
└── juggluco-build-env/   ← TheBullRing/juggluco-build-env (Dockerfile + scripts)
```

Both directories are then bind-mounted into the container:

```
/workspace/Juggluco          ← Juggluco source inside container
/workspace/juggluco-build-env ← scripts/validate.sh, scripts/build.sh
```

---

## 4. Setting up the APK workflow in j-kaltes/Juggluco

1. Copy [`docs/juggluco-ci.yml`](./juggluco-ci.yml) into the Juggluco repo at
   `.github/workflows/ci.yml`.
2. Commit and push (or open a PR in Juggluco).
3. The workflow fires automatically on every subsequent PR.

No secrets are required — all repositories involved are public.

---

## 5. Reading workflow results

After opening a PR in `j-kaltes/Juggluco`:

1. Go to the PR page and scroll to the **Checks** section.
2. Click **"Build APK"** to open the Actions run.
3. Expand any step to read its log output.

A ✅ means the APK compiled without errors. A ❌ means a step failed; expand
the failed step's log to see the error.

---

## 6. Downloading build artifacts

1. Open the Actions run in `j-kaltes/Juggluco`.
2. Scroll to the **Artifacts** section at the bottom of the Summary page.
3. Download `juggluco-apk-<run_number>` for the APK, or
   `build-log-<run_number>` for the full Gradle log.

Artifacts are retained for 14 days.

---

## 7. Customising the APK workflow

### 7.1 Building a different variant

In [`docs/juggluco-ci.yml`](./juggluco-ci.yml), change the variant argument
passed to `build.sh`:

```yaml
bash /workspace/juggluco-build-env/scripts/build.sh YourVariantName
```

### 7.2 Building multiple variants in parallel

Use a matrix:

```yaml
jobs:
  build:
    strategy:
      matrix:
        variant:
          - MobileLibre3SiDexNogoogleRelease
          - AnotherVariant
    steps:
      ...
      - name: Build Juggluco APK
        run: |
          docker run --rm ... \
            -c "bash /workspace/juggluco-build-env/scripts/build.sh ${{ matrix.variant }}"
```

### 7.3 Persisting the Gradle cache across runs

Add a cache step before the Docker build step:

```yaml
- name: Cache Gradle
  uses: actions/cache@v4
  with:
    path: ~/.gradle/caches
    key: ${{ runner.os }}-gradle-${{ hashFiles('**/*.gradle*') }}
    restore-keys: ${{ runner.os }}-gradle-
```

Then mount it into the container:

```
-v "$HOME/.gradle:/home/juggluco/.gradle"
```

---

## 8. Troubleshooting

### The first run takes 15–20 minutes
The Docker layer cache is empty on the first run. Subsequent runs will be
faster (typically 5–8 minutes) once the cache is warm.

### `Cache Docker layers` step shows "Cache not found"
Normal on the first run. The cache is populated after the first successful
build.

### `Build Docker image` fails with a network error
Transient GitHub Actions network issue. Re-run the workflow from the Actions UI.

### `Validate prerequisites` fails with "NDK not found"
The NDK version declared in the Dockerfile does not match what is expected by
`validate.sh`. Update the NDK version in `Dockerfile` or `validate.sh` to match.

### `Build Juggluco APK` fails with "Permission denied" on `build.log`
The `ci-artifacts` directory on the runner must be writable. Ensure the
`Prepare artifact output directory` step runs before the build step.

### Build fails with a Gradle or CMake error
Check `build-log-<run_number>` artifact for the full error. This is typically
a source-code issue in Juggluco, not a build-environment issue.

### The APK artifact is not uploaded (warning on the upload step)
The build failed before producing an APK. The `build-log` artifact will
contain the Gradle error that explains the failure.

---

## 9. Security notes

- No secrets or credentials are used. All source repositories are public.
- The Docker image is built fresh from the `Dockerfile` on every run —
  no pre-built image is pulled from an external registry.
- The container runs as the unprivileged `juggluco` user, not as root.
- Artifacts (APK, logs) are scoped to the repository and accessible only to
  collaborators with read access.
