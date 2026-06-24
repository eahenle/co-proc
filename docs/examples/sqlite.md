# SQLite

SQLite can be used as a line-oriented coprocess for quick local queries.

```zsh
co-proc start db sqlite3 test.db

co-proc send db 'create table if not exists notes (body text);'
co-proc send db "insert into notes values ('hello from co-proc');"
co-proc send db 'select rowid, body from notes;'
co-proc read -t 1 db

co-proc stop db
```

SQLite's default output mode is simple text. For scripts, set an explicit mode:

```zsh
co-proc send db '.mode json'
```
