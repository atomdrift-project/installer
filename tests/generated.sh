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

	sh "$TEST_ROOT/tools/render.sh" "$product.sh" "$TMP/$product.sh" ||
		fail "$product does not render"
	cmp -s "$installer" "$TMP/$product.sh" ||
		fail "$product.sh is stale — run make regen"

	# Rendering twice from the same inputs must produce the same bytes, or
	# `make check` becomes a coin toss and nobody trusts it.
	sh "$TEST_ROOT/tools/render.sh" "$product.sh" "$TMP/$product.again.sh"
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

# PowerShell installers. This shell cannot run them — tests/windows.ps1 does
# that on Windows — so check what generation alone decides.
windows=""
for product in $products; do
	conf="$TEST_ROOT/products/$product.conf"
	if [ ! -f "$TEST_ROOT/$product.ps1" ]; then
		# A Unix installer must not send Windows users to a script that is not
		# there, and a config must not describe one nobody renders.
		if grep -q "$product\.ps1" "$conf"; then
			fail "$product.conf points Windows users at $product.ps1, which is not checked in"
		fi
		if grep -q '^WINDOWS_TARGETS=' "$conf"; then
			fail "$product.conf sets WINDOWS_TARGETS, but $product.ps1 is not checked in"
		fi
		continue
	fi
	windows="$windows $product"
	installer="$TEST_ROOT/$product.ps1"
	grep -q "irm https://install.atomdrift.org/$product.ps1 | iex" "$conf" ||
		fail "$product.sh does not point Windows users at $product.ps1"

	sh "$TEST_ROOT/tools/render.sh" "$product.ps1" "$TMP/$product.ps1" ||
		fail "$product.ps1 does not render"
	cmp -s "$installer" "$TMP/$product.ps1" ||
		fail "$product.ps1 is stale — run make regen"
	sh "$TEST_ROOT/tools/render.sh" "$product.ps1" "$TMP/$product.again.ps1"
	cmp -s "$TMP/$product.ps1" "$TMP/$product.again.ps1" ||
		fail "$product.ps1 renders differently on a second run"

	if grep -q '@[A-Z_][A-Z_]*@' "$installer"; then
		fail "$product.ps1 still contains an unsubstituted token"
	fi
	# Windows PowerShell 5.1 reads a script without a byte-order mark in the
	# legacy code page, so anything outside ASCII arrives mangled.
	if LC_ALL=C grep -q '[^	 -~]' "$installer"; then
		fail "$product.ps1 contains non-ASCII bytes"
	fi
	grep -q "install.atomdrift.org/$product.ps1" "$installer" ||
		fail "$product.ps1 does not name its own install URL"

	# Every Windows target has to be a Windows triple: the installer only ever
	# detects those, so anything else is dead weight or a typo.
	# shellcheck disable=SC1090 # the product's own config, by design.
	windows_targets=$(. "$conf" && printf '%s' "${WINDOWS_TARGETS:-}")
	[ -n "$windows_targets" ] || fail "$product.conf sets no WINDOWS_TARGETS"
	for target in $windows_targets; do
		case $target in
		*-pc-windows-*) ;;
		*) fail "$product.ps1 lists a non-Windows target: $target" ;;
		esac
	done
done
[ -n "$windows" ] || fail 'no PowerShell installers found'

printf 'ok - PowerShell installers are current, reproducible, and ASCII:%s\n' "$windows"
