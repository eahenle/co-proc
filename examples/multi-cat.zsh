#!/usr/bin/env zsh

emulate -R zsh
setopt errexit pipe_fail

source "${0:A:h:h}/co-proc.zsh"

for name in alpha beta gamma; do
  co-proc start "$name" cat
done

co-proc send alpha "message for alpha"
co-proc send beta "message for beta"
co-proc send gamma "message for gamma"

for name in alpha beta gamma; do
  print -r -- "$name -> $(co-proc read -t 1 "$name")"
done

co-proc cleanup
