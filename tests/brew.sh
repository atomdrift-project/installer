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
	help) [ "${2:-}" = trust ] ;;
	trust)
		[ "${2:-}" = --formula ] || return 1
		[ "${3:-}" = atomdrift-project/tap/scan ] || return 1
		[ "${4:-}" = atomdrift-project/tap/cleave ] || return 1
		;;
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

uname() {
	printf '%s\n' "$test_os"
}

OPT_DIR=
OPT_VERSION=
for test_os in Darwin Linux; do
	[ "$(auto_method)" = brew ] || fail "auto mode did not select Homebrew on $test_os"
done
test_os=FreeBSD
[ "$(auto_method)" = binary ] || fail 'auto mode selected Homebrew on an unsupported OS'
test_os=Linux
OPT_DIR="$test_tmp/custom-bin"
[ "$(auto_method)" = binary ] || fail 'a custom directory did not bypass Homebrew on Linux'
OPT_DIR=
OPT_VERSION=9.9.9
[ "$(auto_method)" = binary ] || fail 'a pinned version did not bypass Homebrew on Linux'
OPT_VERSION=

install_brew || fail 'mock Homebrew installation failed'
[ "$INSTALLED" = "$test_prefix/bin/$BIN" ] || fail "unexpected install path: $INSTALLED"
trust_line=$(grep -n -F 'trust --formula atomdrift-project/tap/scan atomdrift-project/tap/cleave' "$test_log" | sed -n '1s/:.*//p')
install_line=$(grep -n -F 'install --formula atomdrift-project/tap/scan' "$test_log" | sed -n '1s/:.*//p')
[ -n "$trust_line" ] || fail 'scan and cleave were not trusted individually'
[ -n "$install_line" ] || fail 'canonical formula was not installed'
[ "$trust_line" -lt "$install_line" ] || fail 'formula trust was granted after installation started'
if grep -F 'tap ' "$test_log" >/dev/null; then
	fail 'installer issued a redundant brew tap command'
fi

printf 'ok - Homebrew auto-selection and canonical tap namespace\n'
