#!/bin/sh

set -eu

prefix=${PREFIX:-"$HOME/.local/share/co-proc"}

mkdir -p "$prefix/src"
cp co-proc.zsh "$prefix/co-proc.zsh"
cp src/co-proc.zsh "$prefix/src/co-proc.zsh"
cp src/validate-frame.py "$prefix/src/validate-frame.py"

printf '%s\n' "Installed co-proc to $prefix"
printf '%s\n' "Add this to ~/.zshrc:"
printf '%s\n' "  source \"$prefix/co-proc.zsh\""
