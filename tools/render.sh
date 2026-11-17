#!/bin/sh
# render.sh INSTALLER [OUTFILE] — expand one installer template for one product.
#
#   tools/render.sh scan.sh             # writes scan.sh from templates/install.sh.in
#   tools/render.sh cleave.ps1          # writes cleave.ps1 from templates/install.ps1.in
#   tools/render.sh scan.sh /dev/stdout
#
# The product's settings come from products/PRODUCT.conf, a plain sh file that
# assigns one shell variable per @TOKEN@ in the template. The tokens are read
# from the template itself, so rendering fails when a config leaves one unset,
# and a half-substituted installer never reaches disk.
#
# POSIX sh and awk only, for the same reason the installers are: this has to run
# wherever someone edits them.

set -eu

# shellcheck disable=SC1007 # CDPATH= is cleared for this cd, not an assignment.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

die() {
	printf 'render: %s\n' "$*" >&2
	exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: render.sh INSTALLER [OUTFILE]"
INSTALLER=$1
case $INSTALLER in
*/*) die "$INSTALLER: name an installer, such as scan.sh, not a path" ;;
?*.sh) KIND=sh MODE=755 ;;
?*.ps1) KIND=ps1 MODE=644 ;;
*) die "$INSTALLER: expected PRODUCT.sh or PRODUCT.ps1" ;;
esac
PRODUCT=${INSTALLER%.*}
TEMPLATE="$ROOT/templates/install.$KIND.in"
CONF="$ROOT/products/$PRODUCT.conf"
OUT=${2:-"$ROOT/$INSTALLER"}

[ -f "$TEMPLATE" ] || die "no template at $TEMPLATE"
[ -f "$CONF" ] || die "no configuration at $CONF"

# Every token this template asks for. One line: awk's -v cannot carry a newline.
TOKENS=$(grep -o '@[A-Z_][A-Z_]*@' "$TEMPLATE" | tr -d @ | sort -u | tr '\n' ' ')

# PRODUCT is supplied rather than configured: it names the file being rendered,
# so a config cannot disagree with its own filename.
# shellcheck disable=SC1090 # the path is derived from an argument by design.
. "$CONF"
PRODUCT=${INSTALLER%.*}

# Token values are pasted into shell and PowerShell source, so anything that
# could end a quote or start an expansion in either has to be refused here
# rather than discovered by whoever runs the result. Product blurbs need none
# of it.
check_value() {
	case $2 in
	*\'* | *\"* | *\$* | *\`* | *\\*) die "$CONF: $1 may not contain a quote, backslash, dollar sign, or backtick" ;;
	esac
	# Values that land in code rather than prose are stricter still: names,
	# repository paths, or whitespace-separated lists of them.
	case $1 in
	BIN | ENV | UI_ENV | FORMULA | FORMULA_DEPS | REPO | TARGETS | WINDOWS_TARGETS | SOURCE_GB | UNRELEASED_REF)
		case $(printf '%s' "$2" | tr -d ' \t\n') in
		*[!0-9A-Za-z._/+-]*) die "$CONF: $1 must be names, not prose" ;;
		esac
		;;
	esac
	# Windows PowerShell 5.1 reads a script without a byte-order mark in the
	# legacy code page, and it treats typographic quotes as real ones, so a
	# PowerShell installer stays pure ASCII.
	if [ "$KIND" = ps1 ]; then
		case $(printf '%s' "$2" | LC_ALL=C tr -d '\t\n -~') in
		?*) die "$CONF: $1 must be ASCII for $INSTALLER" ;;
		esac
	fi
}

for tok in $TOKENS; do
	eval "[ \"\${$tok+set}\" = set ]" || die "$CONF does not set $tok, which $INSTALLER needs"
	eval "check_value \"\$tok\" \"\$$tok\""
	eval "export $tok"
done

# Substitute @TOKEN@ anywhere it appears, including multi-line values.
awk -v tokens="$TOKENS" '
	BEGIN {
		n = split(tokens, list, /[ \t\n]+/)
		for (i = 1; i <= n; i++)
			if (list[i] != "") value["@" list[i] "@"] = ENVIRON[list[i]]
	}
	{
		line = $0
		out = ""
		while (match(line, /@[A-Z_]+@/)) {
			out = out substr(line, 1, RSTART - 1) value[substr(line, RSTART, RLENGTH)]
			line = substr(line, RSTART + RLENGTH)
		}
		print out line
	}
' "$TEMPLATE" >"$OUT.tmp.$$" || {
	rm -f "$OUT.tmp.$$"
	die "could not render $INSTALLER"
}

chmod "$MODE" "$OUT.tmp.$$"
mv -f "$OUT.tmp.$$" "$OUT"
