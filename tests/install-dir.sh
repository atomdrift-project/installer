#!/bin/sh
# Default installs must prefer a user-owned directory already named in PATH,
# then fall back to an OS-appropriate PATH directory. Privilege commands are
# shell-function fakes here: CI never actually elevates.

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
trap 'exit 130' INT
trap 'exit 143' HUP TERM
test_home="$TMP/home"
mkdir -p "$test_home"
original_path=$PATH

# Make the selection behave as an ordinary account even when a container runs
# its test steps as root.
id() { printf '1000\n'; }
current_install() { return 1; }

[ "$(native_path_dirs Linux)" = '/usr/local/bin' ] || fail 'Linux native PATH order changed'
[ "$(native_path_dirs Haiku)" = '/boot/system/non-packaged/bin /usr/local/bin' ] || fail 'Haiku native PATH order changed'
[ "$(native_path_dirs SunOS)" = '/opt/local/bin /usr/local/bin' ] || fail 'Solaris/illumos native PATH order changed'
[ "$(native_path_dirs NetBSD)" = '/usr/local/bin /usr/pkg/bin' ] || fail 'NetBSD native PATH order changed'
printf 'ok - OS-native install directory preferences\n'

HOME=$test_home
OPT_DIR=""
BREW_PREFIX=""
PATH="$HOME/bin:$original_path"
resolve_install_dir
[ "$INSTALL_DIR" = "$HOME/bin" ] || fail "selected $INSTALL_DIR instead of existing PATH entry $HOME/bin"
[ -d "$HOME/bin" ] || fail 'did not create ~/bin'
printf 'ok - creates and selects ~/bin when it is on PATH\n'

INSTALL_DIR=""
PATH="$HOME/.local/bin:$HOME/bin:$original_path"
resolve_install_dir
[ "$INSTALL_DIR" = "$HOME/.local/bin" ] || fail "selected $INSTALL_DIR instead of $HOME/.local/bin"
[ -d "$HOME/.local/bin" ] || fail 'did not create ~/.local/bin'
printf 'ok - prefers ~/.local/bin when it is on PATH\n'

INSTALL_DIR=""
path_fallback="$TMP/path-bin"
mkdir -p "$path_fallback"
PATH="$path_fallback:/usr/bin:/bin"
resolve_install_dir
[ "$INSTALL_DIR" = "$path_fallback" ] || fail "PATH fallback selected $INSTALL_DIR instead of $path_fallback"
on_path "$INSTALL_DIR" || fail 'fallback directory is not on PATH'
printf 'ok - falls back to a writable directory already on PATH\n'

TEST_DOAS_FAIL=0
doas() {
	[ "$TEST_DOAS_FAIL" = 0 ] || return 1
	command "$@"
}
pfexec() { command "$@"; }
sudo() { command "$@"; }
find_escalator || fail 'found no mock privilege tool'
[ "$INSTALL_ESCALATOR" = doas ] || fail "selected $INSTALL_ESCALATOR instead of doas"
printf 'ok - escalation preference is doas, pfexec, sudo\n'

# Force ordinary mkdir attempts to fail, then let the fake privilege commands
# execute the same command. First prove a failed doas falls through to pfexec
# for an automatic PATH choice.
privileged_fallback="$TMP/system-fallback/bin"
privileged_dir="$TMP/system-explicit/bin"
command mkdir -p "$TMP/system-fallback" "$TMP/system-explicit"
mkdir() {
	if [ "${1:-}" = -p ]; then
		case ${2:-} in
		"$privileged_fallback" | "$privileged_dir") return 1 ;;
		esac
	fi
	command mkdir "$@"
}

TEST_DOAS_FAIL=1
OPT_DIR=""
INSTALL_DIR=""
PATH="$privileged_fallback:/usr/bin:/bin"
resolve_install_dir
[ "$INSTALL_DIR" = "$privileged_fallback" ] || fail 'privileged fallback did not remain on PATH'
[ "$INSTALL_PRIVILEGED" = 1 ] || fail 'unwritable PATH fallback did not select escalation'
[ "$INSTALL_ESCALATOR" = pfexec ] || fail 'failed doas did not fall through to pfexec'
printf 'ok - PATH fallback escalates through doas, pfexec, then sudo\n'

TEST_DOAS_FAIL=0
OPT_DIR=$privileged_dir
INSTALL_DIR=""
resolve_install_dir
[ "$INSTALL_PRIVILEGED" = 1 ] || fail 'explicit unwritable --dir did not select escalation'
[ "$INSTALL_ESCALATOR" = doas ] || fail 'explicit --dir did not use doas'

fixture="$TMP/atomscan-fixture"
cat >"$fixture" <<'EOF'
#!/bin/sh
printf '%s\n' 'atomscan 9.9.9'
EOF
chmod 755 "$fixture"
install_binary_file "$fixture"
[ "$(installed_version "$INSTALLED")" = 9.9.9 ] || fail 'escalated atomic install failed'
printf 'ok - explicit --dir uses the escalation adapter\n'

PATH=$original_path
