#!/bin/bash
#
# Provisions the polyglot toolchain into the image. Runs once, at image build
# time, as the `runner` user. Any failure aborts the build (set -e).
set -Eeuo pipefail
trap 'echo "build.sh: failed at line $LINENO" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export PROFILE_CONFIG="$HOME/.profile"

# tooling version
#
# Bump policy: keep these at the latest stable upstream release. Node.js tracks
# the active LTS line (not "Current"). Java stays on the latest LTS that the
# Android Gradle Plugin / Flutter toolchain officially supports (currently 21);
# Temurin 25 exists but is not yet safe as the shared default for Android builds.
# Verify a JDK id against: asdf list all java 'temurin-'
NODEJS_VERSION=24.20.0
PYTHON_VERSION=3.14.7
GOLANG_VERSION=1.27.1
JAVA_VERSION=temurin-21.0.12+101.0.LTS
FLUTTER_VERSION=3.47.2-stable
TERRAFORM_VERSION=1.16.1
KUBECTL_VERSION=1.37.0
HELM_VERSION=4.2.4
SOPS_VERSION=3.13.3

# android cli version
ANDROID_CLI=https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip

# sonar scanner
SONAR_SCANNER_VERSION=8.1.0.6389-linux-x64
SONAR_SCANNER_CLI=https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$SONAR_SCANNER_VERSION.zip

# helper: install an asdf plugin and set it as the global version
tools_install() {
  asdf plugin add "$1" || true
  asdf install "$1" "$2"
  asdf set -u "$1" "$2"
}

# helper: re-load ~/.profile. Sourcing a profile is best-effort (completion/eval
# lines may exit non-zero or touch unset vars), so relax -e/-u around it. The
# end-of-script verification block is the real safety net.
reload_profile() {
  set +eu
  # shellcheck source=/dev/null
  source "$PROFILE_CONFIG"
  set -eu
}

# set gpg tty
# if we sign git commits with gpg, this redirects the passphrase prompt to the tty
cat >> "$PROFILE_CONFIG" <<'EOF'

# gpg
export GPG_TTY=$(tty)
EOF

# install homebrew / linuxbrew (yeah that's right, homebrew is not only for macOS)
brew_installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
NONINTERACTIVE=1 /bin/bash -c "$brew_installer"
cat >> "$PROFILE_CONFIG" <<'EOF'

# homebrew
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)
EOF
reload_profile

# install asdf-vm, this makes life easier when juggling multiple toolchains
# note: terraform is provided via asdf (pinned above); do not add it here too
brew install asdf fastlane awscli ruby
cat >> "$PROFILE_CONFIG" <<'EOF'

# asdf
export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
EOF
reload_profile

# asdf configuration
#
# `legacy_version_file` makes asdf honour a Node project's .nvmrc when no
# .tool-versions is present (nvm compatibility).
echo "legacy_version_file = yes" >> ~/.asdfrc

# actually install the tooling
tools_install nodejs "$NODEJS_VERSION"
tools_install python "$PYTHON_VERSION"
tools_install golang "$GOLANG_VERSION"
tools_install java "$JAVA_VERSION"
tools_install flutter "$FLUTTER_VERSION"
tools_install terraform "$TERRAFORM_VERSION"
tools_install kubectl "$KUBECTL_VERSION"
tools_install helm "$HELM_VERSION"
tools_install sops "$SOPS_VERSION"

# asdf plugin config
# set-java-home.bash keeps JAVA_HOME pointed at the active asdf Java
cat >> "$PROFILE_CONFIG" <<'EOF'
. ${ASDF_DATA_DIR:-$HOME/.asdf}/plugins/java/set-java-home.bash
. <(asdf completion bash)
EOF
reload_profile

# android sdk and cli setup
export ANDROID_HOME="$HOME/android/sdk"
CLI_TOOLS_OUTPUT=cli-tools.zip
mkdir -p "$ANDROID_HOME"
curl -fsSL -o "$CLI_TOOLS_OUTPUT" "$ANDROID_CLI"
unzip -q "$CLI_TOOLS_OUTPUT" -d "$ANDROID_HOME"
mv "$ANDROID_HOME/cmdline-tools" "$ANDROID_HOME/latest"
mkdir -p "$ANDROID_HOME/cmdline-tools"
mv "$ANDROID_HOME/latest" "$ANDROID_HOME/cmdline-tools"
rm -f "$CLI_TOOLS_OUTPUT"

# set android home path
cat >> "$PROFILE_CONFIG" <<'EOF'

# android
export ANDROID_HOME=$HOME/android/sdk
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
export PATH=$PATH:$ANDROID_HOME/platform-tools
export ANDROID_SDK_ROOT=$ANDROID_HOME
EOF
reload_profile

# android sdkmanager basic tools installation
# `yes` is killed by SIGPIPE once sdkmanager stops reading — that is expected.
yes | sdkmanager --licenses || true
sdkmanager --install "platform-tools" "platforms;android-36" "build-tools;36.0.0"

# sonar-scanner setup
export SONAR_HOME="$HOME/sonarqube"
SONAR_SCANNER_OUTPUT=sonar-scanner-cli.zip
mkdir -p "$SONAR_HOME"
curl -fsSL -o "$SONAR_SCANNER_OUTPUT" "$SONAR_SCANNER_CLI"
unzip -q "$SONAR_SCANNER_OUTPUT" -d "$SONAR_HOME"
mv "$SONAR_HOME/sonar-scanner-$SONAR_SCANNER_VERSION" "$SONAR_HOME/sonar-scanner"
rm -f "$SONAR_SCANNER_OUTPUT"

# set sonar-scanner path
cat >> "$PROFILE_CONFIG" <<'EOF'

# sonar
export SONAR_HOME=$HOME/sonarqube
export PATH=$PATH:$SONAR_HOME/sonar-scanner/bin
EOF
reload_profile

# cleanup
brew cleanup

# verify every toolchain resolves — fail the build if one does not
echo "==> verifying installed toolchain"
node --version
python --version
go version
java -version
flutter --version
terraform version
kubectl version --client
helm version
sops --version
sonar-scanner --version
sdkmanager --version
echo "==> toolchain OK"
