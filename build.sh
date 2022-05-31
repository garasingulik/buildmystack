#!/bin/bash

# tooling version
NODEJS_VERSION=16.15.0
PYTHON_VERSION=3.10.4
JAVA_VERSION=adoptopenjdk-14.0.2+12

# android cli
ANDROID_CLI=https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip

# install plugin and tooling
function tools_install() {
  asdf plugin add $1
  asdf install $1 $2
  asdf global $1 $2
}

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

# set nodejs global version
tools_install nodejs $NODEJS_VERSION
# set python global version
tools_install python $PYTHON_VERSION
# set java global version
tools_install java $JAVA_VERSION

# plugin config
echo -e ". ~/.asdf/plugins/java/set-java-home.bash" >> ~/.profile
source ~/.profile

# android sdk setup
mkdir -p ~/android/sdk
curl -o cli-tools.zip $ANDROID_CLI
unzip cli-tools.zip -d ~/android/sdk
mv ~/android/sdk/cmdline-tools ~/android/sdk/latest
mkdir -p ~/android/sdk/cmdline-tools
mv ~/android/sdk/latest ~/android/sdk/cmdline-tools
rm -f cli-tools.zip

# set path
echo "" >> ~/.profile
echo 'export ANDROID_HOME=$HOME/android/sdk' >> ~/.profile
echo 'export PATH=$PATH:$ANDROID_HOME/emulator' >> ~/.profile
echo 'export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest' >> ~/.profile
echo 'export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin' >> ~/.profile
echo 'export PATH=$PATH:$ANDROID_HOME/platform-tools' >> ~/.profile
echo 'export ANDROID_SDK_ROOT=$ANDROID_HOME' >> ~/.profile
source ~/.profile

# android sdkmanager
yes | sdkmanager --licenses
sdkmanager --install "platform-tools" "platforms;android-30" "build-tools;32.0.0"
