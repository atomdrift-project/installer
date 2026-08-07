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

# Homebrew that is installed but not exported — a non-login `curl | sh` on an
# image-based system — is put back on PATH by brew_works. find_brew_prefix has
# to call it before reading the prefix: BREW_PREFIX is what stops the installer
# writing into Homebrew's own directories behind its back, so an empty prefix on
# a Homebrew machine is a silent hazard rather than a cosmetic gap.
#
# The mock refuses to report a prefix until the repair has run, so reading it in
# the wrong order yields no prefix at all — which is exactly the bug.
(
	repaired=0
	# shellcheck disable=SC2329 # Invoked indirectly through find_brew_prefix.
	brew_works() {
		repaired=1
	}
	# shellcheck disable=SC2329 # Invoked indirectly through find_brew_prefix.
	brew() {
		[ "${1:-}" = --prefix ] || return 1
		[ "$repaired" = 1 ] || return 1
		printf '%s\n' /opt/unexported-homebrew
	}
	BREW_PREFIX=""
	find_brew_prefix || fail 'an unexported Homebrew was not resolved to a prefix'
	[ "$BREW_PREFIX" = /opt/unexported-homebrew ] ||
		fail "prefix resolved to '$BREW_PREFIX' instead of the repaired one"
)
printf 'ok - the Homebrew prefix is read after the PATH repair, not before\n'

# auto_method reads HOST_OS, which detect_platform fills in on a real run.
OPT_DIR=
OPT_VERSION=
for HOST_OS in Darwin Linux; do
	[ "$(auto_method)" = brew ] || fail "auto mode did not select Homebrew on $HOST_OS"
done
HOST_OS=FreeBSD
[ "$(auto_method)" = binary ] || fail 'auto mode selected Homebrew on an unsupported OS'
HOST_OS=Linux
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
