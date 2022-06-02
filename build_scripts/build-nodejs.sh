#!/bin/bash

# tooling version
NODEJS_VERSION=16.15.0
PYTHON_VERSION=3.10.4

# install plugin and tooling
function tools_install() {
  asdf plugin add $1
  asdf install $1 $2
  asdf global $1 $2
}

# install tooling
tools_install nodejs $NODEJS_VERSION
tools_install python $PYTHON_VERSION
