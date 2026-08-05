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
[ "$(native_path_dirs SunOS)" = '/opt/atomdrift/bin' ] || fail 'Solaris/illumos native PATH order changed'
[ "$(native_path_dirs FreeBSD)" = '/usr/local/bin' ] || fail 'FreeBSD native PATH order changed'
[ "$(native_path_dirs NetBSD)" = '/usr/pkg/bin /usr/local/bin' ] || fail 'NetBSD native PATH order changed'
printf 'ok - OS-native install directory preferences\n'

# Keep generic PATH-selection cases deterministic on BSD/macOS runners too.
uname() { printf '%s\n' Linux; }

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

APPROVAL_COUNT=0
APPROVAL_COMMAND=""
approve_privilege() {
	APPROVAL_COUNT=$((APPROVAL_COUNT + 1))
	APPROVAL_COMMAND=$1
	PRIVILEGE_APPROVED=1
	return 0
}

# Force ordinary mkdir attempts to fail, then let the fake privilege commands
# execute the same command. The installer selects one mechanism, shows the exact
# command, and asks before running it.
privileged_fallback="$TMP/system-fallback/bin"
privileged_dir="$TMP/system-explicit/bin"
privileged_existing="$TMP/system-existing/bin"
command mkdir -p "$TMP/system-fallback" "$TMP/system-explicit" "$privileged_existing"
mkdir() {
	if [ "${1:-}" = -p ]; then
		case ${2:-} in
		"$privileged_fallback" | "$privileged_dir" | "$privileged_existing") return 1 ;;
		esac
	fi
	command mkdir "$@"
}

TEST_DOAS_FAIL=0
OPT_DIR=""
INSTALL_DIR=""
PATH="$privileged_fallback:/usr/bin:/bin"
resolve_install_dir
[ "$INSTALL_DIR" = "$privileged_fallback" ] || fail 'privileged fallback did not remain on PATH'
[ "$INSTALL_PRIVILEGED" = 1 ] || fail 'unwritable PATH fallback did not select escalation'
[ "$INSTALL_ESCALATOR" = doas ] || fail 'PATH fallback did not use preferred escalator'
[ "$APPROVAL_COMMAND" = "doas mkdir -p '$privileged_fallback'" ] || fail "approval hid the exact command: $APPROVAL_COMMAND"
[ "$APPROVAL_COUNT" = 1 ] || fail 'privilege approval was not requested exactly once'
printf 'ok - PATH fallback shows and approves the exact privileged command\n'

PRIVILEGE_APPROVED=0
APPROVAL_COUNT=0
APPROVAL_COMMAND=""
INSTALL_DIR=""
use_install_dir "$privileged_existing" ||
	fail 'existing protected directory was not selected'
[ "$INSTALL_PRIVILEGED" = 1 ] || fail 'existing protected directory did not retain escalation'
[ "$APPROVAL_COUNT" = 0 ] || fail 'read-only directory selection requested unused privilege'

existing_fixture="$TMP/atomscan-existing-fixture"
cat >"$existing_fixture" <<'EOF'
#!/bin/sh
printf '%s\n' 'atomscan 8.8.8'
EOF
chmod 755 "$existing_fixture"
install_binary_file "$existing_fixture"
[ "$APPROVAL_COUNT" = 1 ] || fail 'first protected write did not request approval'
case $APPROVAL_COMMAND in
"doas cp '$existing_fixture' "*" && doas chmod 755 "*" && doas mv -f "*" '$privileged_existing/atomscan'") : ;;
*) fail "protected write did not show its exact operations: $APPROVAL_COMMAND" ;;
esac
printf 'ok - protected existing directory defers approval until the first write\n'

TEST_DOAS_FAIL=0
OPT_DIR=$privileged_dir
INSTALL_DIR=""
PRIVILEGE_APPROVED=0
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

# A legacy /usr/bin install must not pin upgrades there on non-Linux systems.
# Mock directory preparation so this checks policy without touching host paths.
check_legacy_migration() (
	clm_os=$1 clm_expected=$2
	uname() { printf '%s\n' "$clm_os"; }
	current_install() { printf '%s\n' /usr/bin/atomscan; }
	writable_dir() { return 0; }
	use_install_dir() { INSTALL_DIR=$1; return 0; }
	HOME=""
	OPT_DIR=""
	BREW_PREFIX=""
	INSTALL_DIR=""
	resolve_install_dir
	[ "$INSTALL_DIR" = "$clm_expected" ] ||
		fail "$clm_os retained /usr/bin instead of selecting $clm_expected"
)
check_legacy_migration SunOS /opt/atomdrift/bin
check_legacy_migration FreeBSD /usr/local/bin
printf 'ok - non-Linux upgrades migrate away from legacy /usr/bin installs\n'

PATH=$original_path
