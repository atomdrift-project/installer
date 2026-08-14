#!/bin/sh
# The installers are generated, so the properties worth testing are the ones
# that survive generation: each product renders, renders the same way twice,
# matches what is checked in, and produces a script this shell can actually run.
#
# The behavioral suite drives scan.sh, which comes from the same template as the
# rest — this covers what differs between products, not what they share.

set -eu

TEST_ROOT=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/atomdrift-generated.XXXXXX")
trap 'rm -rf "$TMP"' 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

products=""
for conf in "$TEST_ROOT"/products/*.conf; do
	products="$products $(basename "$conf" .conf)"
done
[ -n "$products" ] || fail 'no product configurations found'

for product in $products; do
	installer="$TEST_ROOT/$product.sh"
	[ -f "$installer" ] || fail "$product.sh is not checked in"

	sh "$TEST_ROOT/tools/render.sh" "$product" "$TMP/$product.sh" ||
		fail "$product does not render"
	cmp -s "$installer" "$TMP/$product.sh" ||
		fail "$product.sh is stale — run make regen"

	# Rendering twice from the same inputs must produce the same bytes, or
	# `make check` becomes a coin toss and nobody trusts it.
	sh "$TEST_ROOT/tools/render.sh" "$product" "$TMP/$product.again.sh"
	cmp -s "$TMP/$product.sh" "$TMP/$product.again.sh" ||
		fail "$product renders differently on a second run"

	# No token may survive into the output: an installer that prints @BIN@ has
	# a config missing a value, and the message people see is nonsense.
	if grep -q '@[A-Z_][A-Z_]*@' "$installer"; then
		fail "$product.sh still contains an unsubstituted token"
	fi

	# The shell running the tests has to be able to parse and run it. --help
	# exercises argument parsing, the style setup, and the usage text.
	sh -n "$installer" || fail "$product.sh is not valid POSIX shell"
	sh "$installer" --help >"$TMP/$product.help" 2>&1 ||
		fail "$product.sh --help failed"
	grep -q "install.atomdrift.org/$product.sh" "$TMP/$product.help" ||
		fail "$product.sh --help does not name its own install URL"

	# An unknown option must be refused rather than ignored.
	if sh "$installer" --no-such-option >/dev/null 2>&1; then
		fail "$product.sh accepted an unknown option"
	fi

	# The constants the rest of the script depends on have to be populated.
	product_env=$(sed -n 's/^ENV="\([A-Z0-9_]*\)"$/\1/p' "$TEST_ROOT/products/$product.conf")
	[ -n "$product_env" ] || fail "$product.conf has no ENV prefix"
	(
		eval "export ${product_env}_INSTALLER_TESTING=1"
		# shellcheck disable=SC1090 # the installer under test, by design.
		. "$installer"
		[ -n "$BIN" ] || fail "$product.sh has an empty BIN"
		[ -n "$REPO" ] || fail "$product.sh has an empty REPO"
		[ -n "$TARGETS" ] || fail "$product.sh publishes no targets"
		[ -n "$EXAMPLES" ] || fail "$product.sh suggests no example commands"
		for target in $TARGETS; do
			case $target in
			*-*-*) ;;
			*) fail "$product.sh lists a malformed target: $target" ;;
			esac
		done
	) || exit 1
done

printf 'ok - generated installers are current, reproducible, and runnable:%s\n' "$products"
