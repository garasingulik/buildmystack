# Build-My-Stack — Specification

Status: living document · Last updated: 2026-09-03 · Toolchain audit: §13 (2026-09)

This document describes what the `buildmystack` repository produces today, how the
pieces fit together, the contracts each piece must honour, and the direction for
future development. It is written to be enough for a new contributor to change the
image safely without reverse-engineering every line of the `Dockerfile` and
`build_scripts/build.sh`.

---

## 1. Purpose

`buildmystack` builds a single Docker image that bundles **every toolchain needed
to build our software projects** — Node.js, Python, Go, Java, Flutter/Android,
Terraform, Kubernetes tooling, SonarScanner, and more — so that the **build
environment is identical everywhere it runs**.

The problem it solves: without it, each CI job and each developer laptop installs
its own toolchain, at its own versions, producing "works on my machine" drift and
slow pipelines that reinstall the same SDKs on every run. With it, there is **one
pinned, reproducible environment** that is:

- **Primary use — CI/CD parity.** The same image backs **GitLab CI** and **GitHub
  Actions** pipelines, so a build behaves the same in either system and the same
  as it did last week. `gitlab-runner` is installed and registered as a service
  inside the image; the GitHub Actions runner binary is bundled so the container
  can be registered as a self-hosted runner.
- **Secondary use — local development.** Developers can `docker run -it` the same
  image (or use it as a VS Code / JetBrains dev container) and immediately have
  the exact tools and versions the pipeline uses, without polluting the host.
- Also usable as a **SonarScanner CLI** wrapper (see §4.9).

Whatever consumes it, the contract is the same: **check out a repo, build it, get
the same result** — because the toolchain is baked in and version-pinned, not
assembled at job time.

### 1.1 Non-goals

- It is not a minimal/single-purpose build image. Size is traded for one
  environment that covers every stack we build.
- It does not orchestrate runners (no autoscaling, no Kubernetes executor config).
- It does not ship application code — it is infrastructure only.
- It is not intended to run the Docker daemon itself; Docker-in-Docker relies on an
  external DinD service or a mounted host socket (see §4.3).

---

## 2. Repository layout

| Path | Role |
|---|---|
| `Dockerfile` | Image definition: base OS, system packages, Docker CE, GitLab Runner, GitHub Actions runner, user model, entrypoint wiring. |
| `build_scripts/build.sh` | Runs **once at image build time** as the `runner` user. Installs Homebrew, asdf, and every language/CLI toolchain; writes `~/.profile`. |
| `docker-entrypoint.sh` | Container entrypoint. Dispatches between interactive shell, SonarScanner wrapper, and pass-through exec. |
| `.gitlab-ci.yml` | Pipeline that builds and pushes the image to the GitLab Container Registry as `:latest` on the default branch. |
| `.github/workflows/docker-publish.yml` | Workflow that builds and pushes the image to Docker Hub (`feedsbrain/buildmystack`) on a published release. |
| `README.md` | One-line description. |
| `docs/SPEC.md` | This document. |

---

## 3. High-level architecture

```
                     ┌─────────────────────────────────────────────┐
                     │ Image build (Dockerfile)                     │
                     │                                             │
  ubuntu:noble ───▶  │ 1. apt: build-essential, git, GTK/Flutter    │
                     │    deps, python build deps, cmake/ninja      │
                     │ 2. Docker CE + buildx + compose plugins      │
                     │ 3. gitlab-runner (apt repo)                  │
                     │ 4. libssl1.1 (Debian bullseye .deb) for      │
                     │    legacy binary compatibility               │
                     │ 5. locale en_US.UTF-8                        │
                     │ 6. user `runner` (+sudo NOPASSWD, +docker)   │
                     │ 7. GitHub Actions runner tarball → ~/github  │
                     │ 8. COPY build.sh → RUN build.sh  ────────────┼──┐
                     │ 9. gitlab-runner install as service          │  │
                     │ 10. ENTRYPOINT docker-entrypoint.sh          │  │
                     └─────────────────────────────────────────────┘  │
                                                                      │
             ┌────────────────────────────────────────────────────────┘
             ▼
   build_scripts/build.sh  (as user `runner`, at build time)
   ├─ Homebrew/Linuxbrew            → /home/linuxbrew/.linuxbrew
   ├─ brew: asdf, fastlane, awscli, terraform, ruby
   ├─ asdf plugins + pinned versions:
   │     nodejs, python, golang, java, flutter,
   │     terraform, kubectl, helm, sops
   ├─ Android SDK cmdline-tools + platform-tools,
   │     platforms;android-30, build-tools;32.0.0
   ├─ SonarScanner CLI 7.2.0
   └─ writes ~/.profile (GPG_TTY, brew, asdf, android, sonar on PATH)
```

Runtime dispatch:

```
docker run … buildmystack [ARGS]
        │
        ▼
docker-entrypoint.sh
  ├─ no args, or ARG[0] starts with "-"   → exec bash -l "$@"   (interactive/login shell)
  ├─ ARG[0] == "sonar-scanner"            → inject -Dsonar.* from env, exec sonar-scanner …
  └─ otherwise                            → exec "$@"            (e.g. gitlab-runner run, ./run.sh)
```

---

## 4. Component specifications

### 4.1 Base image

- **Base:** `ubuntu:noble` (Ubuntu 24.04 LTS).
- **`DEBIAN_FRONTEND=noninteractive`** set for the whole build.
- Locale generated and pinned: `LC_ALL=en_US.UTF-8`, `LANG=en_US.UTF-8`.
- Target architecture today is effectively **amd64 only** because of the pinned
  `libssl1.1_…_amd64.deb` (see §4.5). Multi-arch is a roadmap item (§10).

### 4.2 System packages (apt)

Two categories, both installed in the `Dockerfile`:

1. **Build toolchain / language build deps:** `build-essential`, `git`, `curl`,
   `sudo`, `make`, `jq`, `unzip`, `wget`, `xz-utils`, `llvm`, `cmake`,
   `ninja-build`, plus the headers Python/asdf needs to compile CPython
   (`libssl-dev`, `zlib1g-dev`, `libbz2-dev`, `libreadline-dev`, `libsqlite3-dev`,
   `libncursesw5-dev`, `tk-dev`, `libxml2-dev`, `libxmlsec1-dev`, `libffi-dev`,
   `liblzma-dev`).
2. **Flutter/Linux desktop deps:** `libgtk-3-dev`.
3. **APT plumbing:** `apt-transport-https`, `ca-certificates`,
   `software-properties-common`, `locales`.

`/var/lib/apt/lists/*` is removed at the end to shrink the image.

**Contract:** anything a pinned asdf toolchain needs to *compile from source* must
be added here, because `build.sh` runs after this layer and asdf builds several
runtimes (notably Python) from source.

### 4.3 Docker-in-Docker (DinD)

- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`,
  `docker-compose-plugin` from Docker's official APT repo (GPG key pinned under
  `/etc/apt/keyrings/docker.asc`).
- The `runner` user is added to the `docker` group.
- **The Docker daemon is not started by this image.** Intended usage is one of:
  - GitLab CI with a `docker:dind` service and `DOCKER_HOST` pointing at it, or
  - `-v /var/run/docker.sock:/var/run/docker.sock` bind mount, or
  - running the container `--privileged` and starting `dockerd` yourself.
- `RUN newgrp docker` in the `Dockerfile` is a **no-op** (it spawns a subshell that
  exits immediately) and is kept only for documentation intent. Group membership
  takes effect via `usermod -aG docker runner`.

### 4.4 GitLab Runner

- Installed from `packages.gitlab.com` APT repo.
- In the `Dockerfile` it is **uninstalled and re-installed as a system service**
  bound to:
  - config: `/etc/gitlab-runner/config.toml`
  - working directory: `/home/gitlab-runner`
  - user: `runner`
- **Registration is not baked in.** A running container must either mount a
  pre-registered `config.toml` or run `gitlab-runner register` at startup.
- Note the working directory (`/home/gitlab-runner`) differs from the `runner`
  user's home (`/home/runner`); the `git config --global --add safe.directory`
  entry targets `/home/gitlab-runner/builds*` accordingly. The trailing `*` is a
  literal, not a glob, when passed to `git config`; a broader value such as `'*'`
  or per-build configuration is preferable (§9).

### 4.5 libssl 1.1 backward compatibility

- `libssl1.1_1.1.1w-0+deb11u3_amd64.deb` is fetched from Debian security and
  installed so that older prebuilt binaries (some Android/Gradle/Node native
  tooling, older Sonar plugins) that link `libssl.so.1.1` keep working on Ubuntu
  24.04, which ships OpenSSL 3.
- This `.deb` is **amd64-specific** and is the main blocker for arm64 images.

### 4.6 User & permission model

- Single non-root user `runner` (uid/gid from `useradd -ms /bin/bash`).
- **Passwordless sudo** for `runner` (`runner ALL=(ALL) NOPASSWD:ALL`).
- Member of `docker` group.
- `WORKDIR /home/runner`, `USER runner` for the rest of the build and at runtime.
- Consequence: the container is effectively root-capable. Acceptable for a CI
  builder, called out here so it is a deliberate choice, not a surprise.

### 4.7 GitHub Actions runner

- Version pinned by `ENV GITHUB_RUNNER_VERSION` in the `Dockerfile`
  (currently `2.328.0`).
- Tarball `actions-runner-linux-x64-<version>.tar.gz` is downloaded and extracted
  to `~/github/actions-runner`, then the tarball is deleted.
- `x64` only — same multi-arch caveat as §4.5.
- **Not configured/registered.** To use it: run `./config.sh --url … --token …`
  then `./run.sh` inside `~/github/actions-runner`, typically via the container
  command so `docker-entrypoint.sh` passes it through.

### 4.8 `build_scripts/build.sh` — toolchain provisioning

Runs once, at image build time, as `runner`. Responsibilities:

1. **`~/.profile` bootstrap.** Appends blocks for: `GPG_TTY` (so GPG-signed git
   commits can prompt on a tty), Homebrew `shellenv`, asdf shims on `PATH`,
   Android SDK paths, SonarScanner on `PATH`. Every interactive/login shell picks
   these up (entrypoint uses `bash -l`).
2. **Homebrew/Linuxbrew** install (`NONINTERACTIVE=1`).
3. **brew packages:** `asdf`, `fastlane`, `awscli`, `terraform`, `ruby`.
   (Note `terraform` is installed both via brew and via asdf — see §9.)
4. **asdf config:** `legacy_version_file = yes` in `~/.asdfrc` so a Node project
   with only a `.nvmrc` (no `.tool-versions`) still resolves a Node version.
5. **asdf toolchains** via the `tools_install <plugin> <version>` helper
   (`plugin add` → `install` → `set -u` global). Current pinned versions:

   | Tool | Version (var) |
   |---|---|
   | Node.js | `22.20.0` (`NODEJS_VERSION`) |
   | Python | `3.10.18` (`PYTHON_VERSION`) |
   | Go | `1.25.1` (`GOLANG_VERSION`) |
   | Java | `adoptopenjdk-17.0.16+8` (`JAVA_VERSION`) |
   | Flutter | `3.35.5-stable` (`FLUTTER_VERSION`) |
   | Terraform | `1.13.3` (`TERRAFORM_VERSION`) |
   | kubectl | `1.34.1` (`KUBECTL_VERSION`) |
   | Helm | `3.19.0` (`HELM_VERSION`) |
   | SOPS | `3.11.0` (`SOPS_VERSION`) |

   asdf-java's `set-java-home.bash` is sourced from `~/.profile` so `JAVA_HOME`
   tracks the active asdf Java.
6. **Android SDK** (`ANDROID_HOME=$HOME/android/sdk`):
   - `commandlinetools-linux-13114758_latest.zip` unzipped and relocated to
     `$ANDROID_HOME/cmdline-tools/latest`.
   - `sdkmanager --licenses` accepted non-interactively.
   - Installs `platform-tools`, `platforms;android-30`, `build-tools;32.0.0`.
   - Android env exported via `~/.profile` (`ANDROID_HOME`, `ANDROID_SDK_ROOT`,
     emulator/platform-tools/cmdline-tools on `PATH`).
7. **SonarScanner CLI** `7.2.0.5079-linux-x64` unzipped to
   `$SONAR_HOME/sonar-scanner` (`SONAR_HOME=$HOME/sonarqube`), added to `PATH`.
8. `brew cleanup` at the end.

**Contract for changing versions:** bump the `*_VERSION` variable at the top of
`build.sh` (or the `Dockerfile` `ENV` for the GitHub runner). Keep the Android API
level / build-tools roughly in step with the Flutter version's requirements.

### 4.9 `docker-entrypoint.sh` — runtime contract

`set -Eeuo pipefail`.

| Invocation | Behaviour |
|---|---|
| `docker run … buildmystack` (no args) | `exec bash -l` — login shell, full toolchain on `PATH`. |
| First arg starts with `-` (e.g. `-c "…"`, `--login`) | `exec bash -l "$@"`. |
| First arg is `sonar-scanner` | Reads `SONAR_LOGIN`, `SONAR_PASSWORD`, `SONAR_PROJECT_BASE_DIR` from env and appends them as `-Dsonar.login=…` / `-Dsonar.password=…` / `-Dsonar.projectBaseDir=…`, then `exec sonar-scanner <injected> <remaining args>`. Missing env vars are simply omitted. |
| Any other args | `exec "$@"` verbatim (e.g. `gitlab-runner run`, `./run.sh`, `bash ci/build.sh`). |

**Invariants:** the entrypoint must remain a thin dispatcher, must `exec` (no
orphan PID 1), and must not swallow non-zero exit codes.

---

## 5. Build & release pipelines

### 5.1 GitLab CI (`.gitlab-ci.yml`)

- Job `docker-build`, stage `build`, image `docker:latest`, service `docker:dind`.
- Runs **only on the default branch** (`$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH`).
- `docker login` to `$CI_REGISTRY` with `$CI_REGISTRY_USER` / `$CI_REGISTRY_PASSWORD`.
- `docker build --pull -t $CI_REGISTRY_IMAGE:latest .` then `docker push`.
- **Only tags `:latest`.** No immutable version tag is produced here.

### 5.2 GitHub Actions (`.github/workflows/docker-publish.yml`)

- Trigger: `release` `published` (the workflow also lists `branches`/`tags` keys
  under `on.release`, which GitHub ignores for the `release` event — see §9).
- Steps: checkout → `docker/login-action` to Docker Hub
  (`secrets.DOCKER_USERNAME` / `secrets.DOCKER_PASSWORD`) →
  `docker/metadata-action` for `feedsbrain/buildmystack` semver tags →
  `docker build` and push `:latest` plus a `:<version>` tag derived from the
  release version label.
- The image name (`feedsbrain/buildmystack`) is hard-coded.

### 5.3 Consumption

- **GitLab CI (as job image):** set `image:` (or a runner's default `image`) to the
  pushed registry path. Jobs run under the entrypoint, so `script:` lines execute
  in a login shell with the full toolchain on `PATH`.
- **GitLab CI (as the runner itself):** run the container with
  `gitlab-runner run`, mounting a registered `/etc/gitlab-runner/config.toml`
  (or registering at container start).
- **GitHub Actions (self-hosted runner):** run the container with
  `bash -lc 'cd ~/github/actions-runner && ./config.sh --url … --token … --unattended && ./run.sh'`.
- **Local development (interactive):**
  `docker run --rm -it -v "$PWD":/work -w /work <image>` — drops into a login
  shell with every tool available.
- **Local development (dev container):** point `.devcontainer/devcontainer.json`
  (`"image": "<image>"`) or a JetBrains dev-container config at the same tag CI
  uses, so the editor environment matches the pipeline exactly.
- **Sonar:**
  `docker run --rm -e SONAR_HOST_URL -e SONAR_LOGIN -v "$PWD":/src -w /src <image> sonar-scanner`.

---

## 6. Configuration reference

### 6.1 Build-time

| Mechanism | Name | Purpose |
|---|---|---|
| `Dockerfile` `ENV` | `GITHUB_RUNNER_VERSION` | GitHub Actions runner release. |
| `Dockerfile` `ENV` | `LIBSSL_PACKAGE` | Debian libssl1.1 `.deb` filename (arch-bound). |
| `build.sh` vars | `NODEJS_VERSION`, `PYTHON_VERSION`, `GOLANG_VERSION`, `JAVA_VERSION`, `FLUTTER_VERSION`, `TERRAFORM_VERSION`, `KUBECTL_VERSION`, `HELM_VERSION`, `SOPS_VERSION` | asdf global tool versions. |
| `build.sh` vars | `ANDROID_CLI`, `SONAR_SCANNER_VERSION` / `SONAR_SCANNER_CLI` | Android cmdline-tools and SonarScanner download URLs. |

Today these are edited in-file. §10 proposes promoting them to `ARG`s.

### 6.2 Runtime env vars

| Var | Consumed by | Effect |
|---|---|---|
| `SONAR_LOGIN` | entrypoint | → `-Dsonar.login` |
| `SONAR_PASSWORD` | entrypoint | → `-Dsonar.password` |
| `SONAR_PROJECT_BASE_DIR` | entrypoint | → `-Dsonar.projectBaseDir` |
| `SONAR_HOST_URL` | sonar-scanner | Sonar server URL (standard scanner var). |
| `GPG_TTY` | git/gpg | Set from `$(tty)` in `~/.profile` for signed commits. |
| `DOCKER_HOST` / docker socket | docker CLI | Points at DinD service or mounted socket. |
| GitLab: `CI_REGISTRY*` | pipeline | Registry auth (CI only). |

### 6.3 Important paths

| Path | Contents |
|---|---|
| `/home/runner` | `runner` user home; `.profile`, `.asdfrc`, `.asdf/`. |
| `/home/runner/github/actions-runner` | GitHub Actions runner. |
| `/home/runner/android/sdk` | `ANDROID_HOME` / `ANDROID_SDK_ROOT`. |
| `/home/runner/sonarqube/sonar-scanner` | SonarScanner CLI. |
| `/home/linuxbrew/.linuxbrew` | Homebrew prefix. |
| `/home/gitlab-runner` | GitLab Runner working directory (builds land here). |
| `/etc/gitlab-runner/config.toml` | GitLab Runner config (mount this). |

---

## 7. Versioning & tagging strategy (target)

- **Immutable tags:** every published image should carry
  `:<semver>` (e.g. `:1.4.0`) in addition to `:latest`.
- **Toolchain digest tag (optional):** a short hash of `build.sh` +
  `Dockerfile` so a given toolchain snapshot is addressable even without a release.
- **`latest`** = most recent release of the default branch, never a dev build.
- GitLab CI should tag `:latest` **and** `:$CI_COMMIT_SHORT_SHA` (and `:$CI_COMMIT_TAG`
  when present) so pipelines can pin.
- Document a support window (e.g. last 2 minor tags kept pullable).

---

## 8. Testing & QA (target)

Currently there are **no automated checks**. Recommended, in rough priority order:

1. **`hadolint Dockerfile`** and **`shellcheck build_scripts/build.sh
   docker-entrypoint.sh`** in both pipelines, blocking.
2. **Post-build smoke test** run against the freshly built image before push:
   - `bash -lc 'node --version && python --version && go version && java -version && flutter --version && terraform version && kubectl version --client && helm version && sops --version && sonar-scanner --version'`
   - `bash -lc 'sdkmanager --list_installed'`
   - `docker-entrypoint.sh` dispatch: no-arg → shell, `sonar-scanner` arg builds
     expected `-D` flags (assert with a fake `sonar-scanner` on `PATH`), arbitrary
     arg is exec'd.
3. **Image size budget** check (fail if it grows > X% between builds).
4. **Trivy / Grype scan** of the built image; fail on fixable HIGH/CRITICAL.
5. **`docker buildx build`** for every target platform once multi-arch lands.

---

## 9. Known issues / tech debt

> **See also:** §13 (Toolchain currency audit — what is behind or obsolete) and
> §14 (OS & architecture compatibility). The items below are structural; §13/§14
> are about the specific versions pinned today.

| # | Issue | Impact | Suggested fix |
|---|---|---|---|
| 1 | `libssl1.1` `.deb` and GitHub runner tarball are **amd64/x64 only**. | No arm64 image (Apple Silicon devs, Graviton runners). | Arch-parametrised downloads; drop libssl1.1 if no consumer still needs it. See §13, §14. |
| 2 | GitHub workflow `on.release` also lists `branches`/`tags` keys. | Ignored by GitHub for `release` events — misleading, may hide intent. | Remove the invalid keys; gate on `github.event.release.prerelease == false` if needed. |
| 3 | `RUN newgrp docker` is a no-op. | Dead line. | Delete it. |
| 4 | `git config --global --add safe.directory /home/gitlab-runner/builds*` — trailing `*` is literal. | Nested build dirs may still trip `detected dubious ownership`. | Use `safe.directory '*'` for a CI builder, or set it per-build in CI. |
| 5 | GitLab Runner working dir `/home/gitlab-runner` ≠ user home `/home/runner`; dir is created implicitly. | Confusing; permissions can drift. | Pick one home, or `mkdir -p` + `chown` explicitly. |
| 6 | Terraform installed twice (brew **and** asdf). | Ambiguous which is on `PATH`; wasted space. | Keep the asdf one (pinned), drop from brew. |
| 7 | Many `RUN` layers in `Dockerfile` (apt key steps, etc.). | Larger image, slower rebuilds. | Merge related `RUN`s; use `--mount=type=cache` for apt/brew. |
| 8 | No `.dockerignore`. | `.git` and everything else sent as build context. | Add `.dockerignore` (`.git`, `docs`, CI files). |
| 9 | Android `platforms;android-30` (Android 11, 2020) / `build-tools;32.0.0` are years behind. | Cannot build against a current `compileSdk`; Play Store target-API requirements not met; modern AGP/Flutter refuse these. | Bump to API 36 / `build-tools;36.0.0` and parametrise; keep in step with the Flutter channel. See §13. |
| 10 | Neither runner is registerable without extra scripting. | Every consumer re-invents startup. | Ship `bin/register-gitlab.sh` / `bin/register-github.sh` helpers. |
| 11 | Secrets (`SONAR_LOGIN`) passed as env and expanded into a process arg list. | Visible in `ps` inside the container. | Prefer `SONAR_TOKEN` via `sonar-scanner` native env, or a properties file. |
| 12 | `build.sh` has no `set -euo pipefail`. | A failed tool install can pass silently and ship a broken image. | Add `set -Eeuo pipefail` and a post-install verification block. |
| 13 | Downloads are unpinned by checksum (Homebrew installer, Android tools, Sonar, runner). | Supply-chain risk; non-reproducible. | Pin SHA256 for every `curl`ed artifact and verify before use. |
| 14 | `:latest`-only publishing from GitLab CI. | Consumers cannot pin; rollbacks are manual. | Add immutable tags (§7). |
| 15 | No healthcheck / no `LABEL org.opencontainers.image.*`. | Poor provenance and observability. | Add OCI labels (source, revision, created) and a lightweight `HEALTHCHECK` where it makes sense. |
| 16 | Single giant image serves every stack. | ~multi-GB pull for a job that only needs Node. | Consider a `core` base + stack-specific tags (`-android`, `-flutter`, `-infra`) built via multi-stage / build targets. |

---

## 10. Roadmap for future development

### Phase 1 — Hygiene (low risk, high leverage)
- Add `.dockerignore`.
- Add `hadolint` + `shellcheck` to CI (blocking).
- `set -Eeuo pipefail` in `build.sh` + post-install `--version` verification block.
- Remove dead lines (#3), fix `safe.directory` (#4), de-dupe Terraform (#6).
- Add OCI image labels with source/revision/build-date.

### Phase 2 — Reproducibility & release quality
- Promote every version to a `Dockerfile` `ARG` (defaulted), forwarded into
  `build.sh` via `--build-arg` / `ENV`. One place to bump, visible in
  `docker history`.
- Pin SHA256 checksums for all downloaded artifacts.
- Immutable version tags from both pipelines; keep `:latest` = latest release.
- Post-build smoke test + Trivy scan gates (§8).
- Publish an SBOM (`syft`) alongside each release.

### Phase 2b — Toolchain refresh (do alongside Phase 2; details in §13)
- **Blocking:** bump the GitHub Actions runner to ≥ `2.329.0` (GitHub rejects
  older self-hosted runners at registration since 2026-03).
- **Time-boxed:** move Python off 3.10 before its 2026-10-31 EOL.
- Bump Node → 24 LTS, Go → supported branch, Java → Temurin 21 (rename off the
  `adoptopenjdk-…` identifier), Flutter → current stable, Android → API 36 /
  build-tools 36, plus Terraform / kubectl / Helm (v4) / SOPS / SonarScanner.
- Decide Terraform vs OpenTofu (Terraform is BSL-licensed since 1.6).
- Re-evaluate whether `libssl1.1` is still needed after the bumps; aim to delete.

### Phase 3 — Multi-arch (details and constraints in §14)
- Introduce `ARG TARGETARCH` / `TARGETOS`; map to each vendor's naming
  (`x64`/`amd64`, `arm64`/`aarch64`) for the GitHub runner tarball, SonarScanner,
  and any remaining arch-bound `.deb`.
- Resolve or remove the `libssl1.1` dependency (its `.deb` is the hard amd64 pin).
- `docker buildx` matrix building `linux/amd64` + `linux/arm64`, single manifest,
  **for the non-Android images only** — the Android SDK/emulator has no arm64
  Linux distribution, so a mobile-build image stays `linux/amd64` (documented).

### Phase 4 — Modularisation (optional, only if image size hurts)
- Split into a `core` image (git, build-essential, asdf, Node/Python/Go/Java,
  Docker CLI, cloud CLIs) and derived tags:
  - `-android` / `-flutter` (Android SDK, GTK deps)
  - `-infra` (Terraform, kubectl, Helm, SOPS, AWS CLI)
  - `-sonar` (SonarScanner)
- Keep an `-all` tag equal to today's image for compatibility.
- Use Docker build stages/targets so it is one `Dockerfile`.

### Phase 5 — Runner UX
- `bin/register-gitlab.sh` and `bin/register-github.sh` that read env
  (`RUNNER_URL`, `RUNNER_TOKEN`, labels, tags) and register/run unattended, with
  graceful de-registration on `SIGTERM`.
- Document `docker-compose` / Kubernetes Deployment examples for running N runners.
- Optional: entrypoint sub-commands (`register-gitlab`, `register-github`,
  `run-gitlab`, `run-github`) layered on the existing dispatcher.

---

## 11. Change-management rules

- **Never** change the `docker-entrypoint.sh` dispatch semantics (§4.9) without a
  major version bump — pipelines depend on the "first arg starts with `-` ⇒ shell"
  and "unknown args ⇒ exec verbatim" behaviour.
- Any new toolchain must:
  1. have its version pinned in one obvious place,
  2. be on `PATH` for a login shell (add to `~/.profile` if not via asdf/brew),
  3. be covered by the smoke test's `--version` line.
- Removing or downgrading a toolchain is a breaking change — announce in the
  release notes and bump the minor (or major) version.
- Keep `README.md` pointing at this document.

---

## 12. Security considerations

- The container runs as `runner` with **passwordless sudo** and **docker group** —
  treat it as root-equivalent. Only run it in trusted CI contexts.
- DinD / mounted docker socket grants host root; scope which pipelines get it.
- Pin and checksum every remote download (Phase 2) to reduce supply-chain risk.
- Do not bake registration tokens or registry credentials into the image; always
  inject at runtime.
- Scan published images (Trivy/Grype) and rebuild on a schedule so base-OS CVEs
  get picked up even without a code change.
- Prefer token-based Sonar auth over `SONAR_LOGIN`/`SONAR_PASSWORD` on the process
  command line.

---

## 13. Toolchain currency audit (as of 2026-09)

Snapshot of every pinned version against what is current/supported. Re-run this
audit each quarter; treat "🔴 obsolete" rows as release-blocking.

| Component | Pinned | Current / supported (2026-09) | Status | Notes & action |
|---|---|---|---|---|
| **GitHub Actions runner** | `2.328.0` (`Dockerfile` ENV) | ≥ `2.329.0` **enforced** | 🔴 **broken** | GitHub refuses to register/run self-hosted runners below the enforced minimum (since 2026-03). Bump immediately; keep it near-latest since the floor moves. |
| **Python** | `3.10.18` | 3.12 / 3.13 stable; **3.10 EOL 2026-10-31** (security-only now) | 🔴 obsolete imminently | Move to 3.12 (safe) or 3.13. Hard deadline ~2 months out. asdf compiles it from source, so system build headers (§4.2) must stay complete. |
| **Android platform** | `platforms;android-30` (Android 11, 2020) | API 36 (Android 16) | 🔴 obsolete | Too old to be a `compileSdk` for current AGP/Flutter; fails Play Store target-API rules. Install `platforms;android-36`. |
| **Android build-tools** | `32.0.0` | `36.0.0` | 🔴 obsolete | Bump with the platform. |
| **Java** | `adoptopenjdk-17.0.16+8` | LTS: 17 (premier support ends 2026), **21**, **25** | 🟠 behind + stale name | "AdoptOpenJDK" was renamed **Eclipse Temurin / Adoptium** in 2021. Move to `temurin-21.…` (or 25). 17 still works but its free-update window is closing. |
| **Node.js** | `22.20.0` | 22 = maintenance LTS; **24 = active LTS**; 26 → LTS 2026-10 | 🟠 behind | Move to 24.x LTS. Node 27+ (2026-10) makes every line LTS. |
| **Go** | `1.25.1` | 1.27.x; Go supports only the **latest 2 minors** (1.26, 1.27) | 🟠 out of support window | Bump to 1.27.x (or 1.26.x). Security fixes only land on supported minors. |
| **Flutter** | `3.35.5-stable` | current stable is many releases ahead | 🟠 behind | Bump to current stable; this also drives the Android SDK / JDK minimums above. Verify Dart version consumers. |
| **Terraform** | `1.13.3` | 1.15.x | 🟠 behind + license | Bump. Also: Terraform is **BSL-licensed since 1.6** — if that is a problem, switch to **OpenTofu** (MPL fork, drop-in for now). |
| **kubectl** | `1.34.1` | 1.37 latest | 🟠 behind | Keep within ±1 minor of the clusters you target (version-skew policy). Bump to match. |
| **Helm** | `3.19.0` | **Helm 4.x** released 2026 | 🟠 major behind | Plan a Helm 4 migration; check chart/plugin compatibility before bumping the default. |
| **SonarScanner CLI** | `7.2.0.5079` | `8.1` (2026-04) | 🟠 major behind | Bump. 8.x bundles a Java 21 JRE and adds a `linux-aarch64` build (useful for §14). |
| **SOPS** | `3.11.0` | `3.13.x` | 🟢 minor behind | Low-risk patch bump. |
| **Android cmdline-tools** | rev `13114758` (2024) | newer revision | 🟢 behind | Bump the download URL with the platform refresh. |
| **libssl 1.1** | `1.1.1w-0+deb11u3` (Debian 11) | **OpenSSL 1.1.1 EOL 2023-09** — no patches | 🔴 liability | Unpatched crypto shipped in the image purely for legacy binary compat, and the hard amd64 pin (§14). Identify the actual consumer (candidates: old Android build-tools, old native Node modules); after the bumps above it is likely removable. Delete if nothing links `libssl.so.1.1`. |
| **Ubuntu base** | `ubuntu:noble` (24.04 LTS) | 24.04 LTS current; 26.04 LTS due 2026-04 | 🟢 ok | Fine. Consider pinning by digest (or `ubuntu:24.04`) so the tag can't drift under you. The `Dockerfile` comment referencing "ubuntu:jammy" is stale — fix it. |
| Homebrew / Linuxbrew | latest (unpinned) | 5.x | 🟢 ok | 5.0 (2025-11) made **arm64 Linux Tier-1**, so brew is no longer a multi-arch blocker. Unpinned = non-reproducible (see §9 #13). |
| asdf | via brew (Go rewrite) | current | 🟢 ok | `asdf set -u` / `.tool-versions` usage matches the current Go-based asdf. `legacy_version_file = yes` (`.nvmrc` support) still valid. |
| Ruby | brew `ruby` **+** implied by `fastlane` | — | 🟢 cleanup | `fastlane` pulls its own Ruby; the extra brew `ruby` (and the asdf ruby plugin, if ever added) is redundant. |

### 13.1 Obsolete / dead weight to remove

- **`RUN newgrp docker`** — no-op (spawns a subshell that exits). Delete.
- **Terraform via brew** — also installed via asdf (pinned). Keep asdf, drop brew.
- **Redundant Ruby** — see table.
- **`libssl1.1` shim** — remove once its consumer is gone (see table / §14).
- **`android-30` / `build-tools;32.0.0`** — replace, don't keep alongside new ones
  unless a real project still targets them.
- **`adoptopenjdk-*` identifier** — migrate to the Temurin/Adoptium name.
- **GitHub workflow `on.release.branches` / `tags` keys** — invalid for the
  `release` event, silently ignored. Remove.
- **Stale `Dockerfile` comment** ("ubuntu:jammy" while base is `noble`).

### 13.2 Suggested cadence

- **Monthly:** GitHub Actions runner (moving floor), base-OS security rebuild.
- **Quarterly:** re-run this table; bump patch/minor toolchains.
- **On upstream release:** Flutter stable, Node LTS promotion, Kubernetes minor,
  Java LTS.
- Gate every bump on the §8 smoke test.

---

## 14. OS & architecture compatibility

### 14.1 Where the image can run

| Host | Supported | Notes |
|---|---|---|
| Native Linux x86-64 | ✅ | Primary target. |
| Linux arm64 | ❌ (today) | See blockers below. Non-Android tools *could* support it. |
| Docker Desktop — macOS (Apple Silicon) | ⚠️ emulated | Runs the `linux/amd64` image under Rosetta/QEMU. Works for most builds; slow; **Android emulator will not run**. |
| Docker Desktop — macOS (Intel) | ✅ | Native `linux/amd64` in the Docker VM. |
| Docker Desktop / WSL2 — Windows | ✅ | Linux container in the WSL2/LinuxKit VM. No Windows-container support (and none is feasible — the toolchain is Linux/Android). |
| Podman / containerd / nerdctl | ✅ | OCI image; `sudo`+`docker` group assumptions still apply. Rootless Podman changes uid mapping — DinD/socket needs extra care. |
| Kubernetes (as a runner pod) | ✅ | Needs a privileged sidecar or mounted socket for DinD; `runner` uid must be allowed by PodSecurity. |

The image is **glibc / Ubuntu** based — no musl/Alpine variant. That keeps it
large but avoids native-module compatibility surprises.

### 14.2 Why it is `linux/amd64`-only today

| Blocker | Detail | Fix path |
|---|---|---|
| `LIBSSL_PACKAGE=…_amd64.deb` | Filename hard-codes `amd64`; fetched from Debian 11. | Remove the shim (preferred, see §13), or select the `arm64` `.deb` via `TARGETARCH`. |
| `actions-runner-linux-**x64**-…tar.gz` | GitHub publishes `linux-arm64` too, but the URL is hard-coded to `x64`. | Map `TARGETARCH` → `x64`/`arm64`. |
| Android `commandlinetools-**linux**-….zip` | Google ships cmdline-tools, platform-tools and the emulator **only for linux x86-64**. There is no arm64 Linux Android SDK. | None for the SDK itself. A mobile-build image stays `linux/amd64`. Non-mobile images can go multi-arch. |
| SonarScanner `…-linux-x64.zip` | 7.2 is x64-only; 8.x adds `linux-aarch64` (or use the no-JRE build + system Java). | Bump to 8.x and pick by arch. |
| `docker` apt source | Already arch-aware (`dpkg --print-architecture`). | — none. |
| Homebrew | arm64 Linux is Tier-1 since brew 5.0. | — none. |
| asdf toolchains | Node, Go, Java (Temurin), Terraform, kubectl, Helm, SOPS all ship `linux-arm64`; Python builds from source. | — none. |

### 14.3 Recommended architecture strategy

1. **Split the image by purpose** (also §10 Phase 4):
   - `buildmystack-core` / `-web` / `-infra` — no Android SDK →
     **multi-arch `linux/amd64` + `linux/arm64`**.
   - `buildmystack-android` (or `-mobile`) — includes the Android SDK →
     **`linux/amd64` only**, stated in its docs and enforced with
     `--platform=linux/amd64` in downstream pipelines.
2. **Parametrise arch** in the `Dockerfile`:
   ```dockerfile
   ARG TARGETOS TARGETARCH
   # gh runner:  x64 when amd64, arm64 when arm64
   # sonar:      x64 / aarch64
   ```
   Use `docker buildx build --platform linux/amd64,linux/arm64` and publish a
   manifest list under one tag.
3. **Keep `linux/amd64` authoritative for CI** until arm64 images have their own
   smoke-test run (§8), so a broken arm64 layer can't block amd64 releases.
4. **Document** for consumers: Apple-Silicon developers pulling the multi-arch
   `core` image get a native arm64 container; anyone needing Android must run the
   amd64 mobile image emulated (slow) or on an amd64 CI runner.
