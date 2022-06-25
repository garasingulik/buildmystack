FROM ubuntu:jammy

# disable prompt
ENV DEBIAN_FRONTEND=noninteractive

# install required packages
RUN apt update && apt install -y locales build-essential git curl sudo make jq unzip libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev wget llvm libncursesw5-dev xz-utils tk-dev libxml2-dev \
  libxmlsec1-dev libffi-dev liblzma-dev apt-transport-https ca-certificates software-properties-common \
  cmake ninja-build libgtk-3-dev

# gilab-runner package
RUN curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
RUN apt install gitlab-runner

# install open ssl 1.1.1 for backward compatibility (ubuntu:jammy)
RUN curl -o /tmp/libssl1.1_1.1.0l-1~deb9u6_amd64.deb http://security.debian.org/debian-security/pool/updates/main/o/openssl/libssl1.1_1.1.0l-1~deb9u6_amd64.deb
RUN apt install -y /tmp/libssl1.1_1.1.0l-1~deb9u6_amd64.deb

# set locale
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# clean up image
RUN rm -rf /var/lib/apt/lists/*  /tmp/libssl*.deb

# set user
RUN useradd -ms /bin/bash runner -p runner
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /home/runner
USER runner

# copy build script
COPY build_scripts/build.sh build.sh
RUN sudo chmod +x build.sh

# run build & clean script
RUN ./build.sh && rm build.sh

# set environment variables
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

# shell
CMD ["/bin/bash", "-l"]
