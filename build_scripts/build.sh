#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export PROFILE_CONFIG="$HOME/.profile"

# tooling version
NODEJS_VERSION=16.15.1
PYTHON_VERSION=3.10.5
GOLANG_VERSION=1.18.3
JAVA_VERSION=adoptopenjdk-14.0.2+12
FLUTTER_VERSION=3.0.3-stable

# android cli version
ANDROID_CLI=https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip

# helper script to install asdf plugin and set global tooling version
function tools_install() {
  asdf plugin add $1
  asdf install $1 $2
  asdf global $1 $2
}

# set gpg tty
# if we sign git commit using gpg, this configuration will redirect password prompt to tty
echo "" >> $PROFILE_CONFIG
echo "# gpg" >> $PROFILE_CONFIG
echo 'export GPG_TTY=$(tty)' >> $PROFILE_CONFIG

# install homebrew / linuxbrew (yeah that's right, homebrew is not only for macOS)
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo "" >> $PROFILE_CONFIG
echo "# homebrew" >> $PROFILE_CONFIG
echo 'eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >> $PROFILE_CONFIG
source $PROFILE_CONFIG

# install asdf-vm, this make our life easier if we use multiple tooling
brew install asdf
echo "" >> $PROFILE_CONFIG
echo "# asdf" >> $PROFILE_CONFIG
echo ". /home/linuxbrew/.linuxbrew/opt/asdf/libexec/asdf.sh" >> $PROFILE_CONFIG
source $PROFILE_CONFIG

# asdf configuration
#
# this specific configuration is to make asdf compatible with nvm
# so when the Node.js project has .nvmrc, asdf will honor this file
# if .tool-versions is not found
echo "legacy_version_file = yes" >> ~/.asdfrc

# actually install the tooling
tools_install nodejs $NODEJS_VERSION
tools_install python $PYTHON_VERSION
tools_install golang $GOLANG_VERSION
tools_install java $JAVA_VERSION
tools_install flutter $FLUTTER_VERSION

# asdf plugin config
# this will automatically set JAVA_HOME to the preferred version when using asdf-java
echo -e ". ~/.asdf/plugins/java/set-java-home.bash" >> $PROFILE_CONFIG
source $PROFILE_CONFIG

# android sdk and cli setup
export ANDROID_HOME=$HOME/android/sdk
mkdir -p $ANDROID_HOME
curl -o cli-tools.zip $ANDROID_CLI
unzip cli-tools.zip -d $ANDROID_HOME
mv $ANDROID_HOME/cmdline-tools $ANDROID_HOME/latest
mkdir -p $ANDROID_HOME/cmdline-tools
mv $ANDROID_HOME/latest $ANDROID_HOME/cmdline-tools
rm -f cli-tools.zip

# set android home path
echo "" >> $PROFILE_CONFIG
echo "# android" >> $PROFILE_CONFIG
echo 'export ANDROID_HOME=$HOME/android/sdk' >> $PROFILE_CONFIG
echo 'export PATH=$PATH:$ANDROID_HOME/emulator' >> $PROFILE_CONFIG
echo 'export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest' >> $PROFILE_CONFIG
echo 'export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin' >> $PROFILE_CONFIG
echo 'export PATH=$PATH:$ANDROID_HOME/platform-tools' >> $PROFILE_CONFIG
echo 'export ANDROID_SDK_ROOT=$ANDROID_HOME' >> $PROFILE_CONFIG
source $PROFILE_CONFIG

# android sdkmanager basic tools installation
yes | sdkmanager --licenses
sdkmanager --install "platform-tools" "platforms;android-30" "build-tools;32.0.0"

# cleanup
brew cleanup
