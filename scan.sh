#!/bin/sh
# install.sh — install Atomdrift Scan (the `atomscan` CLI).
#
#   curl -fsSL https://install.atomdrift.org/scan.sh | sh
#
# Passing options through a pipe needs `sh -s --`:
#
#   curl -fsSL https://install.atomdrift.org/scan.sh | sh -s -- --dir ~/bin --method binary
#
# What it does, in order: work out the platform, pick an install method, fetch a
# release binary (checksum- and provenance-verified), fall back to a source
# build when no binary exists for the platform, then report on the optional
# analysis tools that make scans deeper.
#
# Re-running is safe and cheap: an install that is already current is left
# alone, and everything written to the install directory is written atomically.
#
# POSIX sh only — no bashisms, no `local`, no arrays. This has to run on macOS,
# Linux (glibc and musl), FreeBSD, OpenBSD, NetBSD, DragonFly, and illumos,
# where /bin/sh may be dash, ash, busybox, or ksh93. Function-scoped variables
# do not exist here, so each function prefixes its own.

set -eu

REPO="atomdrift-project/scan"
BIN="atomscan"
TAP="atomdrift-project/tap"

# Targets published by .github/workflows/release.yml. Anything else takes the
# source path.
TARGETS="
x86_64-unknown-linux-gnu
aarch64-unknown-linux-gnu
x86_64-unknown-linux-musl
aarch64-unknown-linux-musl
s390x-unknown-linux-gnu
riscv64gc-unknown-linux-gnu
powerpc64le-unknown-linux-gnu
aarch64-apple-darwin
x86_64-apple-darwin
x86_64-unknown-freebsd
x86_64-unknown-openbsd
x86_64-unknown-netbsd
x86_64-unknown-dragonfly
x86_64-unknown-haiku
x86_64-unknown-hurd-gnu
x86_64-unknown-illumos
x86_64-pc-solaris
"

# Settings, overridable by flag or environment.
OPT_VERSION="${ATOMSCAN_VERSION:-}"
OPT_DIR="${ATOMSCAN_INSTALL_DIR:-}"
OPT_METHOD="${ATOMSCAN_METHOD:-auto}"
OPT_TOOLS=1
OPT_FORCE=0
OPT_QUIET=0
[ -n "${ATOMSCAN_NO_TOOLS:-}" ] && OPT_TOOLS=0

# Filled in as we go; declared here so the shape of the script is visible.
SELF=""         # this machine's target triple, published or not
TARGET=""       # same, but empty unless a release actually carries it
PLATFORM=""     # human-readable platform description
METHOD=""       # resolved: brew | binary | source
VERSION=""      # version being installed, without the leading v
INSTALL_DIR=""  # directory the binary lands in
INSTALLED=""    # full path of the binary we installed
CHANGED=0       # whether this run actually replaced anything
INSTALL_ESCALATOR="" # doas | pfexec | sudo, when INSTALL_DIR needs privilege
INSTALL_PRIVILEGED=0 # whether writes to INSTALL_DIR need that escalator
BREW_PREFIX=""  # Homebrew root, empty when there is no Homebrew
DOWNLOADER=""   # curl | wget | fetch | ftp
WGET_MODERN=0   # GNU wget (spider, header dumps) rather than busybox wget
TMP=""          # scratch directory, removed on exit
INSTALL_TMP=""  # same-directory binary staging file, removed on failure
SOURCE_STAGE="" # staged source clone, removed when an install is interrupted
SOURCE_OLD=""   # previous checkout, restored if a staged swap is interrupted
SOURCE_DEST=""  # canonical checkout path paired with SOURCE_OLD

usage() {
	cat <<EOF
Install Atomdrift Scan — malware and supply-chain analysis for files,
directories, archives, packages, URLs, and processes.

Usage: install.sh [options]
       curl -fsSL https://install.atomdrift.org/scan.sh | sh -s -- [options]

Options:
  --version VERSION   Install a specific version (default: the latest release).
  --dir DIR           Install into DIR (default: a suitable directory on PATH).
  --method METHOD     auto, binary, brew, or source. auto prefers Homebrew on
                      macOS and Linux, then a release binary, then source.
  --no-tools          Skip the optional analysis tool check (rizin, upx, ...).
  --force             Reinstall even when the target version is already there.
  --quiet             Only report problems.
  --help              Show this message.

Environment:
  ATOMSCAN_VERSION, ATOMSCAN_INSTALL_DIR, ATOMSCAN_METHOD, ATOMSCAN_NO_TOOLS
  SCAN_THEME          dark (default) or light, matching the scanner.
  NO_COLOR            Disable colour (any value).

To uninstall: delete the binary whose path this prints, or run
\`brew uninstall $TAP/scan\` if it was installed with Homebrew.

The default prefers a user-owned directory already on PATH. If none is usable,
it may install into the operating system's local PATH using doas, pfexec, or
sudo (in that preference order).
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
		--version) [ $# -ge 2 ] || die "--version needs a value"; OPT_VERSION=$2; shift 2 ;;
		--version=*) OPT_VERSION=${1#*=}; shift ;;
		--dir) [ $# -ge 2 ] || die "--dir needs a value"; OPT_DIR=$2; shift 2 ;;
		--dir=*) OPT_DIR=${1#*=}; shift ;;
		--method) [ $# -ge 2 ] || die "--method needs a value"; OPT_METHOD=$2; shift 2 ;;
		--method=*) OPT_METHOD=${1#*=}; shift ;;
		--no-tools) OPT_TOOLS=0; shift ;;
		--force) OPT_FORCE=1; shift ;;
		--quiet | -q) OPT_QUIET=1; shift ;;
		--help | -h) usage; exit 0 ;;
		*) usage >&2; printf '\nunknown option: %s\n' "$1" >&2; exit 2 ;;
		esac
	done

	case $OPT_METHOD in
	auto | binary | brew | source) ;;
	*) die "--method must be auto, binary, brew, or source (got '$OPT_METHOD')" ;;
	esac
	OPT_VERSION=${OPT_VERSION#v}
	case $OPT_VERSION in
	*[!0-9A-Za-z._+-]*) die "invalid version '$OPT_VERSION'" ;;
	esac
}

# ---------------------------------------------------------------------------
# Style
#
# Match Scan's litmus palette: green for success, amber for attention, red for
# failure, and neutral grey for ordinary progress. Redirected output and
# NO_COLOR remain clean plain text.
# ---------------------------------------------------------------------------

setup_style() {
	ESC=$(printf '\033')
	TTY=0
	[ -t 1 ] && TTY=1

	if [ "${NO_COLOR+x}" = x ] || [ "$TTY" = 0 ] || [ "${TERM:-dumb}" = dumb ]; then
		C_RED='' C_AMBER='' C_GREEN=''
		C_DIM='' C_BOLD='' C_RESET=''
	else
		case "${SCAN_THEME:-dark}" in
		light | white)
			C_RED="${ESC}[38;2;200;30;30m" C_AMBER="${ESC}[38;2;180;120;0m"
			C_GREEN="${ESC}[38;2;30;140;30m" C_DIM="${ESC}[38;2;120;120;120m"
			;;
		*)
			C_RED="${ESC}[38;2;255;70;70m" C_AMBER="${ESC}[38;2;255;175;55m"
			C_GREEN="${ESC}[38;2;80;200;80m" C_DIM="${ESC}[38;2;100;100;100m"
			;;
		esac
		C_BOLD="${ESC}[1m" C_RESET="${ESC}[0m"
	fi

	# Friendly glyphs in UTF-8 locales, with an ASCII fallback for old consoles
	# and minimal environments.
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UTF8=1 ;;
	*) UTF8=0 ;;
	esac
	if [ "$UTF8" = 1 ]; then
		G_SCAN="🔍" G_STEP="·" G_OK="✓" G_WARN="⚠" G_ERR="✗"
	else
		G_SCAN="*" G_STEP="-" G_OK="+" G_WARN="!" G_ERR="x"
	fi
}

# step LABEL VALUE — one aligned line of progress.
step() {
	if [ "$OPT_QUIET" = 0 ]; then
		printf ' %s%s%s %s%-11s%s%s\n' "$C_DIM" "$G_STEP" "$C_RESET" "$C_DIM" "$1" "$C_RESET" "$2"
	fi
}

ok() {
	if [ "$OPT_QUIET" = 0 ]; then
		printf ' %s%s%s %s%-11s%s%s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$C_DIM" "$1" "$C_RESET" "$2"
	fi
}

note() {
	if [ "$OPT_QUIET" = 0 ]; then
		printf '   %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
	fi
}

warn() {
	printf ' %s%s%s %s\n' "$C_AMBER" "$G_WARN" "$C_RESET" "$1" >&2
}

die() {
	printf '\n %s%s%s %s%s%s\n\n' "$C_RED" "$G_ERR" "$C_RESET" "$C_BOLD" "$1" "$C_RESET" >&2
	exit 1
}

banner() {
	if [ "$OPT_QUIET" = 1 ]; then
		return 0
	fi
	printf '\n %s%s%s %sInstalling Atomdrift Scan%s\n\n' \
		"$C_DIM" "$G_SCAN" "$C_RESET" "$C_BOLD" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Scratch space
# ---------------------------------------------------------------------------

cleanup() {
	[ -n "$TMP" ] && rm -rf "$TMP"
	if [ -n "$INSTALL_TMP" ]; then
		if [ "$INSTALL_PRIVILEGED" = 1 ] && [ -n "$INSTALL_ESCALATOR" ]; then
			"$INSTALL_ESCALATOR" rm -f "$INSTALL_TMP" 2>/dev/null || :
		else
			rm -f "$INSTALL_TMP" 2>/dev/null || :
		fi
	fi
	[ -n "$SOURCE_STAGE" ] && rm -rf "$SOURCE_STAGE"
	if [ -n "$SOURCE_OLD" ]; then
		if [ -n "$SOURCE_DEST" ] && [ ! -e "$SOURCE_DEST" ] && [ ! -L "$SOURCE_DEST" ]; then
			mv "$SOURCE_OLD" "$SOURCE_DEST" 2>/dev/null || :
		fi
	fi
	return 0
}

make_tmpdir() {
	TMP=$(mktemp -d 2>/dev/null) || TMP=""
	if [ -z "$TMP" ]; then
		TMP="${TMPDIR:-/tmp}/atomscan-install.$$"
		(umask 077 && mkdir "$TMP") || die "cannot create a temporary directory"
	fi
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

detect_platform() {
	dp_os=$(uname -s 2>/dev/null || echo unknown)
	dp_arch=$(uname -m 2>/dev/null || echo unknown)
	dp_desc=""

	case $dp_arch in
	x86_64 | amd64) dp_arch=x86_64 ;;
	i86pc) dp_arch=x86_64 ;;
	aarch64 | arm64) dp_arch=aarch64 ;;
	riscv64 | riscv64gc) dp_arch=riscv64gc ;;
	ppc64le | powerpc64le) dp_arch=powerpc64le ;;
	esac

	case $dp_os in
	Linux)
		dp_operating=$(uname -o 2>/dev/null || :)
		dp_libc=gnu
		case "$dp_operating:${ANDROID_ROOT:-}" in
		*[Aa]ndroid* | *:/system*) dp_libc=musl ;;
		*)
			# musl announces itself only in ldd's usage message, and that ldd
			# exits non-zero while printing it.
			if ls /lib/ld-musl-* >/dev/null 2>&1 || (ldd --version 2>&1 || :) | grep -qi musl; then
				dp_libc=musl
			fi
			;;
		esac
		SELF="$dp_arch-unknown-linux-$dp_libc"
		dp_desc="Linux"
		[ "$dp_operating" = Android ] && dp_desc=Android
		if [ -r /etc/os-release ]; then
			# shellcheck disable=SC1091
			dp_pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
			[ -n "$dp_pretty" ] && dp_desc=$dp_pretty
		fi
		;;
	Darwin)
		# Under Rosetta `uname -m` says x86_64. Install the native binary.
		if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
			dp_arch=aarch64
		fi
		SELF="$dp_arch-apple-darwin"
		dp_desc="macOS $(sw_vers -productVersion 2>/dev/null || :)"
		;;
	FreeBSD) SELF="$dp_arch-unknown-freebsd" dp_desc="FreeBSD $(uname -r 2>/dev/null || :)" ;;
	OpenBSD) SELF="$dp_arch-unknown-openbsd" dp_desc="OpenBSD $(uname -r 2>/dev/null || :)" ;;
	NetBSD) SELF="$dp_arch-unknown-netbsd" dp_desc="NetBSD $(uname -r 2>/dev/null || :)" ;;
	DragonFly) SELF="$dp_arch-unknown-dragonfly" dp_desc="DragonFly $(uname -r 2>/dev/null || :)" ;;
	Haiku) SELF="$dp_arch-unknown-haiku" dp_desc="Haiku $(uname -r 2>/dev/null || :)" ;;
	GNU) SELF="$dp_arch-unknown-hurd-gnu" dp_desc="GNU/Hurd $(uname -r 2>/dev/null || :)" ;;
	SunOS)
		dp_uname_o=$(uname -o 2>/dev/null || :)
		case "$dp_uname_o $(uname -v 2>/dev/null || :)" in
		*[Ii]llumos* | *[Oo]mni[Oo][Ss]*) SELF="$dp_arch-unknown-illumos" ;;
		*) SELF="$dp_arch-pc-solaris" ;;
		esac
		dp_desc="$dp_uname_o $(uname -r 2>/dev/null || :)"
		;;
	CYGWIN* | MINGW* | MSYS* | Windows_NT)
		die "on Windows, use install.ps1 instead:
   irm https://install.atomdrift.org/scan.ps1 | iex"
		;;
	*)
		SELF="$dp_arch-unknown-$(printf '%s' "$dp_os" | tr '[:upper:]' '[:lower:]')"
		dp_desc="$dp_os $(uname -r 2>/dev/null || :)"
		;;
	esac

	# TARGET is SELF only when a release actually carries it; otherwise the
	# source path takes over.
	TARGET=""
	for dp_t in $TARGETS; do
		[ "$dp_t" = "$SELF" ] && TARGET=$SELF
	done

	# Keep the compiler target internal. Human output should identify the OS
	# once, with the architecture as the useful secondary detail.
	PLATFORM="${dp_desc% }  ${C_DIM}· $dp_arch${C_RESET}"
	return 0
}

# ---------------------------------------------------------------------------
# HTTP
#
# curl, wget, fetch, and ftp in that order: OpenBSD and NetBSD ship the last two
# in the base system and nothing else, and both are targets we publish.
# ---------------------------------------------------------------------------

find_downloader() {
	for fd_c in curl wget fetch ftp; do
		if command -v "$fd_c" >/dev/null 2>&1; then
			DOWNLOADER=$fd_c
			break
		fi
	done
	[ -n "$DOWNLOADER" ] || die "no HTTP client found — install curl or wget and re-run"

	# busybox wget accepts neither --spider nor -S. Ask once instead of
	# discovering it mid-install.
	if [ "$DOWNLOADER" = wget ] && wget --help 2>&1 | grep -q -- --spider; then
		WGET_MODERN=1
	fi
	return 0
}

# http_get URL OUTFILE — writes the body; non-zero on any HTTP or transport error.
http_get() {
	case $DOWNLOADER in
	curl) curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 -o "$2" "$1" ;;
	wget) wget -q -O "$2" "$1" ;;
	fetch) fetch -q -o "$2" "$1" ;;
	ftp) ftp -o "$2" "$1" ;;
	esac
}

# http_ok URL — false only when we can cheaply prove the URL is not there.
#
# Deliberately narrow: only a 404 counts as absent. A HEAD refused for any other
# reason must not be read as "this platform has no binary", or a working release
# would quietly become a twenty-minute source build.
http_ok() {
	case $DOWNLOADER in
	curl)
		ho_code=$(curl -sSLI --proto '=https' --tlsv1.2 -o /dev/null \
			-w '%{http_code}' "$1" 2>/dev/null || printf 000)
		[ "$ho_code" != 404 ]
		;;
	wget)
		[ "$WGET_MODERN" = 1 ] || return 0
		! wget --spider -S "$1" 2>&1 | grep -q ' 404 '
		;;
	*) : ;;
	esac
}

# resolve_latest — the newest release tag.
#
# Read from the redirect that /releases/latest performs, because the REST API is
# rate-limited per IP and CI runners share addresses. The API is the fallback
# for clients that cannot report a redirect target.
resolve_latest() {
	rl_url="https://github.com/$REPO/releases/latest"
	rl_final=""
	case $DOWNLOADER in
	curl) rl_final=$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "$rl_url" 2>/dev/null || :) ;;
	wget)
		if [ "$WGET_MODERN" = 1 ]; then
			rl_final=$(wget -q --spider -S "$rl_url" 2>&1 | awk '/^ *Location:/ { print $2 }' | tail -n 1 || :)
		fi
		;;
	esac
	case $rl_final in
	*/releases/tag/*)
		printf '%s' "${rl_final##*/tag/}"
		return 0
		;;
	esac

	http_get "https://api.github.com/repos/$REPO/releases/latest" "$TMP/latest.json" 2>/dev/null || return 1
	rl_tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/latest.json" | head -n 1)
	[ -n "$rl_tag" ] || return 1
	printf '%s' "$rl_tag"
}

file_size() {
	# `ls -ln` is the portable stat: GNU wants -c%s, BSD wants -f%z.
	# shellcheck disable=SC2012 # the path is ours, in a mode 700 temp dir
	fs_n=$(ls -ln "$1" 2>/dev/null | awk 'NR == 1 { print $5 }')
	case $fs_n in
	'' | *[!0-9]*) fs_n=0 ;;
	esac
	printf '%s' "$fs_n"
}

human_size() {
	awk -v b="$1" 'BEGIN {
		if (b >= 1048576) printf "%.1f MB", b / 1048576
		else if (b >= 1024) printf "%.0f KB", b / 1024
		else printf "%d B", b
	}'
}

# download URL OUTFILE LABEL
download() {
	dl_url=$1 dl_out=$2 dl_label=$3
	step download "$dl_label"
	http_get "$dl_url" "$dl_out" || return 1
	dl_got=$(file_size "$dl_out")
	note "downloaded $(human_size "$dl_got")"
}

# ---------------------------------------------------------------------------
# Integrity
# ---------------------------------------------------------------------------

# sha256_of FILE — lowercase hex digest, empty when nothing here can produce one.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print $1 }'
	elif command -v sha256 >/dev/null 2>&1; then
		sha256 -q "$1"
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{ print $NF }'
	elif command -v digest >/dev/null 2>&1; then
		digest -a sha256 "$1"
	elif cksum -a sha256 "$1" >/dev/null 2>&1; then
		cksum -a sha256 "$1" | awk '{ print $NF }'
	fi
}

# verify_checksum TARBALL SUMSFILE NAME — prints a short digest, non-zero on
# any doubt whatsoever. The caller treats failure as fatal.
#
# The digest travels over the same TLS connection as the archive, so this is a
# corruption and truncation check; verify_provenance below is the trust anchor.
verify_checksum() {
	vc_want=$(awk -v want="$3" '
		{ n = $2; sub(/^\.\//, "", n); sub(/^\*/, "", n)
		  if (n == want) { print tolower($1); exit } }' "$2")
	if [ -z "$vc_want" ]; then
		printf '%s is not listed in SHA256SUMS\n' "$3" >&2
		return 1
	fi

	vc_got=$(sha256_of "$1" | tr '[:upper:]' '[:lower:]')
	if [ -z "$vc_got" ]; then
		printf 'no sha256 tool found (sha256sum, shasum, openssl)\n' >&2
		return 1
	fi
	if [ "$vc_got" != "$vc_want" ]; then
		printf 'expected %s\n     got %s\n' "$vc_want" "$vc_got" >&2
		return 1
	fi

	printf '%s' "$vc_got" | cut -c1-12
}

# Signed build provenance, when the GitHub CLI is here to check it. Its absence
# is not an error: this is a stronger check than we can otherwise make, not a
# required one.
verify_provenance() {
	command -v gh >/dev/null 2>&1 || return 1
	gh attestation verify "$1" --repo "$REPO" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Install locations
# ---------------------------------------------------------------------------

on_path() {
	case ":$PATH:" in
	*":$1:"*) return 0 ;;
	*) return 1 ;;
	esac
}

writable_dir() {
	[ -d "$1" ] && [ -w "$1" ]
}

# Prefer the native least-surprising privilege tool.
find_escalator() {
	INSTALL_ESCALATOR=""
	[ "$(id -u)" = 0 ] && return 1
	for fe_cmd in doas pfexec sudo; do
		if command -v "$fe_cmd" >/dev/null 2>&1; then
			INSTALL_ESCALATOR=$fe_cmd
			return 0
		fi
	done
	return 1
}

# use_install_dir DIR REASON [ALLOW_PRIVILEGE] — use DIR directly when possible,
# otherwise optionally try each privilege mechanism in preference order. Trying
# the next tool after a policy or authentication failure matters on systems
# that ship more than one of doas, pfexec, and sudo.
use_install_dir() {
	uid_dir=$1 uid_reason=$2 uid_privilege=${3:-1}
	if mkdir -p "$uid_dir" 2>/dev/null && writable_dir "$uid_dir"; then
		INSTALL_DIR=$uid_dir
		INSTALL_PRIVILEGED=0
		INSTALL_ESCALATOR=""
		return 0
	fi

	[ "$uid_privilege" = 1 ] || return 1
	[ "$(id -u)" = 0 ] && return 1
	for uid_cmd in doas pfexec sudo; do
		command -v "$uid_cmd" >/dev/null 2>&1 || continue
		step privilege "$uid_cmd  ${C_DIM}($uid_reason)${C_RESET}"
		if "$uid_cmd" mkdir -p "$uid_dir"; then
			[ -d "$uid_dir" ] || continue
			INSTALL_DIR=$uid_dir
			INSTALL_ESCALATOR=$uid_cmd
			INSTALL_PRIVILEGED=1
			return 0
		fi
		warn "$uid_cmd could not prepare $uid_dir — trying another option"
	done
	return 1
}

# A package manager owns its prefix. Directly dropping a binary there would
# bypass its database, so leave those entries to the package-manager method.
managed_path_dir() {
	mpd_dir=$1
	if [ -n "$BREW_PREFIX" ]; then
		case $mpd_dir in
		"$BREW_PREFIX" | "$BREW_PREFIX"/*) return 0 ;;
		esac
	fi
	case $mpd_dir in
	/nix/store/* | /snap/* | /var/lib/flatpak/*) return 0 ;;
	esac
	return 1
}

# native_path_dirs OS — ordered, conventional destinations for manual binaries.
native_path_dirs() {
	case $1 in
	Haiku) printf '%s\n' '/boot/system/non-packaged/bin /usr/local/bin' ;;
	SunOS) printf '%s\n' '/opt/local/bin /usr/local/bin' ;;
	Darwin) printf '%s\n' '/usr/local/bin /opt/local/bin' ;;
	NetBSD) printf '%s\n' '/usr/local/bin /usr/pkg/bin' ;;
	*) printf '%s\n' '/usr/local/bin' ;;
	esac
	return 0
}

# Try OS-conventional local directories before following raw PATH order. Every
# candidate must already be on PATH: the command should work in the next shell
# without asking the user to edit their profile.
use_native_path_dir() {
	unpd_privilege=${1:-1}
	unpd_os=$(uname -s 2>/dev/null || echo unknown)
	unpd_dirs=$(native_path_dirs "$unpd_os")
	for unpd_dir in $unpd_dirs; do
		on_path "$unpd_dir" || continue
		managed_path_dir "$unpd_dir" && continue
		if use_install_dir "$unpd_dir" "$unpd_os PATH" "$unpd_privilege"; then
			return 0
		fi
	done
	return 1
}

# Follow PATH order without word-splitting directory names. Relative and empty
# entries are unsafe escalation targets. Native local directories were already
# attempted above; core directories such as /usr/bin are reached only here.
use_any_path_dir() {
	uap_privilege=${1:-1}
	uap_rest=$PATH
	while :; do
		case $uap_rest in
		*:*) uap_dir=${uap_rest%%:*}; uap_rest=${uap_rest#*:}; uap_last=0 ;;
		*) uap_dir=$uap_rest; uap_last=1 ;;
		esac

		case $uap_dir in
		/*)
			managed_path_dir "$uap_dir" || {
				if use_install_dir "$uap_dir" "PATH fallback" "$uap_privilege"; then
					return 0
				fi
			}
			;;
		esac
		[ "$uap_last" = 1 ] && break
	done
	return 1
}

# Path of an atomscan already on PATH, if any.
current_install() {
	command -v "$BIN" 2>/dev/null
}

# installed_version PATH — version string of a binary already on disk.
installed_version() {
	[ -x "$1" ] || return 1
	iv_out=$("$1" --version 2>/dev/null) || return 1
	printf '%s' "$iv_out" | awk '{ print $2; exit }'
}

resolve_install_dir() {
	INSTALL_PRIVILEGED=0
	INSTALL_ESCALATOR=""
	if [ -n "$OPT_DIR" ]; then
		if use_install_dir "$OPT_DIR" "explicit --dir"; then
			return 0
		fi
		die "$OPT_DIR is not writable and no privilege tool could prepare it
   Prefer --dir \$HOME/.local/bin, or install doas, pfexec, or sudo for a system path."
	fi

	# Upgrading in place beats installing a second copy that shadows the first.
	# Anything Homebrew owns is left to Homebrew.
	rid_cur=$(current_install || :)
	if [ -n "$rid_cur" ]; then
		rid_dir=$(dirname "$rid_cur")
		rid_brewed=0
		if [ -n "$BREW_PREFIX" ] && [ "${rid_dir#"$BREW_PREFIX"}" != "$rid_dir" ]; then
			rid_brewed=1
		fi
		if [ "$rid_brewed" = 0 ] && writable_dir "$rid_dir"; then
			INSTALL_DIR=$rid_dir
			return 0
		fi
	fi

	# A PATH entry wins even when its directory has not been created yet. This
	if [ -n "${HOME:-}" ]; then
		if [ "$(uname -s 2>/dev/null || :)" = Haiku ]; then
			rid_haiku="$HOME/config/non-packaged/bin"
			if on_path "$rid_haiku" && mkdir -p "$rid_haiku" 2>/dev/null && writable_dir "$rid_haiku"; then
				INSTALL_DIR=$rid_haiku
				return 0
			fi
		fi
		for rid_d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.cargo/bin"; do
			on_path "$rid_d" || continue
			if [ ! -d "$rid_d" ]; then
				mkdir -p "$rid_d" 2>/dev/null || continue
			fi
			if writable_dir "$rid_d"; then
				INSTALL_DIR=$rid_d
				return 0
			fi
		done
	fi

	# Search all PATH entries without privilege before considering elevation. A
	# writable custom user bin directory must beat even a conventional /usr/bin.
	use_native_path_dir 0 && return 0
	use_any_path_dir 0 && return 0

	# Nothing writable was available. Prefer the OS's conventional local prefix,
	# then honor PATH order as the final (possibly privileged) fallback.
	use_native_path_dir 1 && return 0
	use_any_path_dir 1 && return 0
	die "no usable absolute directory was found on PATH
   Add \$HOME/.local/bin or \$HOME/bin to PATH, or choose one with --dir."
}

# install_binary_file SRC — move SRC into place atomically.
#
# Writing beside the destination and renaming means a reader sees either the old
# binary or the new one and never a half-written file, which matters most when
# the thing being replaced is a binary that is currently running.
install_binary_file() {
	ibf_dest="$INSTALL_DIR/$BIN"
	ibf_tmp="$INSTALL_DIR/.$BIN.new.$$"
	INSTALL_TMP=$ibf_tmp
	if [ "$INSTALL_PRIVILEGED" = 1 ]; then
		"$INSTALL_ESCALATOR" cp "$1" "$ibf_tmp" || {
			"$INSTALL_ESCALATOR" rm -f "$ibf_tmp" 2>/dev/null || :
			die "cannot write to $INSTALL_DIR with $INSTALL_ESCALATOR"
		}
		"$INSTALL_ESCALATOR" chmod 755 "$ibf_tmp" || {
			"$INSTALL_ESCALATOR" rm -f "$ibf_tmp" 2>/dev/null || :
			die "cannot make $ibf_tmp executable"
		}
		"$INSTALL_ESCALATOR" mv -f "$ibf_tmp" "$ibf_dest" || {
			"$INSTALL_ESCALATOR" rm -f "$ibf_tmp" 2>/dev/null || :
			die "cannot replace $ibf_dest with $INSTALL_ESCALATOR"
		}
	else
		cp "$1" "$ibf_tmp" || {
			rm -f "$ibf_tmp" 2>/dev/null || :
			die "cannot write to $INSTALL_DIR"
		}
		chmod 755 "$ibf_tmp" || {
			rm -f "$ibf_tmp" 2>/dev/null || :
			die "cannot make $ibf_tmp executable"
		}
		mv -f "$ibf_tmp" "$ibf_dest" || {
			rm -f "$ibf_tmp"
			die "cannot replace $ibf_dest"
		}
	fi
	INSTALL_TMP=""
	INSTALLED=$ibf_dest
	CHANGED=1
}

# ---------------------------------------------------------------------------
# Method: Homebrew
#
# On macOS and Linux it owns upgrades, PATH, and — through the cleave formula —
# rizin and upx. The formula builds from source, which is slow, so say so and
# leave `--method binary` one flag away.
# ---------------------------------------------------------------------------

brew_works() {
	command -v brew >/dev/null 2>&1 && brew --version >/dev/null 2>&1
}

trust_brew_formulae() {
	# Homebrew 6 requires every non-official formula it evaluates to be trusted.
	# Installing scan by its fully qualified name trusts scan itself, but not the
	# cleave formula it depends on. Keep the grant narrow instead of trusting the
	# whole tap, and support Homebrew versions without the `trust` command.
	if brew help trust >/dev/null 2>&1; then
		brew trust --formula "$TAP/scan" "$TAP/cleave" || return 1
	fi
}

auto_method() {
	case "$(uname -s 2>/dev/null || :)" in
	Darwin | Linux)
		if brew_works && [ -z "$OPT_DIR" ] && [ -z "$OPT_VERSION" ]; then
			printf '%s\n' brew
			return 0
		fi
		;;
	esac
	printf '%s\n' binary
}

install_brew() {
	step method "Homebrew  ${C_DIM}$TAP/scan${C_RESET}"

	trust_brew_formulae || return 1
	br_prefix=$(brew --prefix 2>/dev/null) || return 1
	if brew list --formula "$TAP/scan" >/dev/null 2>&1; then
		if [ "$OPT_FORCE" = 1 ]; then
			note "reinstalling through Homebrew — it builds from source, so this takes a while"
			brew reinstall --formula "$TAP/scan" || return 1
			CHANGED=1
			INSTALLED="$br_prefix/bin/$BIN"
			VERSION=$(installed_version "$INSTALLED" || :)
			return 0
		fi
		if [ -z "$(brew outdated --formula --quiet "$TAP/scan" 2>/dev/null)" ]; then
			INSTALLED="$br_prefix/bin/$BIN"
			VERSION=$(installed_version "$INSTALLED" || :)
			ok "up to date" "$INSTALLED  ${C_DIM}${VERSION}${C_RESET}"
			return 0
		fi
		note "upgrading through Homebrew — it builds from source, so this takes a while"
		brew upgrade --formula "$TAP/scan" || return 1
	else
		note "installing through Homebrew — it builds from source, so this takes a while"
		note "for a prebuilt binary instead, re-run with --method binary"
		brew install --formula "$TAP/scan" || return 1
	fi

	CHANGED=1
	INSTALLED="$br_prefix/bin/$BIN"
	[ -x "$INSTALLED" ] || return 1
	VERSION=$(installed_version "$INSTALLED" || :)
	return 0
}

# ---------------------------------------------------------------------------
# Method: release binary
#
# Returns non-zero when this platform has no published binary — the signal for
# main() to fall back to a source build.
# ---------------------------------------------------------------------------

install_binary() {
	if [ -z "$TARGET" ]; then
		warn "no published binary for this platform"
		return 1
	fi
	[ -n "$DOWNLOADER" ] || find_downloader

	if [ -n "$OPT_VERSION" ]; then
		VERSION=$OPT_VERSION
	else
		VERSION=$(resolve_latest || :)
		VERSION=${VERSION#v}
		if [ -z "$VERSION" ]; then
			warn "could not work out the latest release"
			return 1
		fi
	fi
	step version "$VERSION${OPT_VERSION:+  ${C_DIM}(pinned)${C_RESET}}"

	# Idempotence: an install that is already what we would install is done.
	ib_have=$(installed_version "$INSTALL_DIR/$BIN" || :)
	if [ "$OPT_FORCE" = 0 ] && [ "$ib_have" = "$VERSION" ]; then
		INSTALLED="$INSTALL_DIR/$BIN"
		ok "up to date" "$INSTALLED  ${C_DIM}$VERSION${C_RESET}"
		return 0
	fi

	ib_name="$BIN-$VERSION-$TARGET.tar.gz"
	ib_base="https://github.com/$REPO/releases/download/v$VERSION"

	if ! http_ok "$ib_base/$ib_name"; then
		warn "release v$VERSION publishes no binary for $TARGET"
		return 1
	fi

	step method "release binary  ${C_DIM}$TARGET${C_RESET}"
	download "$ib_base/$ib_name" "$TMP/$ib_name" "$ib_name" || {
		warn "download failed"
		return 1
	}

	http_get "$ib_base/SHA256SUMS" "$TMP/SHA256SUMS" ||
		die "release v$VERSION publishes no SHA256SUMS — refusing to install unverified"
	ib_digest=$(verify_checksum "$TMP/$ib_name" "$TMP/SHA256SUMS" "$ib_name") ||
		die "$ib_name failed verification — refusing to install"

	if verify_provenance "$TMP/$ib_name"; then
		ok verified "sha256 $ib_digest  ${C_DIM}·  provenance attested${C_RESET}"
	else
		ok verified "sha256 $ib_digest"
	fi

	# Solaris and illumos tar have no -z; piping gzip works everywhere.
	mkdir -p "$TMP/x"
	gzip -dc "$TMP/$ib_name" | (cd "$TMP/x" && tar -xf -) || die "cannot unpack $ib_name"
	[ -f "$TMP/x/$BIN" ] || die "$ib_name does not contain $BIN"
	chmod 755 "$TMP/x/$BIN" || die "cannot make the downloaded $BIN executable"
	if ! "$TMP/x/$BIN" --version >/dev/null 2>&1; then
		warn "the $TARGET release binary does not run on this machine"
		return 1
	fi

	install_binary_file "$TMP/x/$BIN"
}

# ---------------------------------------------------------------------------
# Method: source
#
# The fallback for platforms with no published binary, and for anyone who asks
# for it. The checkout stays in the cache directory so a later re-run is an
# incremental rebuild rather than a cold one.
# ---------------------------------------------------------------------------

rust_hint() {
	if command -v rustup >/dev/null 2>&1; then
		printf 'rustup update stable'
	elif [ "$(uname -s)" = Darwin ] && brew_works; then
		if command -v rustc >/dev/null 2>&1; then printf 'brew upgrade rust'; else printf 'brew install rust'; fi
	elif [ "$(uname -s)" = FreeBSD ] && command -v pkg >/dev/null 2>&1; then
		if command -v rustc >/dev/null 2>&1; then printf 'pkg upgrade rust'; else printf 'pkg install rust'; fi
	else
		printf "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
	fi
}

inspect_rust() {
	RUST_COMPATIBLE=0
	RUST_VERSION=$(rustc --version 2>/dev/null | awk 'NR == 1 && $1 == "rustc" { print $2 }' || :)
	if [ -z "$RUST_VERSION" ]; then
		return 0
	fi
	ric_base=${RUST_VERSION%%-*}
	ric_major=${ric_base%%.*}
	ric_rest=${ric_base#*.}
	if [ "$ric_rest" = "$ric_base" ]; then
		return 0
	fi
	ric_minor=${ric_rest%%.*}
	case $ric_major:$ric_minor in
	*[!0-9:]* | :* | *:) return 0 ;;
	esac
	if [ "$ric_major" -gt 1 ] || { [ "$ric_major" -eq 1 ] && [ "$ric_minor" -ge 94 ]; }; then
		RUST_COMPATIBLE=1
	fi
	return 0
}

# Reserve an unpredictable, same-filesystem directory for a Git clone. Git can
# clone into an existing empty directory, and the later rename into the cache is
# atomic. The fallback covers older mktemp implementations without templates.
make_source_stage() {
	mss_dest=$1
	SOURCE_STAGE=$(mktemp -d "${mss_dest}.clone.XXXXXX" 2>/dev/null || :)
	if [ -z "$SOURCE_STAGE" ]; then
		SOURCE_STAGE="${mss_dest}.clone.${TMP##*/}.$$"
		(umask 077 && mkdir "$SOURCE_STAGE") || die "cannot stage a source checkout beside $mss_dest"
	fi
}

install_source() {
	step method "source  ${C_DIM}git + cargo${C_RESET}"

	if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
		die "a source build needs Rust 1.94 or newer:
   $(rust_hint)
   then re-run this installer"
	fi
	RUST_VERSION=""
	inspect_rust
	if [ "$RUST_COMPATIBLE" != 1 ]; then
		die "a source build needs Rust 1.94 or newer (found ${RUST_VERSION:-unknown}):
	   $(rust_hint)
	   then re-run this installer"
	fi
	command -v git >/dev/null 2>&1 || die "a source build needs git"
	if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1 &&
		! command -v clang >/dev/null 2>&1; then
		die "a source build needs a C/C++ toolchain (cc, gcc, or clang)"
	fi

	is_ref=""
	if [ -n "$OPT_VERSION" ]; then
		is_ref="v$OPT_VERSION"
	elif [ -n "$VERSION" ]; then
		# Auto mode may already have resolved the release before discovering that
		# this platform has no archive. Reuse it instead of making another request.
		is_ref="v$VERSION"
	else
		[ -n "$DOWNLOADER" ] || find_downloader
		is_latest=$(resolve_latest || :)
		[ -n "$is_latest" ] || die "could not work out the latest source release; re-run or specify --version"
		is_ref=$is_latest
	fi
	VERSION=${is_ref#v}

	is_have=$(installed_version "$INSTALL_DIR/$BIN" || :)
	if [ "$OPT_FORCE" = 0 ] && [ -n "$is_have" ] && [ "$is_have" = "$VERSION" ]; then
		INSTALLED="$INSTALL_DIR/$BIN"
		ok "up to date" "$INSTALLED  ${C_DIM}$VERSION${C_RESET}"
		return 0
	fi

	is_src="${XDG_CACHE_HOME:-$HOME/.cache}/atomdrift/scan"
	mkdir -p "$(dirname "$is_src")" || die "cannot create $(dirname "$is_src")"

	# The analysis stack is large; the target directory wants about 10 GB.
	is_free=$(df -Pk "$(dirname "$is_src")" 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')
	case $is_free in
	'' | *[!0-9]*) : ;;
	*) [ "$is_free" -lt 10 ] && warn "only ${is_free} GB free at $is_src — a source build wants about 10 GB" ;;
	esac

	is_url="https://github.com/$REPO.git"
	is_present=0
	is_repair=0
	if [ -e "$is_src" ] || [ -L "$is_src" ]; then
		is_present=1
	fi
	if [ -d "$is_src/.git" ] || [ -f "$is_src/.git" ]; then
		is_origin=$(git -C "$is_src" remote get-url origin 2>/dev/null || :)
		if [ "$is_origin" != "$is_url" ]; then
			warn "cached source checkout has an unexpected origin — replacing it"
			is_repair=1
		else
			step checkout "updating $is_src"
			if ! git -C "$is_src" fetch --quiet --depth 1 origin "$is_ref"; then
				warn "cached source checkout could not be fetched — replacing it"
				is_repair=1
			elif ! git -C "$is_src" checkout --quiet --force FETCH_HEAD; then
				warn "cached source checkout could not be reset — replacing it"
				is_repair=1
			fi
		fi
	elif [ "$is_present" = 1 ]; then
		is_repair=1
	fi

	if [ "$is_repair" = 1 ]; then
		# Clone beside the old cache first so another network failure leaves it
		# available, then swap the completed checkout into place.
		make_source_stage "$is_src"
		is_stage=$SOURCE_STAGE
		is_old="${is_stage}.old"
		step checkout "repairing $is_src"
		git clone --quiet --depth 1 --branch "$is_ref" "$is_url" "$is_stage" || {
			rm -rf "$is_stage"
			SOURCE_STAGE=""
			die "cannot clone $REPO at $is_ref"
		}
		SOURCE_OLD=$is_old
		SOURCE_DEST=$is_src
		mv "$is_src" "$is_old" || {
			SOURCE_OLD=""
			SOURCE_DEST=""
			rm -rf "$is_stage"
			SOURCE_STAGE=""
			die "cannot replace incomplete checkout at $is_src"
		}
		if mv "$is_stage" "$is_src"; then
			SOURCE_STAGE=""
			if ! rm -rf "$is_old"; then
				warn "old source cache remains at $is_old"
			fi
			SOURCE_OLD=""
			SOURCE_DEST=""
		else
			if mv "$is_old" "$is_src" 2>/dev/null; then
				SOURCE_OLD=""
				SOURCE_DEST=""
			fi
			rm -rf "$is_stage"
			SOURCE_STAGE=""
			die "cannot replace incomplete checkout at $is_src"
		fi
	elif [ "$is_present" = 0 ]; then
		# Stage even the first clone: an interrupted download must not turn the
		# canonical cache path into a destination that the next run cannot use.
		make_source_stage "$is_src"
		is_stage=$SOURCE_STAGE
		step checkout "cloning $is_ref into $is_src"
		git clone --quiet --depth 1 --branch "$is_ref" "$is_url" "$is_stage" || {
			rm -rf "$is_stage"
			SOURCE_STAGE=""
			die "cannot clone $REPO at $is_ref"
		}
		mv "$is_stage" "$is_src" || {
			rm -rf "$is_stage"
			SOURCE_STAGE=""
			die "cannot place source checkout at $is_src"
		}
		SOURCE_STAGE=""
	fi

	step build "cargo build --release  ${C_DIM}(the analysis stack is large — expect minutes)${C_RESET}"
	(cd "$is_src" && cargo build --release --locked --bin "$BIN") || die "build failed in $is_src"
	is_built="$is_src/target/release/$BIN"
	[ -f "$is_built" ] || die "the build produced no $BIN"
	if [ "$(uname -s)" = Darwin ] && command -v codesign >/dev/null 2>&1; then
		codesign --force --sign - "$is_built" >/dev/null || die "cannot sign the newly built $BIN"
	fi
	"$is_built" --version >/dev/null 2>&1 || die "the newly built $BIN does not run"

	install_binary_file "$is_built"
	note "source checkout kept at $is_src — delete it to reclaim the space"
}

# ---------------------------------------------------------------------------
# Optional analysis tools
#
# None of these are required: scans work without them, with less depth on some
# file types. Report the exact package-manager command, but leave installation
# to the user rather than silently changing the machine from a piped installer.
# ---------------------------------------------------------------------------

have_tool() {
	for ht_n in $1; do
		command -v "$ht_n" >/dev/null 2>&1 && return 0
	done
	return 1
}

detect_pkg_manager() {
	PM="" PM_INSTALL=""
	if brew_works; then
		PM=brew PM_INSTALL="brew install"
		return 0
	fi
	for pm_c in apt-get dnf pacman zypper apk pkg pkgin pkg_add; do
		command -v "$pm_c" >/dev/null 2>&1 || continue
		case $pm_c in
		apt-get) PM=apt PM_INSTALL="apt-get install -y" ;;
		dnf) PM=dnf PM_INSTALL="dnf install -y" ;;
		pacman) PM=pacman PM_INSTALL="pacman -S --noconfirm --needed" ;;
		zypper) PM=zypper PM_INSTALL="zypper --non-interactive install" ;;
		apk) PM=apk PM_INSTALL="apk add" ;;
		pkg) PM=pkg PM_INSTALL="pkg install -y" ;;
		pkgin) PM=pkgin PM_INSTALL="pkgin -y install" ;;
		pkg_add) PM=pkg_add PM_INSTALL="pkg_add" ;;
		esac
		break
	done
	[ -n "$PM" ] || return 1

	return 0
}

# pkg_name TOOL — the package providing TOOL under the detected manager, empty
# when this manager has no name we trust for it.
pkg_name() {
	case "$PM:$1" in
	brew:rizin | apt:rizin | dnf:rizin | pacman:rizin | pkg:rizin) printf rizin ;;
	brew:upx | dnf:upx | pacman:upx | zypper:upx | apk:upx | pkg:upx | pkgin:upx | pkg_add:upx) printf upx ;;
	apt:upx) printf upx-ucl ;;
	brew:7z) printf sevenzip ;;
	apt:7z) printf p7zip-full ;;
	dnf:7z | pacman:7z | zypper:7z | apk:7z | pkgin:7z | pkg_add:7z) printf p7zip ;;
	pkg:7z) printf 7-zip ;;
	brew:innoextract | apt:innoextract | dnf:innoextract | pacman:innoextract | zypper:innoextract | pkg:innoextract) printf innoextract ;;
	*) : ;;
	esac
}

check_tools() {
	if [ "$OPT_TOOLS" = 0 ]; then
		return 0
	fi
	detect_pkg_manager || :
	ct_report="" ct_missing="" ct_cmds=""

	# tool : binaries that provide it
	for ct_spec in "rizin:rizin radare2 r2" "upx:upx" "7z:7zz 7z" "innoextract:innoextract"; do
		ct_tool=${ct_spec%%:*}
		ct_bins=${ct_spec#*:}

		if have_tool "$ct_bins"; then
			ct_report="$ct_report $C_GREEN$G_OK$C_RESET$ct_tool"
			continue
		fi

		ct_pkg=$(pkg_name "$ct_tool")
		ct_missing="$ct_missing $ct_tool"
		ct_report="$ct_report $C_DIM-$ct_tool$C_RESET"
		[ -n "$ct_pkg" ] && ct_cmds="$ct_cmds $ct_pkg"
	done

	step tools "${ct_report# }  ${C_DIM}optional${C_RESET}"
	if [ -n "$ct_cmds" ]; then
		ct_sudo=""
		if [ "$PM" != brew ] && [ "$(id -u)" != 0 ]; then
			ct_sudo="sudo "
		fi
		note "for deeper analysis:  $ct_sudo$PM_INSTALL$ct_cmds"
	elif [ -n "$ct_missing" ]; then
		note "optional, not packaged here:$ct_missing"
	fi
}

# ---------------------------------------------------------------------------
# Wrap-up
# ---------------------------------------------------------------------------

path_advice() {
	pa_dir=$(dirname "$INSTALLED")
	on_path "$pa_dir" && return 0

	warn "$pa_dir is not on your PATH"
	case "$(basename "${SHELL:-sh}")" in
	fish) note "fish_add_path $pa_dir" ;;
	zsh) note "echo 'export PATH=\"$pa_dir:\$PATH\"' >> ~/.zshrc" ;;
	bash)
		if [ "$(uname -s)" = Darwin ]; then
			note "echo 'export PATH=\"$pa_dir:\$PATH\"' >> ~/.bash_profile"
		else
			note "echo 'export PATH=\"$pa_dir:\$PATH\"' >> ~/.bashrc"
		fi
		;;
	*) note "export PATH=\"$pa_dir:\$PATH\"" ;;
	esac
}

shadow_check() {
	sc_found=$(current_install || :)
	[ -n "$sc_found" ] || return 0
	[ "$sc_found" != "$INSTALLED" ] || return 0
	on_path "$(dirname "$INSTALLED")" || return 0
	warn "an earlier $BIN on your PATH will still win: $sc_found"
}

summary() {
	if [ "$OPT_QUIET" = 1 ]; then
		return 0
	fi
	sm_v=$(installed_version "$INSTALLED" || printf '%s' "${VERSION:-}")
	printf '\n %s%s%s %s%s %s%s  %s%s%s\n\n' \
		"$C_GREEN" "$G_OK" "$C_RESET" "$C_BOLD" "$BIN" "$sm_v" "$C_RESET" \
		"$C_DIM" "$INSTALLED" "$C_RESET"
	printf '   %sscan a project%s     %s ./project\n' "$C_DIM" "$C_RESET" "$BIN"
	printf '   %sscan a package%s     %s purl npm/left-pad@1.3.0\n' "$C_DIM" "$C_RESET" "$BIN"
	printf '   %severything else%s    %s --help\n' "$C_DIM" "$C_RESET" "$BIN"
	printf '\n   %sThe first scan downloads the model, rule, and bloom-filter bundles.%s\n\n' \
		"$C_DIM" "$C_RESET"
}

# ---------------------------------------------------------------------------

main() {
	# Style first: parse_args can die, and die prints in colour.
	setup_style
	parse_args "$@"
	trap cleanup 0
	trap 'exit 130' INT
	trap 'exit 143' TERM HUP
	make_tmpdir

	banner
	detect_platform
	step platform "$PLATFORM"

	BREW_PREFIX=$(brew --prefix 2>/dev/null || :)

	# Homebrew is the right owner of a macOS or Linux install when it is there:
	# it holds upgrades, PATH, and the rizin and upx dependencies. It cannot
	# honour a chosen directory or version, so either option bypasses Homebrew.
	METHOD=$OPT_METHOD
	main_auto=0
	if [ "$METHOD" = auto ]; then
		main_auto=1
		METHOD=$(auto_method)
	fi
	if [ "$METHOD" = brew ]; then
		if ! brew_works; then
			if [ "$main_auto" = 1 ]; then
				warn "Homebrew is not usable here — trying a release binary"
				METHOD=binary
			else
				die "Homebrew is not usable; choose --method binary or --method source"
			fi
		elif [ -n "$OPT_DIR" ] || [ -n "$OPT_VERSION" ]; then
			die "Homebrew chooses its own directory and version; remove --dir/--version or choose another method"
		fi
	fi

	if [ "$METHOD" = brew ]; then
		install_brew || {
			if [ "$main_auto" = 1 ]; then
				warn "the Homebrew install did not finish — trying a release binary"
				METHOD=binary
			else
				die "the Homebrew install did not finish"
			fi
		}
	fi

	if [ "$METHOD" = binary ]; then
		resolve_install_dir
		install_binary || {
			if [ "$main_auto" = 1 ]; then
				METHOD=source
			else
				die "the requested binary install could not be completed"
			fi
		}
	fi

	if [ "$METHOD" = source ]; then
		[ -n "$INSTALL_DIR" ] || resolve_install_dir
		install_source
	fi

	[ -n "$INSTALLED" ] || die "the install produced no binary"
	"$INSTALLED" --version >/dev/null 2>&1 || die "$INSTALLED does not run on this machine"
	[ "$CHANGED" = 1 ] && ok installed "$INSTALLED"

	check_tools
	path_advice
	shadow_check
	summary
}

if [ "${ATOMSCAN_INSTALLER_TESTING:-0}" != 1 ]; then
	main "$@"
fi
