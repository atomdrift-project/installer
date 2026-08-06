#!/bin/sh
# Run scan.sh end to end using a local release fixture. Network functions are
# replaced only after sourcing the installer in test mode; production code has
# no alternate release host or verification bypass.

set -eu

if [ $# -ne 1 ]; then
	printf 'usage: %s EXPECTED_TARGET\n' "$0" >&2
	exit 2
fi
EXPECTED_TARGET=$1

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
	fixture_root="${TMPDIR:-/tmp}/atomscan-integration.$$"
	(umask 077 && mkdir "$fixture_root") || fail 'cannot create fixture directory'
fi
fixture_payload="$fixture_root/payload"
fixture_home="$fixture_root/home"
fixture_install="$fixture_home/bin"
mkdir -p "$fixture_payload" "$fixture_home"

cat >"$fixture_payload/atomscan" <<'EOF'
#!/bin/sh
printf '%s\n' 'atomscan 9.9.9'
EOF
chmod 755 "$fixture_payload/atomscan"

fixture_name="atomscan-9.9.9-$EXPECTED_TARGET.tar.gz"
fixture_archive="$fixture_root/$fixture_name"
(cd "$fixture_payload" && tar -cf - atomscan) | gzip >"$fixture_archive"
fixture_digest=$(sha256_of "$fixture_archive")
[ -n "$fixture_digest" ] || fail 'no supported SHA-256 implementation found'

find_downloader() { DOWNLOADER=fixture; }
http_ok() { return 0; }
verify_provenance() { return 1; }
cosign() { return 0; }
verify_sigstore_manifest() {
	printf '%s\n' 'https://github.com/atomdrift-project/scan/.github/workflows/release.yml@refs/tags/v9.9.9'
}
id() { printf '1000\n'; }
current_install() { return 1; }
http_get() {
	case $1 in
	*/SHA256SUMS)
		printf '%s  %s\n' "$fixture_digest" "$fixture_name" >"$2"
		;;
	*/SHA256SUMS.sigstore.json)
		printf '%s\n' '{}' >"$2"
		;;
	*/"$fixture_name")
		cp "$fixture_archive" "$2"
		;;
	*)
		printf 'unexpected fixture URL: %s\n' "$1" >&2
		return 1
		;;
	esac
}

HOME=$fixture_home
PATH="$fixture_install:$PATH"
export HOME PATH
main --method binary --version 9.9.9 --no-tools --quiet

[ "$SELF" = "$EXPECTED_TARGET" ] || fail "detected $SELF, expected $EXPECTED_TARGET"
[ "$TARGET" = "$EXPECTED_TARGET" ] || fail "$EXPECTED_TARGET is not release-backed"
[ "$INSTALLED" = "$fixture_install/atomscan" ] || fail "installed at unexpected path $INSTALLED"
[ -d "$fixture_install" ] || fail 'installer did not create the user bin directory already on PATH'
[ "$(installed_version "$INSTALLED")" = 9.9.9 ] || fail 'installed fixture does not run'
printf 'ok - end-to-end binary install -> %s\n' "$INSTALLED"

rm -rf "$fixture_root"
