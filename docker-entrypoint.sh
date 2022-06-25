#!/usr/bin/env bash
set -Eeuo pipefail

# first arg is `-f` or `--some-option`
# or there are no args
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
	# docker run bash
	exec bash -l "$@"
fi

exec "$@"
