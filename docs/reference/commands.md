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

## `co-proc info NAME`

Print registry details for one process.

## `co-proc send NAME TEXT...`

Write one line to the named process.

## `co-proc read [-t SECONDS] [NAME]`

Read one line from the named process. If `NAME` is omitted, `co-proc` uses the
current process. The current process is the most recently started or switched
process.

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
