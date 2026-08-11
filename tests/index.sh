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
assert_page_contains "The open-source malware scanner that doesn’t suck."
assert_page_contains 'files, directories, archives, packages, URLs, and running processes'
assert_page_contains 'No cloud scanner, API key, GPU, or sample upload required.'
assert_page_contains 'Uses Homebrew when available'
assert_page_contains 'https://github.com/atomdrift-project/scan/releases/latest'
assert_page_contains 'SHA256SUMS'
assert_page_contains 'before replacing anything'
assert_page_contains 'class="terminal terminal-windows"'
assert_page_contains 'class="window-controls"'
assert_page_contains 'class="command-target"'
assert_page_contains 'x86-64 · ARM64 · ARMv6/ARMv7 hard-float · LoongArch64 · s390x · RISC-V 64 · POWER64LE'

# The GitHub Action installer: its entry point, the one file it writes, and the
# stacks it claims to detect all have to match action.sh.
assert_page_contains 'curl -fsSL https://install.atomdrift.org/action.sh | sh'
assert_page_contains '.github/workflows/supply-chain.yml'
assert_page_contains 'https://github.com/atomdrift-project/isomer-action'
assert_page_contains 'Node · Rust · Go · Python'
for option in --source-only --dry-run --force; do
	assert_page_contains "<dt>$option</dt>"
done

# isomer is an early build. The page has to say so where the command is, not
# leave a reader to find out from the action's README.
grep -F 'class="badge">experimental<' "$PAGE" >/dev/null \
	|| fail 'installer page no longer labels the GitHub Action as experimental'

if grep -F 'Linux binaries:' "$PAGE" >/dev/null; then
	fail 'installer page still labels the shared architecture list as Linux-only'
fi

if grep -F 'atomdrift/tap' "$PAGE" >/dev/null; then
	fail 'installer page still uses the legacy tap namespace'
fi

for platform in macOS Linux BSD Solaris illumos Android Windows; do
	assert_page_contains "$platform"
done

for unsupported in DragonFly Haiku GhostBSD BlissOS GNU/Hurd; do
	if grep -F "$unsupported" "$PAGE" >/dev/null; then
		fail "installer page presents an experimental compatibility target: $unsupported"
	fi
done

printf 'ok - concise installer page, supported platforms, and security behavior\n'
