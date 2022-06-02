#!/bin/bash

# tooling version
JAVA_VERSION=adoptopenjdk-14.0.2+12

# android cli
ANDROID_CLI=https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip

# install plugin and tooling
function tools_install() {
  asdf plugin add $1
  asdf install $1 $2
  asdf global $1 $2
}

# install tooling
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
