FROM ubuntu:jammy

# disable prompt
ENV DEBIAN_FRONTEND noninteractive

# install required packages
RUN apt update && apt install -y locales build-essential git curl sudo make jq unzip libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev wget llvm libncursesw5-dev xz-utils tk-dev libxml2-dev \
  libxmlsec1-dev libffi-dev liblzma-dev apt-transport-https ca-certificates software-properties-common

# install open ssl 1.1.1 for backward compatibility (ubuntu:jammy)
RUN curl -o /tmp/libssl1.1_1.1.0l-1~deb9u6_amd64.deb http://security.debian.org/debian-security/pool/updates/main/o/openssl/libssl1.1_1.1.0l-1~deb9u6_amd64.deb
RUN apt install -y /tmp/libssl1.1_1.1.0l-1~deb9u6_amd64.deb

# set locale
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# gitlab runner
# RUN curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
# RUN apt install -y gitlab-runner

# clean up image
RUN rm -rf /var/lib/apt/lists/*  /tmp/libssl*.deb

# set user
RUN useradd -ms /bin/bash runner -p runner
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /home/runner
USER runner

# install docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN sudo apt update && sudo apt install docker-ce
RUN sudo usermod -aG docker runner

# copy build script
COPY build.sh build.sh
RUN sudo chmod +x build.sh

# run build script
RUN ./build.sh

# cleanup build script
RUN rm build.sh

# set environment variables
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
