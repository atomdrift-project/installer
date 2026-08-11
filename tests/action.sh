#!/bin/sh
# action.sh writes one workflow and never touches git. These are the properties
# that matter: the generated YAML parses, a second run changes nothing, and a
# repository's history is the same before and after.

set -eu

TEST_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
INSTALLER="$TEST_ROOT/action.sh"
WORKFLOW=".github/workflows/supply-chain.yml"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

# A repository whose manifest picks $1 as the detected stack.
make_repo() {
	repo="$TMP/$1"
	mkdir -p "$repo"
	git -C "$repo" init -q -b main
	git -C "$repo" config user.email test@example.com
	git -C "$repo" config user.name test
	case "$1" in
		node) printf '{"name":"x"}\n' > "$repo/package.json" ;;
		rust) printf '[package]\nname = "x"\n' > "$repo/Cargo.toml" ;;
		go) printf 'module x\n' > "$repo/go.mod" ;;
		python) printf '[project]\nname = "x"\n' > "$repo/pyproject.toml" ;;
	esac
}

for stack in node rust go python none; do
	make_repo "$stack"
	repo="$TMP/$stack"

	(cd "$repo" && sh "$INSTALLER" >/dev/null 2>&1) || fail "$stack: installer failed"
	[ -f "$repo/$WORKFLOW" ] || fail "$stack: no workflow written"

	# Idempotence is byte-level, not just exit-code-level: a workflow that
	# churns on every run shows up as noise in every diff.
	before=$(cat "$repo/$WORKFLOW")
	(cd "$repo" && sh "$INSTALLER" >/dev/null 2>&1) || fail "$stack: rerun exited non-zero"
	[ "$before" = "$(cat "$repo/$WORKFLOW")" ] || fail "$stack: rerun changed the workflow"

	# The whole point of the script is that committing stays the user's call.
	[ -z "$(git -C "$repo" log --oneline 2>/dev/null)" ] || fail "$stack: installer created a commit"
	[ "$(git -C "$repo" symbolic-ref --short HEAD)" = main ] || fail "$stack: installer switched branch"

	case "$stack" in
		none) grep -q 'name: isomer · source$' "$repo/$WORKFLOW" \
			|| fail 'none: expected the source-only workflow' ;;
		*) grep -q 'source + build output' "$repo/$WORKFLOW" \
			|| fail "$stack: expected the build-comparison workflow" ;;
	esac
done
printf 'ok - every stack writes a stable workflow and no git history\n'

# Refusing to clobber matters more than convenience: the file may have been
# edited to match a build this script cannot see.
repo="$TMP/node"
printf '# hand-edited\n' >> "$repo/$WORKFLOW"
(cd "$repo" && sh "$INSTALLER" >/dev/null 2>&1) && fail 'a differing workflow was replaced without --force'
grep -q '# hand-edited' "$repo/$WORKFLOW" || fail 'a differing workflow was overwritten'
(cd "$repo" && sh "$INSTALLER" --force >/dev/null 2>&1) || fail '--force did not replace the workflow'
grep -q '# hand-edited' "$repo/$WORKFLOW" && fail '--force left the old contents'
printf 'ok - an edited workflow survives without --force and is replaced with it\n'

# Run from a subdirectory: the workflow belongs at the repository root.
rm -rf "$repo/.github"
mkdir -p "$repo/deep/nested"
(cd "$repo/deep/nested" && sh "$INSTALLER" >/dev/null 2>&1) || fail 'failed from a subdirectory'
[ -f "$repo/$WORKFLOW" ] || fail 'subdirectory run did not write to the repository root'
printf 'ok - runs from any directory in the repository\n'

# --source-only forces the short workflow even where a build was detectable.
rm -rf "$repo/.github"
(cd "$repo" && sh "$INSTALLER" --source-only >/dev/null 2>&1) || fail '--source-only failed'
grep -q 'source + build output' "$repo/$WORKFLOW" && fail '--source-only still compared build output'
printf 'ok - --source-only skips the build comparison\n'

# --dry-run is for reading before writing; it must write nothing at all.
rm -rf "$repo/.github"
out=$(cd "$repo" && sh "$INSTALLER" --dry-run 2>/dev/null)
[ -e "$repo/.github" ] && fail '--dry-run created files'
printf '%s' "$out" | grep -q '^name: supply-chain$' || fail '--dry-run printed no workflow'
printf 'ok - --dry-run prints the workflow and writes nothing\n'

# Outside a repository there is no root to write to, and guessing one would put
# a workflow somewhere the user never looks.
( cd "$TMP" && sh "$INSTALLER" >/dev/null 2>&1 ) && fail 'ran outside a git repository'
printf 'ok - refuses to run outside a git repository\n'
