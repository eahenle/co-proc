# Getting Started

## Install from a checkout

```sh
git clone https://github.com/eahenle/co-proc.git
cd co-proc
make test
make install
```

Then add the printed source line to `~/.zshrc`:

```zsh
source "$HOME/.local/share/co-proc/co-proc.zsh"
```

You can also source directly from a checkout:

```zsh
source /path/to/co-proc/co-proc.zsh
```

## First coprocess

```zsh
co-proc start echoer cat
co-proc send echoer hello
co-proc read -t 1 echoer
co-proc stop echoer
```

## Multiple coprocesses

```zsh
co-proc start a cat
co-proc start b cat

co-proc send a one
co-proc send b two

co-proc read -t 1 a
co-proc read -t 1 b

co-proc cleanup
```

## Optional interactive syntax

Enable the ZLE widget in an interactive zsh session:

```zsh
co-proc enable-zle
```

After that, simple extended commands are rewritten before execution:

```zsh
coproc calc bc -l
coproc list
coproc send calc '2 + 2'
coproc read calc
coproc stop calc
```

The rewrite is deliberately conservative. If a line contains shell control
operators, redirection, grouped commands, or native control words, it is left
unchanged.
