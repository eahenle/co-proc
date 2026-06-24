# Long-Running Services

Named coprocesses are most useful for tools that stay alive and amortize startup
cost:

- interpreters
- database shells
- local protocol adapters
- model or agent servers
- test fixtures

Recommended pattern:

```zsh
co-proc start service command --with --flags
co-proc info service

co-proc send service request
co-proc read -t 5 service

co-proc stop service
```

For services with structured protocols, build a small wrapper function around
`co-proc send` and `co-proc read` so callers do not rely on raw line ordering.
