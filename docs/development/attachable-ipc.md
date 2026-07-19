# Attachable Cross-process IPC

Status: design proposal; the commands and endpoints below are not implemented.

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

The concrete transport may use Unix sockets or paired named pipes. Creation
must reject unsafe ownership, symlinks, invalid names, and unexpectedly broad
permissions. Cleanup must verify the recorded PID and endpoint ownership before
removing anything.

## Proposed behavior

- `co-proc spawn NAME COMMAND...` starts an attachable managed process.
- `co-proc attach NAME` resolves the endpoints for an independent client.
- `co-proc send NAME JSON` writes one bounded NDJSON frame.
- `co-proc recv NAME` returns one complete buffered frame.
- `co-proc pump` uses `zselect` to drain every readable endpoint into a
  per-name buffer before dispatching complete lines.
- `co-proc info NAME` reports readiness, PID, endpoint paths, buffered bytes,
  and peer state without exposing message bodies.

Existing `start`, `send`, `read`, `stop`, and native zsh compatibility must
remain intact unless an attachable mode was explicitly requested.

## Framing and backpressure

Messages are UTF-8 NDJSON control frames. Binary data is never written to a
channel; callers send an absolute file path plus immutable IDs and metadata.
Set a maximum frame and buffer size, reject unterminated oversized frames, and
surface `ready`, `busy`, `ack`, `result`, and `error` states. The supervisor
must continuously drain readable channels so one worker filling a roughly
64-KiB pipe cannot deadlock unrelated workers.

## Validation

Add tests for multiple simultaneous attached clients, partial-line buffering,
messages larger than one read chunk, slow readers, full-pipe backpressure,
worker exit during a write, stale endpoint cleanup, permissions, malformed
frames, and preservation of all existing `co-proc` behavior.
