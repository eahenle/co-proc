#!/usr/bin/env zsh

emulate -R zsh
setopt errexit pipe_fail

source "${0:A:h:h}/co-proc.zsh"

if ! command -v python3 >/dev/null 2>&1; then
  print -ru2 -- "python3 is required for this example"
  exit 1
fi

co-proc start py python3 -u -c '
import sys

for line in sys.stdin:
    value = line.rstrip("\n")
    print(value.upper(), flush=True)
'

co-proc send py "hello from zsh"
print -r -- "$(co-proc read -t 1 py)"

co-proc send py "multiple named services can run side by side"
print -r -- "$(co-proc read -t 1 py)"

co-proc stop py
