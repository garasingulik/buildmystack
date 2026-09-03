# Build-My-Stack

A single Docker image that bundles **every toolchain we need to build our software
projects** — Node.js, Python, Go, Java, Flutter/Android, Terraform, Kubernetes
tooling, SonarScanner, and more — so the build environment is **identical in CI/CD
and on a developer laptop**.

- **Primary use:** the build image / self-hosted runner for **GitLab CI** and
  **GitHub Actions** pipelines. One pinned environment → reproducible builds, no
  "reinstall the SDK on every job".
- **Secondary use:** run it locally (`docker run -it`, or as a VS Code / JetBrains
  dev container) to get the exact tools and versions the pipeline uses without
  installing anything on the host.

For architecture, contracts, known issues, and the development roadmap, see
[`docs/SPEC.md`](docs/SPEC.md).

---

## What's inside

Base: `ubuntu:noble` (24.04 LTS). Non-root user `runner` (passwordless `sudo`,
member of the `docker` group). All tools are on `PATH` in a **login shell**
(`bash -l`), which the entrypoint always uses.

Versions below are the current defaults (latest stable upstream as of the
2026-09 refresh).

| Category | Tools |
|---|---|
| Languages / runtimes (via [asdf](https://asdf-vm.com)) | Node.js `24.20.0` (LTS), Python `3.14.7`, Go `1.27.1`, Java `temurin-21.0.12+101.0.LTS`, Flutter `3.47.2-stable` (Dart 3.13.2) |
| Infra / cloud (via asdf) | Terraform `1.16.1`, kubectl `1.37.0`, Helm `4.2.4`, SOPS `3.13.3` |
| Infra / cloud (via Homebrew) | AWS CLI, Ruby, Fastlane |
| Mobile | Android SDK cmdline-tools `15859902`, `platform-tools`, `platforms;android-36`, `build-tools;36.0.0` (`ANDROID_HOME=/home/runner/android/sdk`) |
| Code quality | SonarScanner CLI `8.1.0.6389` (`sonar-scanner` on `PATH`) |
| Containers | Docker CE + CLI, Buildx, Compose plugin (daemon **not** started — see below) |
| CI runners | `gitlab-runner` (installed as a service), GitHub Actions runner `2.337.0` at `/home/runner/github/actions-runner` |
| Build essentials | `build-essential`, `git`, `curl`, `wget`, `make`, `cmake`, `ninja-build`, `jq`, `unzip`, `llvm`, Python build headers, `libgtk-3-dev` (Flutter Linux), `libssl1.1` (legacy binary compat) |

Exact versions live at the top of [`build_scripts/build.sh`](build_scripts/build.sh)
and in `ENV` lines in the [`Dockerfile`](Dockerfile). See
[Updating tool versions](#updating-tool-versions).

> **Notes on the current defaults:**
> - **Java stays on Temurin 21** (latest LTS the Android Gradle Plugin / Flutter
>   support), not 25 — see [`docs/SPEC.md` §13](docs/SPEC.md#13-toolchain-currency-audit).
> - **Helm is the v4 major line** (`4.2.4`, the latest stable; Helm 3 is EOL). If
>   your charts/plugins are not Helm 4-ready yet, pin an older image tag or add a
>   per-repo `helm 3.x` `.tool-versions` entry, and diff `helm template` output
>   when you adopt.
> - **Terraform 1.16 is BSL-licensed**; swap the asdf plugin for OpenTofu if that
>   matters to you.
> - `libssl1.1` (`libssl.so.1.1`) is kept on purpose for backward compatibility
>   with binaries that still link OpenSSL 1.1, pinned to the newest Debian 11 LTS
>   backport (`deb11u8`). It is amd64-only.

> **Architecture:** currently **amd64 / x86-64 only** (the bundled `libssl1.1`
> `.deb`, the GitHub runner tarball, and the Android SDK are amd64). Multi-arch
> for the non-Android tools is on the roadmap —
> [`docs/SPEC.md` §14](docs/SPEC.md#14-os--architecture-compatibility).

---

## Published images

| Registry | Image | Tags |
|---|---|---|
| Docker Hub | `feedsbrain/buildmystack` | `:latest`, `:<semver>` (on GitHub release) |
| GitLab Container Registry | `$CI_REGISTRY_IMAGE` | `:latest` (on default-branch pipeline) |

```sh
docker pull feedsbrain/buildmystack:latest
```

---

## Build the image

### Prerequisites

- **Docker with BuildKit** (default in Docker 23+). The `Dockerfile` uses
  `COPY --chmod`, which needs BuildKit — a `DOCKER_BUILDKIT=0` build will fail.
- ~15–20 GB free disk and a good connection — the build compiles Python from
  source and downloads Android + Flutter + JDK + Homebrew. Expect **10–30 min**
  cold and a multi-GB image.

### Standard build

```sh
git clone git@github.com:garasingulik/buildmystack.git
cd buildmystack

docker build \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t buildmystack:local .
```

The two `--build-arg`s are optional — they only populate the
`org.opencontainers.image.revision` / `.created` labels (both pipelines pass
them). Tool versions are edited in-file, see
[Updating tool versions](#updating-tool-versions).

### With Buildx

```sh
docker buildx build --load -t buildmystack:local .
```

### Notes

- `build.sh` runs `set -Eeuo pipefail` and ends with a `--version` check of every
  tool, so a broken toolchain fails the build instead of shipping.
- If the build fails partway, fix and rebuild — layer caching keeps earlier steps.
- Lint the sources the way CI does (both are blocking in CI):

  ```sh
  docker run --rm -v "$PWD":/repo -w /repo hadolint/hadolint hadolint Dockerfile
  docker run --rm -v "$PWD":/repo -w /repo koalaman/shellcheck-alpine:stable \
    shellcheck build_scripts/build.sh docker-entrypoint.sh
  ```

- Re-run the in-build smoke check against the finished image:

  ```sh
  docker run --rm buildmystack:local bash -lc '
    node --version && python --version && go version &&
    java -version && flutter --version && terraform version &&
    kubectl version --client && helm version && sops --version &&
    sonar-scanner --version'
  ```

---

## Run locally (development)

### Interactive shell with your project mounted

```sh
docker run --rm -it \
  -v "$PWD":/work -w /work \
  buildmystack:local
```

You land in a login shell with every tool on `PATH`. Build as you would in CI,
e.g. `npm ci && npm run build`, `./gradlew assembleRelease`, `flutter build apk`,
`go build ./...`, `terraform plan`.

### One-off command

```sh
docker run --rm -v "$PWD":/work -w /work buildmystack:local \
  bash -lc 'npm ci && npm test'
```

> The entrypoint treats a first argument starting with `-` (or no arguments) as a
> request for a login shell, and passes anything else straight through to `exec`.
> When you need the environment, wrap your command in `bash -lc '…'`.

### Building Docker images from inside the container

The Docker **daemon is not started** in the image. Choose one:

```sh
# Use the host's Docker daemon (simplest for local dev)
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD":/work -w /work \
  buildmystack:local
```

or run it `--privileged` and start `dockerd` yourself, or point `DOCKER_HOST` at a
`docker:dind` service (how GitLab CI does it).

### As a dev container

`.devcontainer/devcontainer.json`:

```json
{
  "name": "buildmystack",
  "image": "feedsbrain/buildmystack:latest",
  "overrideCommand": true,
  "remoteUser": "runner"
}
```

Pin the same tag your pipeline uses so the editor environment matches CI exactly.

---

## Use in GitLab CI

### As the job image

```yaml
build:
  image: feedsbrain/buildmystack:latest
  script:
    - node --version
    - npm ci
    - npm run build
```

`script:` lines run under the entrypoint in a login shell, so the toolchain is
already on `PATH`.

Need Docker in the job:

```yaml
build-image:
  image: feedsbrain/buildmystack:latest
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2376
    DOCKER_TLS_CERTDIR: "/certs"
  script:
    - docker build -t myapp .
```

### As the runner itself

The image ships `gitlab-runner` installed as a service (working dir
`/home/gitlab-runner`, config `/etc/gitlab-runner/config.toml`, user `runner`).
Provide a registered config and run it:

```sh
docker run -d --name bms-gitlab-runner \
  -v "$PWD/config.toml":/etc/gitlab-runner/config.toml \
  -v /var/run/docker.sock:/var/run/docker.sock \
  feedsbrain/buildmystack:latest gitlab-runner run
```

Register first (interactively or `--non-interactive`) to produce `config.toml`:

```sh
docker run --rm -it \
  -v "$PWD":/etc/gitlab-runner \
  feedsbrain/buildmystack:latest \
  gitlab-runner register --url https://gitlab.com/ --token <RUNNER_TOKEN>
```

---

## Use in GitHub Actions (self-hosted runner)

The Actions runner is bundled at `/home/runner/github/actions-runner` but is not
registered. Start a container that configures and runs it:

```sh
docker run -d --name bms-gh-runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  feedsbrain/buildmystack:latest \
  bash -lc 'cd ~/github/actions-runner &&
            ./config.sh --url https://github.com/<ORG>/<REPO> --token <REG_TOKEN> --unattended --replace &&
            ./run.sh'
```

Then target it from a workflow with `runs-on: self-hosted`. The toolchain is
already present, so steps skip `setup-node` / `setup-java` / etc.

---

## SonarScanner

Passing `sonar-scanner` as the command makes the entrypoint inject `-Dsonar.*`
properties from environment variables:

| Env var | Maps to |
|---|---|
| `SONAR_LOGIN` | `-Dsonar.login` |
| `SONAR_PASSWORD` | `-Dsonar.password` |
| `SONAR_PROJECT_BASE_DIR` | `-Dsonar.projectBaseDir` |
| `SONAR_HOST_URL` | read by the scanner directly |

```sh
docker run --rm \
  -e SONAR_HOST_URL=https://sonar.example.com \
  -e SONAR_LOGIN=$SONAR_TOKEN \
  -v "$PWD":/src -w /src \
  feedsbrain/buildmystack:latest sonar-scanner
```

---

## Configuration reference

### Runtime environment variables

| Var | Used by | Effect |
|---|---|---|
| `SONAR_LOGIN`, `SONAR_PASSWORD`, `SONAR_PROJECT_BASE_DIR` | entrypoint | Injected as `-Dsonar.*` when the command is `sonar-scanner`. |
| `SONAR_HOST_URL` | sonar-scanner | Sonar server URL. |
| `GPG_TTY` | git/gpg | Set from `$(tty)` in `~/.profile` so signed commits can prompt. |
| `DOCKER_HOST` / docker socket | docker CLI | Point at a DinD service or bind-mount `/var/run/docker.sock`. |

### Key paths

| Path | Contents |
|---|---|
| `/home/runner` | User home: `.profile`, `.asdfrc`, `.asdf/`. |
| `/home/runner/github/actions-runner` | GitHub Actions runner. |
| `/home/runner/android/sdk` | `ANDROID_HOME` / `ANDROID_SDK_ROOT`. |
| `/home/runner/sonarqube/sonar-scanner` | SonarScanner CLI. |
| `/home/linuxbrew/.linuxbrew` | Homebrew prefix. |
| `/etc/gitlab-runner/config.toml` | GitLab Runner config (mount this). |
| `/home/gitlab-runner` | GitLab Runner working directory. |

### asdf / `.nvmrc` behaviour

`legacy_version_file = yes` is set, so a Node project with only a `.nvmrc` (no
`.tool-versions`) still resolves a Node version. Drop a `.tool-versions` in your
repo to pin any tool per-project.

---

## Updating tool versions

1. Edit the `*_VERSION` variables at the top of
   [`build_scripts/build.sh`](build_scripts/build.sh) (languages, infra tools,
   Android CLI, SonarScanner) and/or the `ENV` lines in the
   [`Dockerfile`](Dockerfile) (`GITHUB_RUNNER_VERSION`; `LIBSSL_PACKAGE` — set to
   the newest `libssl1.1_1.1.1w-0+deb11u*_amd64.deb` in the
   [debian-security OpenSSL pool](http://security.debian.org/debian-security/pool/updates/main/o/openssl/)).
2. Keep the Android API level / build-tools in step with the Flutter version, and
   keep `JAVA_VERSION` on an LTS the Android Gradle Plugin supports. Verify a JDK
   id with `asdf list all java 'temurin-'`.
3. Bump `GITHUB_RUNNER_VERSION` roughly monthly — GitHub enforces a rolling
   minimum for self-hosted runners.
4. Rebuild and run the smoke check above.
5. Commit; the release pipeline publishes a new tag.

The full currency audit and bump cadence live in
[`docs/SPEC.md` §13](docs/SPEC.md#13-toolchain-currency-audit).

---

## CI / publishing

| Pipeline | Trigger | Result |
|---|---|---|
| [`.gitlab-ci.yml`](.gitlab-ci.yml) `lint` stage | every branch / MR | **blocking** `hadolint Dockerfile` + `shellcheck` of the scripts. |
| [`.github/workflows/lint.yml`](.github/workflows/lint.yml) | push to `main`, every PR | same two **blocking** linters. |
| [`.gitlab-ci.yml`](.gitlab-ci.yml) `build` stage | push to the default branch | `docker build` (with `VCS_REF` / `BUILD_DATE` args) + push `$CI_REGISTRY_IMAGE:latest` via `docker:dind`. |
| [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) | GitHub **release published** | build + push `feedsbrain/buildmystack:latest` and `:<version>` to Docker Hub (`DOCKER_USERNAME` / `DOCKER_PASSWORD` secrets). |

Lint config: [`.hadolint.yaml`](.hadolint.yaml) (`failure-threshold: info` with a
short `ignored` list of accepted debt) and [`.shellcheckrc`](.shellcheckrc).

---

## Repository layout

| Path | Role |
|---|---|
| `Dockerfile` | Image definition: base OS, system packages, Docker CE, GitLab Runner, GitHub Actions runner, user model, OCI labels, entrypoint wiring. |
| `build_scripts/build.sh` | Runs once at build time as `runner` (`set -Eeuo pipefail`): Homebrew, asdf, all language/CLI toolchains, Android SDK, SonarScanner; writes `~/.profile`; verifies every tool at the end. |
| `docker-entrypoint.sh` | Entrypoint: dispatches between login shell, `sonar-scanner` wrapper, and pass-through `exec`. |
| `.dockerignore` | Keeps the build context to the two COPYed scripts. |
| `.hadolint.yaml` / `.shellcheckrc` | Lint config. |
| `.gitlab-ci.yml` | Lint + build/push to the GitLab registry. |
| `.github/workflows/lint.yml` | hadolint + shellcheck. |
| `.github/workflows/docker-publish.yml` | Builds & pushes the image to Docker Hub on release. |
| `docs/SPEC.md` | Full specification, contracts, known issues, roadmap. |
