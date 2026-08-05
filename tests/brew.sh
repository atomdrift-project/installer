#!/bin/sh
# The canonical GitHub tap namespace must support Homebrew's one-command direct
# install. Mock Homebrew so this verifies orchestration without touching the
# developer or CI runner's package database.

set -eu

TEST_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
ATOMSCAN_INSTALLER_TESTING=1
export ATOMSCAN_INSTALLER_TESTING
# shellcheck disable=SC1090 # TEST_ROOT is resolved immediately above.
. "$TEST_ROOT/scan.sh"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/atomscan-brew-test.XXXXXX")
trap 'rm -rf "$test_tmp"' 0
test_prefix="$test_tmp/prefix"
test_log="$test_tmp/brew.log"
mkdir -p "$test_prefix/bin"

brew() {
	printf '%s\n' "$*" >>"$test_log"
	case ${1:-} in
	--version) printf '%s\n' 'Homebrew 6.0.0' ;;
	--prefix) printf '%s\n' "$test_prefix" ;;
	list) return 1 ;;
	install)
		[ "${2:-}" = --formula ] || return 1
		[ "${3:-}" = atomdrift-project/tap/scan ] || return 1
		printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'atomscan 9.9.9'" >"$test_prefix/bin/$BIN"
		chmod 755 "$test_prefix/bin/$BIN"
		;;
	*) return 1 ;;
	esac
}

setup_style
OPT_QUIET=1
[ "$TAP" = atomdrift-project/tap ] || fail "unexpected tap namespace: $TAP"
install_brew || fail 'mock Homebrew installation failed'
[ "$INSTALLED" = "$test_prefix/bin/$BIN" ] || fail "unexpected install path: $INSTALLED"
grep -F 'install --formula atomdrift-project/tap/scan' "$test_log" >/dev/null || fail 'canonical formula was not installed'
if grep -F 'tap ' "$test_log" >/dev/null; then
	fail 'installer issued a redundant brew tap command'
fi

printf 'ok - Homebrew uses the canonical one-command tap namespace\n'
