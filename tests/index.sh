#!/bin/sh
# Keep the human-facing installer page aligned with the actual entry points,
# supported operating systems, and security-relevant installer behavior.

set -eu

TEST_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
PAGE="$TEST_ROOT/index.html"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

assert_page_contains() {
	grep -F "$1" "$PAGE" >/dev/null || fail "installer page is missing: $1"
}

[ -s "$PAGE" ] || fail 'index.html is missing or empty'

assert_page_contains 'curl -fsSL https://install.atomdrift.org/scan.sh | sh'
assert_page_contains 'irm https://install.atomdrift.org/scan.ps1 | iex'
assert_page_contains 'Uses Homebrew when available'
assert_page_contains 'https://github.com/atomdrift-project/scan/releases/latest'
assert_page_contains 'SHA256SUMS'
assert_page_contains 'before replacing anything'
assert_page_contains 'class="terminal terminal-windows"'
assert_page_contains 'class="window-controls"'
assert_page_contains 'Windows PowerShell'

if grep -F 'atomdrift/tap' "$PAGE" >/dev/null; then
	fail 'installer page still uses the legacy tap namespace'
fi

for platform in macOS Linux BSD Solaris illumos Android Windows; do
	assert_page_contains "$platform"
done

for unsupported in Haiku GhostBSD BlissOS GNU/Hurd; do
	if grep -F "$unsupported" "$PAGE" >/dev/null; then
		fail "installer page presents an experimental compatibility target: $unsupported"
	fi
done

printf 'ok - concise installer page, supported platforms, and security behavior\n'
