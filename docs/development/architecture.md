# Architecture

## Principle

Use native zsh `coproc` to create processes, then escape the single-`p`
limitation by duplicating file descriptors into normal numbered descriptors.

## Why not a `coproc` function?

The first design question was whether a shell function named `coproc` could
inspect tokens and delegate native forms back to zsh.

That does not work cleanly because zsh parses `coproc` as a reserved word. A
function cannot sit in front of the reserved word while preserving grammar for
native forms such as `coproc { ... }` and `coproc while ...`.

Disabling the reserved word lets a function named `coproc` exist, but then zsh
no longer parses native coprocess grammar. That violates the compatibility goal.

## Chosen design

- Scriptable API: `co-proc ...`
- Optional interactive sugar: a ZLE `accept-line` widget
- Token inspection: `${(z)BUFFER}` instead of a command-line regex
- Conservative rewrite: only simple extended forms are rewritten

## FD ownership

`co-proc start NAME COMMAND` performs:

```zsh
coproc COMMAND
exec {outfd}<&p
exec {infd}>&p
```

The numbered descriptors are then owned by the registry entry for `NAME`.

## Cleanup

`co-proc stop` closes both descriptors, terminates the child, waits for it, and
removes the active registry entry.

`co-proc cleanup` stops every registered process and is registered with
`add-zsh-hook zshexit`.

## Current limitations

- Complex native-like forms should use native `coproc` or explicit
  `co-proc start NAME zsh -c '...'`.
- The interactive rewrite intentionally refuses lines with redirection, pipes,
  separators, grouped commands, or control operators.
- zsh still retargets the special `p` handle whenever any native coprocess is
  started.
- Numbered descriptors are owned by the sourcing zsh process; unrelated
  processes cannot currently discover or attach to a named registry entry.

## Proposed attachable transport

An upcoming consumer needs named channels that independent processes can attach
to without inheriting the registry shell's descriptors. This is a multiplexer
extension, not a replacement for the existing native-coproc-backed API.

The proposal uses owner-only endpoints beneath `/tmp/co-proc/$UID/` (or a secure
equivalent under `$TMPDIR`), newline-delimited control messages, continuous
`zselect` draining into per-name buffers, and explicit backpressure signals.
Binary payloads stay out of band and are referenced by path.

See [Attachable cross-process IPC](attachable-ipc.md) for the draft contract.
