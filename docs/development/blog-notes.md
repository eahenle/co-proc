# Blog Notes

Working title:

> zsh only supports one coprocess? No. That will not do.

## Problem

zsh has a useful `coproc` feature, but its user-facing abstraction exposes only
one active coprocess through `p`.

That makes the feature feel smaller than what the operating system can support.
Pipes and file descriptors are not the limiting factor.

## Observation

The limitation is primarily the shell abstraction. If the descriptors behind
`p` are duplicated into normal numbered descriptors, they keep working even
after zsh retargets `p` for a later coprocess.

## Experiment

Prototype:

```zsh
coproc command
exec {outfd}<&p
exec {infd}>&p
```

Then store `outfd`, `infd`, and `$!` in associative arrays keyed by name.

## Result

Multiple simultaneous coprocesses are practical:

```zsh
co-proc start calc bc -l
co-proc start echo cat
co-proc start py python3 -u service.py
```

Each process can be addressed by name without relying on the current `p`.

## Parser surprise

The natural idea was to write a shell function named `coproc`. That fails the
compatibility test because zsh parses `coproc` as a reserved word. Replacing it
would sacrifice native syntax.

The better layer is:

- explicit `co-proc` API for scripts
- optional ZLE rewrite for interactive ergonomics

## Lesson

Sometimes a feature is not missing because it is impossible. Sometimes the
available abstraction stopped one layer too early.
