# Calculator

`bc -l` is a useful minimal coprocess because it accepts line-oriented input and
prints line-oriented output.

```zsh
co-proc start calc bc -l

co-proc send calc '2 ^ 16'
co-proc read -t 1 calc

co-proc send calc 'scale=4; 22 / 7'
co-proc read -t 1 calc

co-proc stop calc
```

The repository includes a runnable version:

```sh
examples/calculator.zsh
```
