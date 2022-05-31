FROM gitlab/gitlab-runner:ubuntu

# disable prompt
ENV DEBIAN_FRONTEND noninteractive

# install required packages
RUN apt update && apt install -y locales build-essential git curl sudo make jq unzip libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncursesw5-dev xz-utils tk-dev libxml2-dev \
  libxmlsec1-dev libffi-dev liblzma-dev

# install open ssl 1.1.1 for backward compatibility
# uncomment these two lines if you're building image with ubuntu 22.04 base
# RUN curl -o /tmp/libssl1.1_1.1.0l-1~deb9u6_amd64.deb http://security.debian.org/debian-security/pool/updates/main/o/openssl/libssl1.1_1.1.0l-1~deb9u6_amd64.deb
# RUN apt install -y /tmp/libssl1.1_1.1.0l-1~deb9u6_amd64.deb

# set locale
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# clean up image
RUN rm -rf /var/lib/apt/lists/*  /tmp/libssl*.deb

# set user
ENV CONTAINER_USER=gitlab-runner

# uncomment this line if you're building from scratch
# RUN useradd -ms /bin/bash ${CONTAINER_USER} -p ${CONTAINER_USER}
RUN echo "${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
WORKDIR /home/${CONTAINER_USER}
USER ${CONTAINER_USER}

# copy build script
COPY build.sh build.sh
RUN sudo chmod +x build.sh

# run build script
RUN ./build.sh

# cleanup build script
RUN rm build.sh

# set environment variables
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
