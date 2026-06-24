# Parser Notes

## Findings

`coproc` is a zsh reserved word:

```zsh
whence -w coproc
# coproc: reserved
```

There is no `builtin coproc` to call from a function wrapper.

## Function wrapper investigation

Disabling the reserved word permits a function named `coproc`, but the parser no
longer recognizes native coprocess grammar. That breaks compatibility with
grouped and control-flow forms.

Conclusion: do not replace the reserved word.

## ZLE rewrite strategy

The optional widget uses zsh tokenization:

```zsh
words=(${(z)BUFFER})
```

The rewrite activates when:

- token 1 is `coproc`
- token 2 is a registry command, or
- token 2 is a valid co-proc name and token 3 begins a simple command

The rewrite refuses:

- pipes
- command separators
- redirections
- grouping tokens
- native control-flow words

This keeps the extension predictable and avoids regex-driven parsing.
