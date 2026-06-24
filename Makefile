.PHONY: all lint syntax shellcheck shfmt test docs docs-build install smoke clean

ZSH_BIN ?= zsh
PREFIX ?= $(HOME)/.local/share/co-proc

ZSH_FILES := co-proc.zsh src/co-proc.zsh tests/run.zsh examples/calculator.zsh examples/multi-cat.zsh examples/python-service.zsh
SH_FILES := scripts/install.sh scripts/lint-shfmt.sh

all: lint test

lint: syntax shellcheck shfmt

syntax:
	$(ZSH_BIN) -n co-proc.zsh
	$(ZSH_BIN) -n src/co-proc.zsh
	$(ZSH_BIN) -n tests/run.zsh
	$(ZSH_BIN) -n examples/calculator.zsh
	$(ZSH_BIN) -n examples/multi-cat.zsh
	$(ZSH_BIN) -n examples/python-service.zsh

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SH_FILES); \
	else \
		echo "shellcheck not found; skipping"; \
	fi

shfmt:
	@./scripts/lint-shfmt.sh

test:
	$(ZSH_BIN) tests/run.zsh

docs:
	mkdocs serve

docs-build:
	mkdocs build --strict

install:
	PREFIX="$(PREFIX)" ./scripts/install.sh

smoke:
	$(ZSH_BIN) -fc 'source "$(PREFIX)/co-proc.zsh"; co-proc start smoke cat; co-proc send smoke ok; [[ "$$(co-proc read -t 1 smoke)" == ok ]]; co-proc stop smoke'

clean:
	rm -rf site dist tmp
