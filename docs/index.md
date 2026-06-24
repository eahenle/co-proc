# co-proc

`co-proc` adds named, multiple simultaneous coprocesses to zsh without replacing
native `coproc`.

The native shell feature exposes only one active coprocess through the special
`p` redirection target. `co-proc` starts a native coprocess, immediately
duplicates the `p` descriptors into stable numbered descriptors, and records
those descriptors in a registry keyed by name.

```zsh
source ./co-proc.zsh

co-proc start calc bc -l
co-proc send calc 'sqrt(144)'
co-proc read -t 1 calc
co-proc stop calc
```

Interactive users may opt into natural extended syntax:

```zsh
co-proc enable-zle
coproc calc bc -l
coproc send calc 'sqrt(144)'
coproc read calc
```

Native zsh forms remain native:

```zsh
coproc bc
coproc { cat }
coproc while read -r line; do print -r -- "$line"; done
```

## Status

This repository is structured as a release-ready zsh plugin:

- sourceable implementation in `src/co-proc.zsh`
- automated zsh test harness in `tests/run.zsh`
- GitHub Actions for lint, tests, docs, and install smoke validation
- MkDocs Material documentation
- example scripts
- architecture and blog-development notes
