#!/bin/bash

# tooling version
GOLANG_VERSION=1.18.2

# install plugin and tooling
function tools_install() {
  asdf plugin add $1
  asdf install $1 $2
  asdf global $1 $2
}

# install tooling
tools_install golang $GOLANG_VERSION
