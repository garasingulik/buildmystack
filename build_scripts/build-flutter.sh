#!/bin/bash

# tooling version
FLUTTER_VERSION=3.0.1-stable

# install plugin and tooling
function tools_install() {
  asdf plugin add $1
  asdf install $1 $2
  asdf global $1 $2
}

# install tooling
tools_install flutter $FLUTTER_VERSION
