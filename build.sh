#!/bin/bash
NODEJS_VERSION=16.15.0
PYTHON_VERSION=3.10.4
JAVA_VERSION=adoptopenjdk-14.0.2+12

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

# asdf plugins
asdf plugin add nodejs
asdf plugin add python
asdf plugin add java

# set nodejs global version
asdf install nodejs $NODEJS_VERSION
asdf global nodejs $NODEJS_VERSION

# set python global version
asdf install python $PYTHON_VERSION
asdf global python $PYTHON_VERSION

# set java global version
asdf install java $JAVA_VERSION
asdf global java $JAVA_VERSION

# plugin config
echo -e ". ~/.asdf/plugins/java/set-java-home.bash" >> ~/.profile
source ~/.profile
