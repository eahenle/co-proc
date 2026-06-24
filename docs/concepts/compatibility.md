# Compatibility

`co-proc` does not replace the zsh `coproc` reserved word.

This is intentional. In zsh, `coproc` is parsed as a reserved word rather than
resolved as a builtin or ordinary command. A shell function named `coproc` cannot
wrap it while preserving native grammar such as:

```zsh
coproc { cat }
coproc while read -r line; do print -r -- "$line"; done
```

## Preserved native syntax

These remain zsh-native and are not rewritten unless the optional interactive
widget sees a simple extended form:

```zsh
coproc bc
coproc { ... }
coproc while ...
coproc for ...
coproc if ...
```

## Extended syntax

Scriptable extended syntax uses `co-proc`:

```zsh
co-proc start calc bc -l
co-proc list
co-proc send calc '1 + 1'
co-proc read calc
co-proc stop calc
```

With the optional ZLE integration enabled, interactive commands like these are
rewritten before acceptance:

```zsh
coproc calc bc -l
coproc list
coproc send calc '1 + 1'
```

The widget does not rewrite lines with redirections, pipes, separators, groups,
or native control words. Use explicit `co-proc start NAME zsh -c '...'` for
complex startup forms.

## Mixing native and named coprocesses

Starting any coprocess retargets zsh's special `p` handle. `co-proc` preserves
named processes by saving ordinary descriptors before later coprocesses retarget
`p`. If you use native `coproc` directly and need to keep it after starting
another coprocess, save its descriptors first.
