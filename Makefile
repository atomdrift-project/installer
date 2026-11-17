# Every installer is generated: one template per shell, one config per tool.
# Edit templates/install.sh.in, templates/install.ps1.in, or
# products/<tool>.conf, then `make regen`.
#
#   make regen    rewrite the installers from the template
#   make check    fail if a checked-in installer is stale (what CI runs)
#   make lint     shellcheck everything, including the rendered output
#   make test     the POSIX shell test suite
#   make all      lint, check, and test

PRODUCTS := scan cleave isomer hood
# Tools with a PowerShell installer; each needs WINDOWS_TARGETS in its config.
WINDOWS_PRODUCTS := scan cleave
SH_INSTALLERS := $(addsuffix .sh,$(PRODUCTS))
INSTALLERS := $(SH_INSTALLERS) $(addsuffix .ps1,$(WINDOWS_PRODUCTS))
SHELLS := sh dash ksh bash zsh

.PHONY: all regen check lint test clean

all: lint check test

# Always renders, and says what it did. Timestamp-driven prerequisites would let
# make answer "nothing to be done" — technically true, unhelpful from a command
# whose whole job is to rewrite these files. Rendering a few scripts is cheap;
# wondering whether it ran is not. Unchanged output keeps its old file, so an
# installer nobody edited keeps its mtime.
regen:
	@for i in $(INSTALLERS); do \
		sh tools/render.sh $$i "$$i.new" || exit 1; \
		if cmp -s "$$i" "$$i.new" 2>/dev/null; then \
			rm -f "$$i.new"; \
			printf 'unchanged  %s\n' "$$i"; \
		else \
			mv -f "$$i.new" "$$i" || exit 1; \
			printf 'wrote      %s\n' "$$i"; \
		fi; \
	done

# A stale installer is a silent bug: the file people curl is the one in the
# repository, not the one the template would produce today.
check:
	@status=0; \
	for i in $(INSTALLERS); do \
		sh tools/render.sh $$i "$$i.check" || exit 1; \
		if cmp -s "$$i" "$$i.check"; then \
			printf 'ok       %s is current\n' "$$i"; \
		else \
			printf 'stale    %s differs from the template — run make regen\n' "$$i" >&2; \
			diff -u "$$i" "$$i.check" || :; \
			status=1; \
		fi; \
		rm -f "$$i.check"; \
	done; \
	exit $$status

lint:
	shellcheck -s sh $(SH_INSTALLERS) action.sh tools/render.sh tests/*.sh
	sh tests/workflow.sh

# The suite drives scan.sh, which the template renders for every tool, so a
# regression in shared behaviour surfaces here whichever tool introduced it.
test:
	@for t in generated action platforms install-dir brew source-cache tools; do \
		for s in $(SHELLS); do \
			command -v $$s >/dev/null 2>&1 || continue; \
			printf '%s %s\n' "$$s" "tests/$$t.sh"; \
			case $$s in \
			bash) bash --posix tests/$$t.sh ;; \
			zsh) zsh --emulate sh tests/$$t.sh ;; \
			*) $$s tests/$$t.sh ;; \
			esac || exit 1; \
		done; \
	done; \
	sh tests/index.sh

clean:
	rm -f $(addsuffix .check,$(INSTALLERS)) $(addsuffix .new,$(INSTALLERS))
