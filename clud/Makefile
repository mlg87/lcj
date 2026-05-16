# clud/Makefile
# Single-command quality and dev loops. `make check` is the gate before commit.

.PHONY: install test lint typecheck shellcheck check smoke

install:
	uv venv
	uv pip install -e ".[dev]"

test:
	pytest -v

lint:
	ruff check .
	ruff format --check .

typecheck:
	mypy plugin

shellcheck:
	@if ls hooks/*.sh 1>/dev/null 2>&1; then shellcheck hooks/*.sh; else echo "shellcheck: no hooks yet, skipping"; fi

check: lint typecheck shellcheck test

smoke:
	@cat docs/SMOKE.md
