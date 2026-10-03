# Synced from AinkradAppKit/scripts — edit there, then run scripts/guardrails-sync.sh.
FORMAT_PATHS := Sources $(wildcard Tests)
.PHONY: lint lint-check lint-rebaseline format format-check hooks
lint:            ; @./scripts/design-lint.sh
lint-check:      ; @./scripts/design-lint.sh --check
lint-rebaseline: ; @./scripts/design-lint.sh --rebaseline
format:          ; swift format format -i --recursive --parallel $(FORMAT_PATHS)
format-check:
	@if grep -qx 'format on' .design-lint-baseline; then \
	  swift format lint --strict --recursive --parallel $(FORMAT_PATHS); \
	else echo "format-check: SKIPPED - repo not yet formatted (baseline: format off)"; fi
hooks:
	@test -x scripts/git-hooks/pre-push || { echo "hooks: pre-push missing or not executable"; exit 1; }
	git config core.hooksPath scripts/git-hooks
