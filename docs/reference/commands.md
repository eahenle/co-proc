# Commands

## `co-proc start NAME COMMAND [ARG...]`

Start a named coprocess.

Names must match:

```text
[A-Za-z_][A-Za-z0-9_-]*
```

Startup fails if the name already exists, the command is missing, or the command
cannot be resolved.

## `co-proc list`

Print one line per running registered process:

```text
calc pid=12345 in=13 out=12 state=running current
```

Attachable entries use endpoint paths instead of numbered descriptors and end
with the `attachable` marker.

## `co-proc spawn NAME COMMAND [ARG...]`

Start a detached, attachable process with stdin and stdout connected to a
private FIFO pair. The default runtime root is the current user's temporary
directory plus `co-proc-$EUID`; set `CO_PROC_RUNTIME_ROOT` to override it.

The runtime root and each endpoint directory must be owned by the current user
with mode `700`. Endpoint FIFOs and metadata use mode `600`. Existing endpoints
are never overwritten; use `co-proc stop NAME` or `co-proc prune` first.

## `co-proc attach NAME`

Validate and discover an attachable endpoint from an independent zsh process.
The command reports its PID, endpoint paths, and live state without exposing
message contents.

## `co-proc info NAME`

Print registry details for one process.

## `co-proc send NAME TEXT...`

Write one line to the named process.

When `NAME` resolves to an attachable process, `send` requires exactly one
bounded NDJSON frame. The frame must be at most `CO_PROC_MAX_FRAME_BYTES` bytes
(4095 by default), contain no newline, and include `version: 1` plus non-empty
`type` and `id` fields.

## `co-proc read [-t SECONDS] [NAME]`

Read one line from the named process. If `NAME` is omitted, `co-proc` uses the
current process. The current process is the most recently started or switched
process.

## `co-proc recv [-t SECONDS] NAME`

Read one complete line from an attachable process. `recv` never falls back to a
shell-local numbered-descriptor entry; use `read` for those entries. When a
shell has already pumped the channel, `recv` consumes its oldest buffered frame.

## `co-proc pump [-t SECONDS] [NAME...]`

Open the named attachable outputs, wait for any of them with `zselect`, drain
every ready descriptor with `sysread`, assemble partial lines, and queue complete
frames per name. When names are omitted, `pump` discovers all endpoints under
the runtime root.

The timeout is expressed in seconds. `pump` returns success when it read bytes
and returns failure on timeout. Per-name queued plus partial data is bounded by
`CO_PROC_MAX_BUFFER_BYTES` (65536 by default), so a stalled consumer fails
explicitly instead of growing memory without limit.

## `co-proc switch NAME`

Set the current process.

## `co-proc stop [-f] NAME`

Close registered descriptors and terminate the process. Without `-f`, `co-proc`
sends `TERM`, waits briefly, then sends `KILL` if needed. With `-f`, it sends
`KILL` immediately.

## `co-proc wait NAME`

Wait for a registered process and remove it from the active registry.

## `co-proc prune`

Remove exited processes from the active registry and retain their exit code in
`CO_PROC_EXIT`.

## `co-proc cleanup`

Stop all registered processes.

## `co-proc enable-zle`

Install the optional interactive rewrite widget.

## `co-proc disable-zle`

Remove the optional interactive rewrite widget.
