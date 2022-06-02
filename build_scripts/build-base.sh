#!/bin/bash

# install homebrew
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >> ~/.profile
source ~/.profile

# install asdf
brew install asdf
echo ". /home/linuxbrew/.linuxbrew/opt/asdf/libexec/asdf.sh" >> ~/.profile
source ~/.profile

# asdf configuration
echo "legacy_version_file = yes" >> ~/.asdfrc

# cleanup
brew cleanup
