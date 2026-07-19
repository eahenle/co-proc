# Attachable Cross-process IPC

Status: attachable FIFO transport and buffered multiplexing implemented; richer
peer-state semantics remain follow-up work.

## Motivation

`co-proc` currently multiplexes native zsh coprocesses by copying the special
`p` descriptors into numbered FDs owned by the sourcing shell. That solves the
singleton problem inside one zsh process, but an unrelated process cannot
attach to a registry entry.

The proposed extension publishes secure named endpoints so a long-lived
supervisor, workers, and independent clients can exchange control messages
without polling a filesystem mailbox.

## Runtime layout

Use an owner-only directory such as:

```text
/tmp/co-proc/$UID/
  registry.json
  NAME/
    input
    output
    metadata.json
```

The initial transport uses paired named pipes beneath a secure per-user runtime
root. Creation rejects unsafe ownership, symlinks, invalid names, and
unexpectedly broad permissions. Cleanup verifies the recorded PID and endpoint
ownership before removing anything.

## Proposed behavior

- `co-proc spawn NAME COMMAND...` starts an attachable managed process.
- `co-proc attach NAME` resolves the endpoints for an independent client.
- `co-proc send NAME JSON` writes one bounded NDJSON frame.
- `co-proc recv NAME` returns one complete buffered frame.
- `co-proc info NAME` reports readiness, PID, endpoint paths, buffered bytes,
  and peer state without exposing message bodies.

Implemented now: `spawn`, `attach`, cross-process `send`, `recv`, endpoint-aware
`info`, `list`, `stop`, stale `prune`, and `pump` using `zselect` and `sysread`
to drain readable endpoints into bounded per-name buffers. Richer peer-state
fields in `info` remain planned.

Existing `start`, `send`, `read`, `stop`, and native zsh compatibility must
remain intact unless an attachable mode was explicitly requested.

## Framing and backpressure

Messages are UTF-8 NDJSON control frames. Binary data is never written to a
channel; callers send an absolute file path plus immutable IDs and metadata.
The sender enforces a 4095-byte limit, a single terminated line, and a version-1
envelope with non-empty `type` and `id`, which keeps simultaneous writes atomic.
The pump assembles partial lines, enforces a configurable per-name buffer
ceiling, and drains every ready channel so a slow consumer on one channel does
not prevent progress on unrelated workers.

## Validation

Current tests cover independent attached clients, simultaneous atomic writers,
partial-line assembly, multi-channel pumping, buffer ceilings, stale endpoint
cleanup, permissions, envelope rejection, frame bounds, and preservation of all
existing `co-proc` behavior. Slow-reader saturation and worker exit during a
write remain follow-up stress cases.
