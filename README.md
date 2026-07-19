# co-proc

`co-proc` is a sourceable zsh enhancement layer for named coprocesses.

zsh has native `coproc`, but the shell exposes only one active coprocess through
the special `p` redirection target. `co-proc` keeps native `coproc` intact and
adds a registry that captures each coprocess into stable file descriptors.

```zsh
source ./co-proc.zsh

co-proc start calc bc -l
co-proc send calc '2 ^ 10'
co-proc read -t 1 calc
co-proc stop calc
```

For cross-process NDJSON control channels, start an attachable process. The
process survives the shell that spawned it, and later shells discover it through
an owner-only runtime directory:

```zsh
co-proc spawn agent cat
co-proc send agent '{"version":1,"type":"ready","id":"agent-1"}'
co-proc pump -t 1 agent
co-proc recv -t 1 agent
co-proc stop agent
```

Attachable frames are limited to 4095 bytes so concurrent FIFO writers remain
atomic. Every frame must be one line with `version: 1` and non-empty `type` and
`id` fields. Binary payloads stay out of band and are referenced by path.

Interactive users can opt into natural extended syntax:

```zsh
co-proc enable-zle

coproc calc bc -l
coproc send calc '2 ^ 10'
coproc read calc
coproc stop calc
```

The ZLE layer rewrites only simple extended forms. Native forms such as
`coproc bc`, `coproc { ... }`, and `coproc while ...` are left for zsh itself.

## Install

```sh
git clone https://github.com/eahenle/co-proc.git
cd co-proc
make test
make install
```

Then add the installed source line printed by `make install` to `~/.zshrc`.

## Commands

```zsh
co-proc start NAME COMMAND [ARG...]
co-proc spawn NAME COMMAND [ARG...]
co-proc attach NAME
co-proc list
co-proc info NAME
co-proc send NAME TEXT...
co-proc read [-t SECONDS] [NAME]
co-proc recv [-t SECONDS] NAME
co-proc pump [-t SECONDS] [NAME...]
co-proc switch NAME
co-proc stop [-f] NAME
co-proc wait NAME
co-proc prune
```

Aliases are provided for convenience:

```zsh
cpsend   # co-proc send
cpread   # co-proc read
cplist   # co-proc list
cpstop   # co-proc stop
```

## Development

```sh
make lint
make test
make docs-build
```

ShellCheck does not parse zsh syntax directly, so linting combines:

- `zsh -n` for zsh files
- ShellCheck for POSIX helper scripts
- `shfmt` for POSIX helper scripts

Documentation lives in `docs/` and is built with MkDocs Material.

## License

`co-proc` is released under the MIT License. See [LICENSE](LICENSE).
