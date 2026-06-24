# What Is a Coprocess?

A coprocess is a process connected to the shell by pipes in both directions.
The shell can write to the process's stdin and read from the process's stdout.

In zsh:

```zsh
coproc cat
print -r -- hello >&p
read -r line <&p
print -r -- "$line"
```

The special `p` redirection target is the key limitation. zsh can start another
coprocess, and the operating system can handle many pipes, but zsh exposes only
one current `p` target at a time.

`co-proc` uses native zsh behavior to create the process, then duplicates the
current `p` descriptors into ordinary numbered file descriptors:

```zsh
exec {outfd}<&p
exec {infd}>&p
```

Those ordinary descriptors remain usable after another coprocess retargets
`p`.
