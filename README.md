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

| Category | Tools |
|---|---|
| Languages / runtimes (via [asdf](https://asdf-vm.com)) | Node.js `22.20.0`, Python `3.10.18`, Go `1.25.1`, Java `adoptopenjdk-17.0.16+8`, Flutter `3.35.5-stable` |
| Infra / cloud (via asdf) | Terraform `1.13.3`, kubectl `1.34.1`, Helm `3.19.0`, SOPS `3.11.0` |
| Infra / cloud (via Homebrew) | AWS CLI, Terraform, Ruby, Fastlane |
| Mobile | Android SDK cmdline-tools, `platform-tools`, `platforms;android-30`, `build-tools;32.0.0` (`ANDROID_HOME=/home/runner/android/sdk`) |
| Code quality | SonarScanner CLI `7.2.0` (`sonar-scanner` on `PATH`) |
| Containers | Docker CE + CLI, Buildx, Compose plugin (daemon **not** started — see below) |
| CI runners | `gitlab-runner` (installed as a service), GitHub Actions runner `2.328.0` at `/home/runner/github/actions-runner` |
| Build essentials | `build-essential`, `git`, `curl`, `wget`, `make`, `cmake`, `ninja-build`, `jq`, `unzip`, `llvm`, Python build headers, `libgtk-3-dev` (Flutter Linux), `libssl1.1` (legacy binary compat) |

Exact versions live at the top of [`build_scripts/build.sh`](build_scripts/build.sh)
and in `ENV` lines in the [`Dockerfile`](Dockerfile). See
[Updating tool versions](#updating-tool-versions).

> **Toolchain currency:** several pinned versions are behind or near end-of-life
> (Python 3.10, the GitHub Actions runner, Android API 30, Java 17, Helm 3, …).
> See [`docs/SPEC.md` §13](docs/SPEC.md#13-toolchain-currency-audit-as-of-2026-09)
> for the full audit and priorities.

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

- Docker 20.10+ (Buildx recommended).
- ~15–20 GB free disk and a good connection — the build compiles Python from
  source and downloads Android + Flutter + JDK + Homebrew. Expect **10–30 min**
  cold and a multi-GB image.

### Standard build

```sh
git clone git@github.com:garasingulik/buildmystack.git
cd buildmystack

docker build -t buildmystack:local .
```

### With Buildx (recommended)

```sh
docker buildx build --load -t buildmystack:local .
```

### Notes

- The build has no required build args today; tool versions are edited in-file
  (see [Updating tool versions](#updating-tool-versions)).
- Most of [`build_scripts/build.sh`](build_scripts/build.sh) runs as the `runner`
  user during a single `RUN` layer. If it fails partway, fix and rebuild — layer
  caching keeps earlier steps.
- Do a quick smoke check after building:

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
   [`Dockerfile`](Dockerfile) (`GITHUB_RUNNER_VERSION`, `LIBSSL_PACKAGE`).
2. Keep the Android API level / build-tools roughly in step with the Flutter
   version.
3. Rebuild and run the smoke check above.
4. Commit; the release pipeline publishes a new tag.

---

## How this image is published

| Pipeline | Trigger | Result |
|---|---|---|
| [`.gitlab-ci.yml`](.gitlab-ci.yml) | push to the default branch | `docker build` + push `$CI_REGISTRY_IMAGE:latest` (uses `docker:dind`). |
| [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) | GitHub **release published** | build + push `feedsbrain/buildmystack:latest` and `:<version>` to Docker Hub (`DOCKER_USERNAME` / `DOCKER_PASSWORD` secrets). |

---

## Repository layout

| Path | Role |
|---|---|
| `Dockerfile` | Image definition: base OS, system packages, Docker CE, GitLab Runner, GitHub Actions runner, user model, entrypoint wiring. |
| `build_scripts/build.sh` | Runs once at build time as `runner`: Homebrew, asdf, all language/CLI toolchains, Android SDK, SonarScanner; writes `~/.profile`. |
| `docker-entrypoint.sh` | Entrypoint: dispatches between login shell, `sonar-scanner` wrapper, and pass-through `exec`. |
| `.gitlab-ci.yml` | Builds & pushes the image to the GitLab registry. |
| `.github/workflows/docker-publish.yml` | Builds & pushes the image to Docker Hub on release. |
| `docs/SPEC.md` | Full specification, contracts, known issues, roadmap. |
