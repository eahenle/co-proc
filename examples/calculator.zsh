#!/usr/bin/env zsh

emulate -R zsh
setopt errexit pipe_fail

source "${0:A:h:h}/co-proc.zsh"

if ! command -v bc >/dev/null 2>&1; then
  print -ru2 -- "bc is required for this example"
  exit 1
fi

co-proc start calc bc -l

co-proc send calc "2 ^ 16"
print -r -- "2 ^ 16 = $(co-proc read -t 1 calc)"

co-proc send calc "scale=4; 22 / 7"
print -r -- "22 / 7 = $(co-proc read -t 1 calc)"

co-proc stop calc
