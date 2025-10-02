FROM ubuntu:noble

# disable prompt
ENV DEBIAN_FRONTEND=noninteractive
ENV GITHUB_RUNNER_VERSION=2.328.0

# install required packages
RUN apt update && apt install -y locales build-essential git curl sudo make jq unzip libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev wget llvm libncursesw5-dev xz-utils tk-dev libxml2-dev \
  libxmlsec1-dev libffi-dev liblzma-dev apt-transport-https ca-certificates software-properties-common \
  cmake ninja-build libgtk-3-dev

# add docker official gpg key
RUN install -m 0755 -d /etc/apt/keyrings
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
RUN chmod a+r /etc/apt/keyrings/docker.asc

# add the repository to apt sources:
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# install docker
RUN apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# gilab-runner package
RUN curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
RUN apt install -y gitlab-runner

# install open ssl 1.1.1 for backward compatibility (ubuntu:jammy)
ENV LIBSSL_PACKAGE=libssl1.1_1.1.1w-0+deb11u3_amd64.deb
RUN curl -o /tmp/$LIBSSL_PACKAGE http://security.debian.org/debian-security/pool/updates/main/o/openssl/$LIBSSL_PACKAGE
RUN apt install -y /tmp/$LIBSSL_PACKAGE

# set locale
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# clean up image
RUN rm -rf /var/lib/apt/lists/*  /tmp/libssl*.deb

# set user
RUN useradd -ms /bin/bash runner -p runner
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /home/runner
USER runner

# set group
RUN sudo usermod -aG docker runner
RUN newgrp docker

# set initial git config
RUN git config --global --add safe.directory /home/gitlab-runner/builds*

# github runner
RUN mkdir -p github/actions-runner && cd github/actions-runner \
  && curl -O -L "https://github.com/actions/runner/releases/download/v$GITHUB_RUNNER_VERSION/actions-runner-linux-x64-$GITHUB_RUNNER_VERSION.tar.gz" \
  && tar xzf "./actions-runner-linux-x64-$GITHUB_RUNNER_VERSION.tar.gz" \
  && rm ./"actions-runner-linux-x64-$GITHUB_RUNNER_VERSION.tar.gz"

# copy build script
COPY build_scripts/build.sh build.sh
RUN sudo chmod +x build.sh

# copy entrypoint
COPY ./docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
RUN sudo chmod +x /usr/bin/docker-entrypoint.sh

# run build & clean script
RUN ./build.sh && rm build.sh

# setup gitlab-runner
RUN sudo gitlab-runner uninstall
RUN sudo gitlab-runner install --config /etc/gitlab-runner/config.toml --working-directory /home/gitlab-runner --user runner

# set environment variables
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# shell
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
