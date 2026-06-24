# Registry

The registry is stored in global associative arrays:

```zsh
CO_PROC_IN[$name]
CO_PROC_OUT[$name]
CO_PROC_PID[$name]
CO_PROC_CMD[$name]
CO_PROC_STARTED[$name]
CO_PROC_EXIT[$name]
```

`CO_PROC_CURRENT` stores the current process name.

These arrays are intentionally simple. They are useful for inspection and tests,
but callers should prefer commands such as `co-proc info`, `co-proc list`, and
`co-proc switch`.

## Lifecycle

1. `co-proc start` calls native `coproc COMMAND`.
2. It captures output and input descriptors from `p`.
3. It records descriptors and pid in the registry.
4. `co-proc send` writes to `CO_PROC_IN[$name]`.
5. `co-proc read` reads from `CO_PROC_OUT[$name]`.
6. `co-proc stop`, `wait`, or `prune` closes descriptors and updates registry
   state.

`co-proc` installs a `zshexit` hook through `add-zsh-hook` so registered
processes are cleaned up when the shell exits.
