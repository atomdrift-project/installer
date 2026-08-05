#!/bin/sh
# GitHub resolves actions before any job steps run, so a truncated pin prevents
# the workflow from reaching actionlint or the installer tests. Enforce complete
# commit-object pins locally and again once checkout succeeds in CI.

set -eu

TEST_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
WORKFLOW="$TEST_ROOT/.github/workflows/installer.yml"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

refs=$(sed -n 's/.*uses: [^@]*@\([0-9a-f][0-9a-f]*\).*/\1/p' "$WORKFLOW")
[ -n "$refs" ] || fail 'workflow contains no pinned external actions'

for ref in $refs; do
	case $ref in
	*[!0-9a-f]*) fail "action reference is not hexadecimal: $ref" ;;
	esac
	[ "${#ref}" = 40 ] || fail "action reference is not a full commit SHA: $ref"
done

printf 'ok - all external actions use full commit SHA pins\n'
