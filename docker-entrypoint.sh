#!/usr/bin/env bash
set -Eeuo pipefail

# sonar-scanner
declare -a args=()

add_env_var_as_env_prop() {
  if [ "$1" ]; then
    args+=("-D$2=$1")
  fi
}

# first arg is `-f` or `--some-option`
# or there are no args
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	# docker run bash
	exec bash -l "$@"
fi

# sonar-scanner-cli
if [[ "$1" = 'sonar-scanner' ]]; then
  add_env_var_as_env_prop "${SONAR_LOGIN:-}" "sonar.login"
  add_env_var_as_env_prop "${SONAR_PASSWORD:-}" "sonar.password"
  add_env_var_as_env_prop "${SONAR_PROJECT_BASE_DIR:-}" "sonar.projectBaseDir"
  if [ ${#args[@]} -ne 0 ]; then
    set -- sonar-scanner "${args[@]}" "${@:2}"
  fi
fi

exec "$@"
