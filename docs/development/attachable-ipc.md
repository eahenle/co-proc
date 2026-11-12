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
Send, direct receive, and pumped receive use the same structural validator:

- One complete UTF-8 JSON object, with no trailing data. Leading/trailing JSON
  spaces and tabs are allowed. The root must contain integer `version: 1`
  (not `true`, `"1"`, `1.0`, or `1e0`) and non-empty string `type` and `id`.
  Nested fields never substitute for root fields.
- Strings are checked after JSON escape decoding. Escaped quotes, backslashes,
  control characters, Unicode escapes, and valid surrogate pairs are supported.
  Non-empty strings may contain spaces; a whitespace-only string is non-empty.
  Invalid UTF-8 and lone/reversed surrogate escapes are rejected, including
  inside application payloads and object keys.
- Duplicate object keys are rejected at every depth, including differently
  escaped spellings of the same decoded name. This avoids first/last-key
  ambiguity in both the envelope and application payloads.
- Application fields may contain arbitrary JSON values and nested objects or
  arrays, subject to the frame size and Python parser's nesting/numeric limits.
  Non-JSON constants such as `NaN` and `Infinity` are rejected. Validation does
  not normalize or reserialize accepted frames; their original bytes survive.
- A frame is at most `CO_PROC_MAX_FRAME_BYTES` bytes (4095 by default), excluding
  its terminating LF. Literal LF and CR are not allowed inside the frame, even
  as JSON whitespace. Use escaped `\n` / `\r` inside strings instead. `send`
  adds the one terminating LF, keeping default-sized FIFO writes atomic.

The validator uses the Python 3 standard library (`json` and `decimal`), invoked
as `python3` from `PATH` in isolated mode. No third-party Python package is needed.
A missing Python executable or packaged helper reports a clear error and status
69; invalid frames return 65 and oversized frames return 75. Native coprocesses
and the in-shell API do not invoke this parser. `make install` copies the helper
alongside the shell source, without installing Python or changing shell profiles.

Invalid sends do not write to the peer. Invalid received frames are not printed
or queued; the rejecting direct `recv` / `pump` call returns nonzero. After a
pump FD is open, `recv` returns a buffered valid frame if available. If no valid
frame is available, it preserves the pump failure status (including 65 for a
rejected frame), or returns status 1 for a timeout or incomplete frame.

The pump assembles partial lines, enforces a configurable per-name buffer
ceiling, and drains every ready channel so a slow consumer on one channel does
not prevent progress on unrelated workers.

If a read contains rejected frames, the pump discards those lines while still
queuing every valid complete frame in that read, in order, and retaining any
incomplete tail. It reports the first rejection status rather than success.
The remaining ready channels are still serviced before that error is returned;
valid output does not depend on a malformed peer writing another byte. Buffer
ceilings still apply before a chunk is accepted. A caller may drain valid queued
frames with `recv` after handling the pump error.

## Validation

Current tests cover independent attached clients, simultaneous atomic writers,
partial-line assembly, multi-channel pumping, buffer ceilings, stale endpoint
cleanup, permissions, structural JSON/envelope rejection, Unicode and escape
handling, duplicate keys, byte bounds, missing parser behavior, and preservation of all
existing `co-proc` behavior. Slow-reader saturation and worker exit during a
write remain follow-up stress cases.
