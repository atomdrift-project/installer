#!/bin/sh
# render.sh PRODUCT [OUTFILE] — expand templates/install.sh.in for one product.
#
#   tools/render.sh scan            # writes scan.sh
#   tools/render.sh scan /dev/stdout
#
# The product's settings come from products/PRODUCT.conf, a plain sh file that
# assigns one shell variable per @TOKEN@ in the template. Rendering fails when a
# config leaves a token unset or the template asks for one that does not exist,
# so a half-substituted installer never reaches disk.
#
# POSIX sh and awk only, for the same reason the installers are: this has to run
# wherever someone edits them.

set -eu

# shellcheck disable=SC1007 # CDPATH= is cleared for this cd, not an assignment.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMPLATE="$ROOT/templates/install.sh.in"

die() {
	printf 'render: %s\n' "$*" >&2
	exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: render.sh PRODUCT [OUTFILE]"
PRODUCT=$1
CONF="$ROOT/products/$PRODUCT.conf"
OUT=${2:-"$ROOT/$PRODUCT.sh"}

[ -f "$TEMPLATE" ] || die "no template at $TEMPLATE"
[ -f "$CONF" ] || die "no configuration at $CONF"

# Every token the template accepts. A config that sets anything else has a typo
# in it, and a config missing one of these renders a broken installer.
# One line: awk's -v cannot carry a newline.
TOKENS="PRODUCT DISPLAY UI_ENV TAGLINE READY FOOTER REPO BIN ENV FORMULA FORMULA_DEPS TARGETS EXAMPLES UNRELEASED_REF WINDOWS_HINT SOURCE_GB BUILD_NOTE TOOLS_BARE UPDATE_COMMAND"

# PRODUCT is supplied rather than configured: it names the file being rendered,
# so a config cannot disagree with its own filename.
# shellcheck disable=SC1090 # the path is derived from an argument by design.
. "$CONF"
PRODUCT=$1

# Token values are pasted into shell source, so anything that could end a quote
# or start an expansion has to be refused here rather than discovered by whoever
# pipes the result into sh. Product blurbs need none of it.
check_value() {
	case $2 in
	*\'* | *\"* | *\$* | *\`* | *\\*) die "$CONF: $1 may not contain a quote, backslash, dollar sign, or backtick" ;;
	esac
	# Values that land in code rather than prose are stricter still: names,
	# repository paths, or whitespace-separated lists of them.
	case $1 in
	BIN | ENV | UI_ENV | FORMULA | FORMULA_DEPS | REPO | TARGETS | SOURCE_GB | UNRELEASED_REF)
		case $(printf '%s' "$2" | tr -d ' \t\n') in
		*[!0-9A-Za-z._/+-]*) die "$CONF: $1 must be names, not prose" ;;
		esac
		;;
	esac
}

for tok in $TOKENS; do
	eval "[ \"\${$tok+set}\" = set ]" || die "$CONF does not set $tok"
	eval "check_value \"\$tok\" \"\$$tok\""
	eval "export $tok"
done

# Substitute @TOKEN@ anywhere it appears, including multi-line values, and fail
# on any token the list above does not cover rather than shipping it verbatim.
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
			token = substr(line, RSTART, RLENGTH)
			if (!(token in value)) {
				printf "render: unknown token %s on line %d\n", token, NR > "/dev/stderr"
				exit 1
			}
			out = out substr(line, 1, RSTART - 1) value[token]
			line = substr(line, RSTART + RLENGTH)
		}
		print out line
	}
' "$TEMPLATE" >"$OUT.tmp.$$" || {
	rm -f "$OUT.tmp.$$"
	die "could not render $PRODUCT"
}

chmod 755 "$OUT.tmp.$$"
mv -f "$OUT.tmp.$$" "$OUT"
