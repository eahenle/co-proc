# Development Journal

## 2026-06-24

Initial repository created.

Implementation decisions:

- Keep native `coproc` untouched.
- Use `co-proc` for scriptable commands.
- Add optional ZLE rewrite for interactive extended syntax.
- Use `${(z)BUFFER}` token inspection instead of regex matching.
- Store named descriptors in associative arrays.
- Install cleanup with `add-zsh-hook zshexit`.

Discovery:

- zsh reports `coproc` as a reserved word.
- `builtin coproc` does not exist.
- A function wrapper cannot preserve native grouped/control syntax.

Test coverage added:

- basic start, send, read, stop
- two simultaneous processes
- twenty simultaneous processes and FD uniqueness
- duplicate names and invalid input
- unexpected process exit and pruning
- native simple and grouped coprocess compatibility
- token-inspection rewrite behavior
- current process switching
- 200 sequential create/destroy cycles
