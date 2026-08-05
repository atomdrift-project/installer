#!/bin/sh
# Optional analysis tools are installed only when the active repositories know
# about them. Solaris IPS must never be mistaken for FreeBSD pkg(8).

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

setup_style
make_tmpdir
trap cleanup 0

fake_bin="$TMP/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/pkg" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$fake_bin/pkg"

# Solaris/illumos pkg is IPS. Its presence alone must not produce a FreeBSD
# install command; pkgsrc's pkgin may still be detected later in the loop.
# shellcheck disable=SC2030,SC2031 # PATH changes are intentionally subshell-local.
(
	PATH=$fake_bin
	uname() { printf '%s\n' SunOS; }
	PM="" PM_INSTALL=""
	if detect_pkg_manager; then
		fail "Solaris IPS pkg was detected as $PM"
	fi
)
printf 'ok - Solaris IPS is not mistaken for FreeBSD pkg\n'

# shellcheck disable=SC2030,SC2031 # PATH changes are intentionally subshell-local.
(
	PATH=$fake_bin
	uname() { printf '%s\n' FreeBSD; }
	PM="" PM_INSTALL=""
	detect_pkg_manager || fail 'FreeBSD pkg was not detected'
	[ "$PM" = pkg ] || fail "FreeBSD selected $PM instead of pkg"
)
printf 'ok - FreeBSD pkg is detected on FreeBSD\n'

cat >"$fake_bin/apt-cache" <<'EOF'
#!/bin/sh
[ "${1:-}" = show ] || exit 1
case ${2:-} in
upx-ucl | p7zip-full) exit 0 ;;
*) exit 1 ;;
esac
EOF
cat >"$fake_bin/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TOOL_INSTALL_LOG"
EOF
chmod 755 "$fake_bin/apt-cache" "$fake_bin/apt-get"

# shellcheck disable=SC2031 # The prior PATH assignments were subshell-local.
original_path=$PATH
PATH=$fake_bin
TOOL_INSTALL_LOG="$TMP/install.log"
export TOOL_INSTALL_LOG
BREW_PREFIX=""
INSTALL_ESCALATOR=""
PRIVILEGE_APPROVED=0
PRIVILEGE_DENIED=0
APPROVAL_COMMAND=""

uname() { printf '%s\n' Linux; }
id() { printf '%s\n' 1000; }
doas() { command "$@"; }
have_tool() { return 1; }
approve_privilege() {
	APPROVAL_COMMAND=$1
	PRIVILEGE_APPROVED=1
	return 0
}

check_tools >"$TMP/output"
PATH=$original_path

[ "$(cat "$TOOL_INSTALL_LOG")" = 'install -y upx-ucl p7zip-full' ] ||
	fail 'installer did not limit apt packages to repository matches'
[ "$APPROVAL_COMMAND" = 'doas apt-get install -y upx-ucl p7zip-full' ] ||
	fail "approval did not show the exact package command: $APPROVAL_COMMAND"
grep -q 'not available from configured repositories: rizin innoextract' "$TMP/output" ||
	fail 'unavailable repository packages were not reported accurately'
if grep -q -- '-rizin\|-upx\|-7z\|-innoextract' "$TMP/output"; then
	fail 'tool output regressed to the negative +/- status row'
fi
printf 'ok - only available packages are approved and installed\n'
