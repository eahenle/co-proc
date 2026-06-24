# Python Service

Use `python3 -u` for unbuffered stdio.

```zsh
co-proc start py python3 -u -c '
import sys

for line in sys.stdin:
    print(line.rstrip().upper(), flush=True)
'

co-proc send py 'hello'
co-proc read -t 1 py
co-proc stop py
```

The repository includes a runnable version:

```sh
examples/python-service.zsh
```
