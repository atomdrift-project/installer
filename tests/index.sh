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
assert_page_contains 'On macOS and Linux it delegates to Homebrew when available'
assert_page_contains 'https://github.com/atomdrift-project/scan/releases/latest'
assert_page_contains 'SHA256SUMS'
assert_page_contains 'Pre-install check'
assert_page_contains 'doas'
assert_page_contains 'pfexec'
assert_page_contains 'sudo'

if grep -F 'atomdrift/tap' "$PAGE" >/dev/null; then
	fail 'installer page still uses the legacy tap namespace'
fi

for platform in macOS Linux FreeBSD OpenBSD NetBSD 'DragonFly BSD' Solaris illumos Android Windows; do
	assert_page_contains "$platform"
done

for distro in Fedora Debian Ubuntu openSUSE Alpine Wolfi openEuler; do
	assert_page_contains "$distro"
done

for unsupported in Haiku GhostBSD BlissOS GNU/Hurd; do
	if grep -F "$unsupported" "$PAGE" >/dev/null; then
		fail "installer page presents an experimental compatibility target: $unsupported"
	fi
done

printf 'ok - installer methods, supported platforms, and security behavior\n'
