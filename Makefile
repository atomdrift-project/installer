# The four Unix installers are generated: one template, one config per tool.
# Edit templates/install.sh.in or products/<tool>.conf, then `make regen`.
#
#   make regen    rewrite the installers from the template
#   make check    fail if a checked-in installer is stale (what CI runs)
#   make lint     shellcheck everything, including the rendered output
#   make test     the POSIX shell test suite
#   make all      lint, check, and test

PRODUCTS := scan cleave isomer hood
INSTALLERS := $(addsuffix .sh,$(PRODUCTS))
SOURCES := templates/install.sh.in tools/render.sh
SHELLS := sh dash ksh bash zsh

.PHONY: all regen check lint test clean

all: lint check test

# Always renders, and says what it did. Timestamp-driven prerequisites would let
# make answer "nothing to be done" — technically true, unhelpful from a command
# whose whole job is to rewrite these files. Rendering four scripts is cheap;
# wondering whether it ran is not. Unchanged output keeps its old file, so an
# installer nobody edited keeps its mtime.
regen:
	@for p in $(PRODUCTS); do \
		sh tools/render.sh $$p "$$p.sh.new" || exit 1; \
		if cmp -s "$$p.sh" "$$p.sh.new" 2>/dev/null; then \
			rm -f "$$p.sh.new"; \
			printf 'unchanged  %s.sh\n' "$$p"; \
		else \
			mv -f "$$p.sh.new" "$$p.sh" || exit 1; \
			printf 'wrote      %s.sh\n' "$$p"; \
		fi; \
	done

# A stale installer is a silent bug: the file people curl is the one in the
# repository, not the one the template would produce today.
check:
	@status=0; \
	for p in $(PRODUCTS); do \
		sh tools/render.sh $$p "$$p.sh.check" || exit 1; \
		if cmp -s "$$p.sh" "$$p.sh.check"; then \
			printf 'ok       %s.sh is current\n' "$$p"; \
		else \
			printf 'stale    %s.sh differs from the template — run make regen\n' "$$p" >&2; \
			diff -u "$$p.sh" "$$p.sh.check" || :; \
			status=1; \
		fi; \
		rm -f "$$p.sh.check"; \
	done; \
	exit $$status

lint:
	shellcheck -s sh $(INSTALLERS) action.sh tools/render.sh tests/*.sh
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
	rm -f $(addsuffix .sh.check,$(PRODUCTS))
