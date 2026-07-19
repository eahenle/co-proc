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

## Attachable registry

Attachable processes are intentionally not owned by the shell-local descriptor
registry. They publish an owner-only endpoint directory beneath
`${CO_PROC_RUNTIME_ROOT:-${TMPDIR}/co-proc-$EUID}`:

```text
NAME/
  input
  output
  metadata.json
  child.pid
  stderr.log
```

`input` and `output` are mode-`600` FIFOs. `metadata.json` records version, name,
PID, owner UID, start time, and absolute endpoint paths. A shell that validates
an endpoint caches its discovered values in `CO_PROC_ATTACH_IN`,
`CO_PROC_ATTACH_OUT`, and `CO_PROC_ATTACH_PID` for that shell only.

Calling `co-proc pump` adds shell-local `CO_PROC_PUMP_FD`,
`CO_PROC_PUMP_BUFFER`, and `CO_PROC_PUMP_QUEUE` state. Partial frames remain in
the buffer; complete frames move to the FIFO queue consumed by `co-proc recv`.
The published endpoints and child process remain cross-process, while pump
buffers intentionally belong to the supervising shell.

Attachable processes are not stopped by the sourcing shell's `zshexit` hook.
They remain discoverable until `co-proc stop NAME`, or until they exit and a
later `co-proc prune` removes the stale, ownership-checked endpoint.

`co-proc` installs a `zshexit` hook through `add-zsh-hook` so registered
processes are cleaned up when the shell exits.
