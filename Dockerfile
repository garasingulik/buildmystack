FROM ubuntu:noble

# OCI image metadata. VCS_REF / BUILD_DATE are supplied by the build pipeline:
#   --build-arg VCS_REF=$(git rev-parse --short HEAD)
#   --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ARG VCS_REF=unknown
ARG BUILD_DATE
LABEL org.opencontainers.image.title="build-my-stack" \
      org.opencontainers.image.description="Polyglot CI/CD build image with a pinned toolchain (Node, Python, Go, Java, Flutter/Android, Terraform, kubectl, Helm, SOPS, SonarScanner) plus GitLab and GitHub self-hosted runners." \
      org.opencontainers.image.source="https://github.com/garasingulik/buildmystack" \
      org.opencontainers.image.documentation="https://github.com/garasingulik/buildmystack/blob/main/docs/SPEC.md" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

# disable prompt
ENV DEBIAN_FRONTEND=noninteractive
ENV GITHUB_RUNNER_VERSION=2.337.0

# fail RUN pipelines on the first non-zero stage, not just the last
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# install required packages
RUN apt-get update && apt-get install -y locales build-essential git curl sudo make jq unzip libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev wget llvm libncursesw5-dev xz-utils tk-dev libxml2-dev \
  libxmlsec1-dev libffi-dev liblzma-dev apt-transport-https ca-certificates software-properties-common \
  cmake ninja-build libgtk-3-dev \
  && rm -rf /var/lib/apt/lists/*

# add docker official gpg key
RUN install -m 0755 -d /etc/apt/keyrings
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
RUN chmod a+r /etc/apt/keyrings/docker.asc

# add the repository to apt sources:
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# install docker
RUN apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

# gilab-runner package
RUN curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
RUN apt-get install -y gitlab-runner \
  && rm -rf /var/lib/apt/lists/*

# install openssl 1.1.1 (libssl.so.1.1) for backward compatibility with tools /
# prebuilt binaries that still link OpenSSL 1.1 (not shipped on ubuntu:noble).
# OpenSSL 1.1.1 upstream ended at 1.1.1w; Debian 11 (bullseye) LTS keeps
# backporting security fixes as deb11uN — pin the newest available from the
# debian-security pool. Check for a newer patch level at:
#   http://security.debian.org/debian-security/pool/updates/main/o/openssl/
ENV LIBSSL_PACKAGE=libssl1.1_1.1.1w-0+deb11u8_amd64.deb
RUN curl -fsSL -o "/tmp/$LIBSSL_PACKAGE" "http://security.debian.org/debian-security/pool/updates/main/o/openssl/$LIBSSL_PACKAGE" \
  && apt-get install -y "/tmp/$LIBSSL_PACKAGE" \
  && rm -f "/tmp/$LIBSSL_PACKAGE" \
  && rm -rf /var/lib/apt/lists/*

# set locale
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# set user
RUN useradd -ms /bin/bash runner -p runner
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /home/runner
USER runner

# set group
RUN sudo usermod -aG docker runner

# set initial git config — a CI builder checks out repos it does not own
RUN git config --global --add safe.directory '*'

# github runner
RUN mkdir -p github/actions-runner \
  && curl -fsSL -o /tmp/actions-runner.tar.gz "https://github.com/actions/runner/releases/download/v$GITHUB_RUNNER_VERSION/actions-runner-linux-x64-$GITHUB_RUNNER_VERSION.tar.gz" \
  && tar xzf /tmp/actions-runner.tar.gz -C github/actions-runner \
  && rm /tmp/actions-runner.tar.gz

# copy build script
COPY --chmod=0755 build_scripts/build.sh build.sh

# copy entrypoint
COPY --chmod=0755 docker-entrypoint.sh /usr/bin/docker-entrypoint.sh

# run build & clean script
RUN ./build.sh && rm build.sh

# setup gitlab-runner
RUN sudo gitlab-runner uninstall
RUN sudo gitlab-runner install --config /etc/gitlab-runner/config.toml --working-directory /home/gitlab-runner --user runner

# set environment variables
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# shell
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
