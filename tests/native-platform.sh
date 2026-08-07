#!/bin/sh
# Native smoke test for one POSIX target. This deliberately avoids the network:
# it exercises the platform probe, checksum implementation, executable smoke
# test, and same-directory atomic replacement using a tiny fixture binary.

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

setup_style
detect_platform
[ "$SELF" = "$EXPECTED_TARGET" ] || fail "detected $SELF, expected $EXPECTED_TARGET"
[ "$TARGET" = "$EXPECTED_TARGET" ] || fail "$EXPECTED_TARGET is not release-backed"
printf 'ok - native platform -> %s\n' "$SELF"

make_tmpdir
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' HUP TERM
INSTALL_DIR="$TMP/bin"
mkdir -p "$INSTALL_DIR"

write_fixture() {
	wf_path=$1 wf_version=$2
	cat >"$wf_path" <<EOF
#!/bin/sh
printf '%s\\n' 'atomscan $wf_version'
EOF
	chmod 755 "$wf_path"
}

fixture_one="$TMP/atomscan-one"
fixture_two="$TMP/atomscan-two"
write_fixture "$fixture_one" 9.9.9
write_fixture "$fixture_two" 9.9.10

digest=$(sha256_of "$fixture_one")
[ -n "$digest" ] || fail 'no supported SHA-256 implementation found'
printf '%s  %s\n' "$digest" atomscan-fixture >"$TMP/SHA256SUMS"
verified=$(verify_checksum "$fixture_one" "$TMP/SHA256SUMS" atomscan-fixture)
[ "$verified" = "$(printf '%s' "$digest" | cut -c1-12)" ] || fail 'checksum verification failed'
printf 'ok - native SHA-256 verification\n'

cosign() {
	case " $* " in
	*' --certificate-identity https://github.com/atomdrift-project/scan/.github/workflows/release.yml@refs/tags/v9.9.9 '*) return 0 ;;
	*) return 1 ;;
	esac
}
sigstore_identity=$(verify_sigstore_manifest \
	"$TMP/SHA256SUMS" "$TMP/SHA256SUMS.sigstore.json" 9.9.9)
[ "$sigstore_identity" = 'https://github.com/atomdrift-project/scan/.github/workflows/release.yml@refs/tags/v9.9.9' ] ||
	fail 'Sigstore verification did not enforce the release workflow identity'
cosign() { return 1; }
if verify_sigstore_manifest "$TMP/SHA256SUMS" "$TMP/SHA256SUMS.sigstore.json" 9.9.9 >/dev/null; then
	fail 'invalid Sigstore bundle unexpectedly verified'
fi
printf 'ok - Sigstore identity verification\n'

install_binary_file "$fixture_one"
[ "$(installed_version "$INSTALLED")" = 9.9.9 ] || fail 'initial atomic install failed'
install_binary_file "$fixture_two"
[ "$(installed_version "$INSTALLED")" = 9.9.10 ] || fail 'atomic replacement failed'
printf 'ok - native install and replacement\n'

# Failure after staging must leave the installed binary intact and no hidden
# partial file behind for later runs to trip over.
if (
	trap - 0
	# shellcheck disable=SC2329 # Invoked indirectly through install_run.
	chmod() { return 1; }
	install_binary_file "$fixture_one" 2>/dev/null
); then
	fail 'staging failure unexpectedly installed a binary'
fi
[ "$(installed_version "$INSTALLED")" = 9.9.10 ] || fail 'staging failure damaged the installed binary'
[ ! -e "$INSTALL_DIR/.$BIN.new.$$" ] || fail 'staging failure left a partial binary'
printf 'ok - failed binary staging rolls back cleanly\n'
