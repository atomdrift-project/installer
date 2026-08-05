#!/bin/sh
# Exercise repair and reuse of the source checkout without network access or a
# real Rust build.

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

fixture_root=$(mktemp -d 2>/dev/null || :)
if [ -z "$fixture_root" ]; then
	fixture_root="${TMPDIR:-/tmp}/atomscan-source-cache.$$"
	(umask 077 && mkdir "$fixture_root") || fail 'cannot create fixture directory'
fi

CLONES=0
FETCHES=0
CHECKOUTS=0
MOCK_CLONE_FAIL=0
MOCK_FETCH_FAIL=0
MOCK_ORIGIN='https://github.com/atomdrift-project/scan.git'
MOCK_PROMOTE_FAIL=0
MOCK_RUST_VERSION=1.94.0

git() {
	case $1 in
	clone)
		CLONES=$((CLONES + 1))
		for mock_arg do mock_dest=$mock_arg; done
		if [ "$MOCK_CLONE_FAIL" = 1 ]; then
			mkdir -p "$mock_dest"
			printf '%s\n' partial >"$mock_dest/partial"
			return 1
		fi
		mkdir -p "$mock_dest/.git"
		;;
	-C)
		case $3 in
		remote) printf '%s\n' "$MOCK_ORIGIN" ;;
		fetch)
			FETCHES=$((FETCHES + 1))
			[ "$MOCK_FETCH_FAIL" = 0 ]
			;;
		checkout) CHECKOUTS=$((CHECKOUTS + 1)) ;;
		*) fail "unexpected mocked git operation: $3" ;;
		esac
		;;
	*) fail "unexpected mocked git invocation: $*" ;;
	esac
}

mv() {
	case ${1:-}:${2:-} in
	"$source_dir".clone.*:"$source_dir")
		if [ "$MOCK_PROMOTE_FAIL" = 1 ]; then
			MOCK_PROMOTE_FAIL=0
			return 1
		fi
		;;
	esac
	command mv "$@"
}

staged_checkout_exists() {
	for staged_path in "$source_dir".clone.*; do
		[ -e "$staged_path" ] && return 0
	done
	return 1
}

cargo() {
	mkdir -p target/release
	cat >target/release/atomscan <<'EOF'
#!/bin/sh
printf '%s\n' 'atomscan 2.5.0'
EOF
	chmod 755 target/release/atomscan
}

rustc() { printf 'rustc %s (test toolchain)\n' "$MOCK_RUST_VERSION"; }

uname() { printf '%s\n' FreeBSD; }
installed_version() {
	if [ -n "${MOCK_CURRENT:-}" ] && [ "$1" = "$MOCK_CURRENT" ]; then
		printf '%s' 2.5.0
		return 0
	fi
	return 1
}
install_binary_file() { INSTALLED=$1; }

setup_style
OPT_VERSION=2.5.0
OPT_FORCE=1
OPT_QUIET=1
HOME="$fixture_root/home"
XDG_CACHE_HOME="$fixture_root/cache"
INSTALL_DIR="$fixture_root/bin"
export HOME XDG_CACHE_HOME

source_dir="$XDG_CACHE_HOME/atomdrift/scan"
destination_marker="$fixture_root/destination-prepared"
MOCK_CURRENT=""
current_install() {
	[ -n "$MOCK_CURRENT" ] || return 1
	printf '%s\n' "$MOCK_CURRENT"
}
resolve_install_dir() {
	: >"$destination_marker"
	INSTALL_DIR="$fixture_root/bin"
}

# A protected/current PATH install is already a successful source outcome. It
# must not require the build toolchain or create a second, shadowed copy.
current_dir="$fixture_root/current/bin"
mkdir -p "$current_dir"
cat >"$current_dir/atomscan" <<'EOF'
#!/bin/sh
printf '%s\n' 'atomscan 2.5.0'
EOF
chmod 755 "$current_dir/atomscan"
MOCK_CURRENT="$current_dir/atomscan"
MOCK_RUST_VERSION=1.93.9
OPT_FORCE=0
INSTALL_DIR=""
install_source
[ "$INSTALLED" = "$MOCK_CURRENT" ] || fail 'current PATH install was replaced by a shadowing copy'
[ "$ALREADY_CURRENT" = 1 ] || fail 'current PATH install was not recognized as idempotent'
[ ! -e "$destination_marker" ] || fail 'current PATH install prepared another destination'
[ ! -e "$source_dir" ] || fail 'current PATH install touched the source cache'

MOCK_CURRENT=""
INSTALLED=""
ALREADY_CURRENT=0
VERSION=""
OPT_FORCE=1

# Reject an old compiler before resolving a release, preparing a destination,
# requesting privilege, or touching the cache.
MOCK_RUST_VERSION=1.93.9
INSTALL_DIR=""
old_rust_log="$fixture_root/old-rust.log"
if (install_source >"$old_rust_log" 2>&1); then
	fail 'source install accepted Rust older than its MSRV'
fi
old_rust_output=$(sed -n '1,20p' "$old_rust_log")
case $old_rust_output in
*'Rust 1.94 or newer (found 1.93.9)'*'then re-run this installer'*) : ;;
*) fail 'old-Rust error did not report the requirement and recovery action' ;;
esac
[ ! -e "$source_dir" ] || fail 'old Rust toolchain touched the source cache'
[ ! -e "$destination_marker" ] || fail 'old Rust toolchain prepared an install destination'
MOCK_RUST_VERSION=1.94.0
INSTALL_DIR="$fixture_root/bin"

# Even the initial clone is staged, so interruption leaves no poisoned cache.
MOCK_CLONE_FAIL=1
if (install_source 2>/dev/null); then
	fail 'failed initial source clone unexpectedly succeeded'
fi
[ ! -e "$source_dir" ] || fail 'failed initial clone created the canonical cache path'
if staged_checkout_exists; then fail 'failed initial clone left its staging directory'; fi

mkdir -p "$source_dir"
printf '%s\n' keep-me >"$source_dir/interrupted"

# A failed repair must preserve the old cache and remove its partial clone.
MOCK_CLONE_FAIL=1
if (install_source 2>/dev/null); then
	fail 'failed source clone unexpectedly succeeded'
fi
[ -f "$source_dir/interrupted" ] || fail 'failed repair damaged the existing cache'
if staged_checkout_exists; then fail 'failed repair left a partial staged clone'; fi

# A retry replaces the incomplete cache, then a later run updates that checkout.
MOCK_CLONE_FAIL=0
install_source
[ -d "$source_dir/.git" ] || fail 'retry did not install a valid source checkout'
[ ! -e "$source_dir/interrupted" ] || fail 'retry retained the incomplete cache contents'
if staged_checkout_exists; then fail 'retry left source-cache staging debris'; fi
[ "$CLONES" = 1 ] || fail "retry cloned $CLONES times, expected once"

install_source
[ "$CLONES" = 1 ] || fail 'valid checkout was cloned again instead of updated'
[ "$FETCHES" = 1 ] || fail 'valid checkout was not fetched on the next run'
[ "$CHECKOUTS" = 1 ] || fail 'fetched checkout was not selected on the next run'

# A valid-looking checkout with the wrong origin must be replaced, never built.
MOCK_ORIGIN='https://example.invalid/not-atomdrift.git'
printf '%s\n' keep-on-rollback >"$source_dir/before-promotion"
MOCK_PROMOTE_FAIL=1
if (install_source 2>/dev/null); then
	fail 'failed cache promotion unexpectedly succeeded'
fi
[ -f "$source_dir/before-promotion" ] || fail 'failed promotion did not restore the previous checkout'
if staged_checkout_exists; then fail 'failed promotion left source-cache staging debris'; fi

MOCK_PROMOTE_FAIL=0
install_source 2>/dev/null
[ "$CLONES" = 2 ] || fail 'wrong-origin checkout was not replaced'

# A corrupt checkout that cannot fetch is also self-healing.
MOCK_ORIGIN='https://github.com/atomdrift-project/scan.git'
MOCK_FETCH_FAIL=1
install_source 2>/dev/null
[ "$CLONES" = 3 ] || fail 'unusable Git checkout was not replaced'

# Never silently build an unreleased main branch when release resolution fails.
OPT_VERSION=""
VERSION=""
DOWNLOADER=fixture
resolve_latest() { return 1; }
if (install_source 2>/dev/null); then
	fail 'source install built main after release resolution failed'
fi

printf 'ok - source cache clones safely, repairs corruption, and is reusable\n'
rm -rf "$fixture_root"
