#!/bin/sh

set -eu

if ! command -v shfmt >/dev/null 2>&1; then
  echo "shfmt not found; skipping"
  exit 0
fi

set -- scripts/*.sh

if [ ! -e "$1" ]; then
  echo "no POSIX shell files to format-check"
  exit 0
fi

shfmt -d "$@"
