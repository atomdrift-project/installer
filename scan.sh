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
# build when no binary exists for the platform, then install the optional
# analysis tools that are available from the machine's configured repositories.
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
arm-unknown-linux-musleabihf
armv7-unknown-linux-musleabihf
loongarch64-unknown-linux-musl
s390x-unknown-linux-gnu
riscv64gc-unknown-linux-gnu
powerpc64le-unknown-linux-gnu
aarch64-apple-darwin
x86_64-apple-darwin
x86_64-unknown-freebsd
x86_64-unknown-openbsd
x86_64-unknown-netbsd
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
HOST_OS=""      # uname -s; detect_platform sets it, everything else reads it
SELF=""         # this machine's target triple, published or not
TARGET=""       # same, but empty unless a release actually carries it
PLATFORM=""     # human-readable platform description
METHOD=""       # resolved: brew | binary | source
VERSION=""      # version being installed, without the leading v
INSTALL_DIR=""  # directory the binary lands in
INSTALLED=""    # full path of the binary we installed
CHANGED=0       # whether this run actually replaced anything
ALREADY_CURRENT=0 # target version was already installed at the chosen path
INSTALL_ESCALATOR="" # doas | pfexec | sudo, when INSTALL_DIR needs privilege
INSTALL_PRIVILEGED=0 # whether writes to INSTALL_DIR need that escalator
PRIVILEGE_APPROVED=0 # user approved the selected escalator for this run
PRIVILEGE_DENIED=0   # do not ask repeatedly after a declined/noninteractive prompt
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
  --no-tools          Skip optional analysis tool installation (rizin, upx, ...).
  --force             Reinstall even when the target version is already there.
  --quiet             Only report problems.
  --help              Show this message.

Environment:
  ATOMSCAN_VERSION, ATOMSCAN_INSTALL_DIR, ATOMSCAN_METHOD, ATOMSCAN_NO_TOOLS
  SCAN_THEME          dark (default) or light.
  SCAN_ASCII          Force ASCII glyphs instead of the branded Unicode UI.
  NO_COLOR            Disable colour (any value).

To uninstall: delete the binary whose path this prints, or run
\`brew uninstall $TAP/scan\` if it was installed with Homebrew.

The default prefers a user-owned directory already on PATH. If none is usable,
it may install into the operating system's local PATH using doas, pfexec, or
sudo (in that preference order).
EOF
}

# valid_version STRING — true for a release identifier we are willing to place
# in a URL or a filesystem path. Applied to resolved tags as well as typed ones:
# a tag arrives from the network and has earned no more trust than an argument.
valid_version() {
	case $1 in
	'' | *[!0-9A-Za-z._+-]*) return 1 ;;
	esac
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
	if [ -n "$OPT_VERSION" ]; then
		valid_version "$OPT_VERSION" || die "invalid version '$OPT_VERSION'"
	fi
}

# ---------------------------------------------------------------------------
# Style
#
# Follow the Atomdrift website: blue for motion, toxic lime for completion,
# amber for attention, red for failure, and a readable neutral for supporting
# detail. Redirected output and NO_COLOR remain clean plain text.
# ---------------------------------------------------------------------------

setup_style() {
	ESC=$(printf '\033')
	TTY=0
	[ -t 1 ] && TTY=1

	if [ "${NO_COLOR+x}" = x ] || [ "$TTY" = 0 ] || [ "${TERM:-dumb}" = dumb ]; then
		C_RED='' C_AMBER='' C_GREEN='' C_BRAND=''
		C_DIM='' C_BOLD='' C_RESET=''
	else
		case "${SCAN_THEME:-dark}" in
		light | white)
			C_RED="${ESC}[38;2;220;38;38m" C_AMBER="${ESC}[38;2;217;119;6m"
			C_GREEN="${ESC}[38;2;74;107;15m" C_BRAND="${ESC}[38;2;37;99;235m"
			C_DIM="${ESC}[38;2;107;114;128m"
			;;
		*)
			C_RED="${ESC}[38;2;248;113;113m" C_AMBER="${ESC}[38;2;251;191;36m"
			C_GREEN="${ESC}[38;2;208;255;0m" C_BRAND="${ESC}[38;2;96;165;250m"
			C_DIM="${ESC}[38;2;161;161;170m"
			;;
		esac
		C_BOLD="${ESC}[1m" C_RESET="${ESC}[0m"
	fi

	# Friendly glyphs in UTF-8 locales, with an ASCII fallback for old consoles
	# and minimal environments.
	UTF8=0
	if [ -z "${SCAN_ASCII:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
		case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
		*[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) UTF8=1 ;;
		*) [ "$TTY" = 1 ] && UTF8=1 ;;
		esac
	fi
	if [ "$UTF8" = 1 ]; then
		G_SCAN="⚛️" G_STEP="·" G_OK="✓" G_WARN="⚠" G_ERR="✗"
	else
		G_SCAN="*" G_STEP="-" G_OK="+" G_WARN="!" G_ERR="x"
	fi
}

# step LABEL VALUE — one aligned line of progress.
step() {
	if [ "$OPT_QUIET" = 0 ]; then
		printf ' %s%s%s %s%-11s%s%s\n' "$C_BRAND" "$G_STEP" "$C_RESET" "$C_DIM" "$1" "$C_RESET" "$2"
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

gap() {
	[ "$OPT_QUIET" = 1 ] || printf '\n'
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
		"$C_BRAND" "$G_SCAN" "$C_RESET" "$C_BOLD" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Scratch space
# ---------------------------------------------------------------------------

cleanup() {
	[ -n "$TMP" ] && rm -rf "$TMP"
	if [ -n "$INSTALL_TMP" ]; then
		install_run rm -f "$INSTALL_TMP" 2>/dev/null || :
	fi
	[ -n "$SOURCE_STAGE" ] && rm -rf "$SOURCE_STAGE"
	if [ -n "$SOURCE_OLD" ]; then
		if [ -n "$SOURCE_DEST" ] && [ ! -e "$SOURCE_DEST" ] && [ ! -L "$SOURCE_DEST" ]; then
			# Interrupted mid-swap: put the previous checkout back.
			mv "$SOURCE_OLD" "$SOURCE_DEST" 2>/dev/null || :
		else
			# The new checkout is already in place, so this one is only taking
			# up several gigabytes of somebody's cache directory.
			rm -rf "$SOURCE_OLD" 2>/dev/null || :
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

# Also the one place `uname -s` is read: everything downstream consults HOST_OS,
# so the whole run agrees on one answer and spends one fork getting it.
detect_platform() {
	HOST_OS=$(uname -s 2>/dev/null || echo unknown)
	dp_arch=$(uname -m 2>/dev/null || echo unknown)
	dp_desc=""

	case $dp_arch in
	x86_64 | amd64) dp_arch=x86_64 ;;
	i86pc) dp_arch=x86_64 ;;
	aarch64 | arm64) dp_arch=aarch64 ;;
	armv6 | armv6l) dp_arch=arm ;;
	armv7 | armv7l | armv8l | armhf) dp_arch=armv7 ;;
	loongarch64) dp_arch=loongarch64 ;;
	riscv64 | riscv64gc) dp_arch=riscv64gc ;;
	ppc64le | powerpc64le) dp_arch=powerpc64le ;;
	esac

	case $HOST_OS in
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
		# The ARM32 and LoongArch release artifacts are static musl binaries.
		# Select them on any Linux libc: this is both more portable for embedded
		# systems (where uClibc remains common) and avoids imposing the cross
		# image's glibc floor. ARM32 targets the standard hard-float ABI.
		case $dp_arch in
		arm | armv7) SELF="$dp_arch-unknown-linux-musleabihf" ;;
		loongarch64) SELF="$dp_arch-unknown-linux-musl" ;;
		*) SELF="$dp_arch-unknown-linux-$dp_libc" ;;
		esac
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
		SELF="$dp_arch-unknown-$(printf '%s' "$HOST_OS" | tr '[:upper:]' '[:lower:]')"
		dp_desc="$HOST_OS $(uname -r 2>/dev/null || :)"
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
		rl_tag=${rl_final##*/tag/}
		valid_version "$rl_tag" || return 1
		printf '%s' "$rl_tag"
		return 0
		;;
	esac

	http_get "https://api.github.com/repos/$REPO/releases/latest" "$TMP/latest.json" 2>/dev/null || return 1
	rl_tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/latest.json" | head -n 1)
	valid_version "$rl_tag" || return 1
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

# Verify the signed release manifest with a standard Sigstore bundle. Tag-push
# releases carry the tag identity; a recovery publish is deliberately limited
# to main by release.yml and carries that identity instead.
verify_sigstore_manifest() {
	command -v cosign >/dev/null 2>&1 || return 1
	vsm_manifest=$1 vsm_bundle=$2 vsm_version=$3
	vsm_tag="https://github.com/$REPO/.github/workflows/release.yml@refs/tags/v$vsm_version"
	vsm_main="https://github.com/$REPO/.github/workflows/release.yml@refs/heads/main"
	for vsm_identity in "$vsm_tag" "$vsm_main"; do
		if cosign verify-blob "$vsm_manifest" \
			--bundle "$vsm_bundle" \
			--certificate-identity "$vsm_identity" \
			--certificate-oidc-issuer https://token.actions.githubusercontent.com \
			>/dev/null 2>&1; then
			printf '%s\n' "$vsm_identity"
			return 0
		fi
	done
	return 1
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

# install_run COMMAND... — run one step of a write into INSTALL_DIR, escalated
# when that directory needs it. install_binary_file and the exit trap both write
# there, and this is the single place that decides how.
install_run() {
	if [ "$INSTALL_PRIVILEGED" = 1 ] && [ -n "$INSTALL_ESCALATOR" ]; then
		"$INSTALL_ESCALATOR" "$@"
	else
		"$@"
	fi
}

quote_arg() {
	qa_escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
	printf "'%s'" "$qa_escaped"
}

# Ask through the controlling terminal because stdin contains scan.sh when the
# documented `curl | sh` form is used. Approval is remembered for this run;
# every later privileged operation is still printed before it executes.
approve_privilege() {
	ap_command=$1
	if [ "$PRIVILEGE_APPROVED" = 1 ]; then
		step privilege "$ap_command"
		return 0
	fi
	[ "$PRIVILEGE_DENIED" = 0 ] || return 1
	if ! (: </dev/tty) 2>/dev/null; then
		warn "privilege is required, but no interactive terminal is available"
		note "command not run:  $ap_command"
		PRIVILEGE_DENIED=1
		return 1
	fi
	printf ' %s%s%s %sPermission needed%s\n   %s\n   Allow %s for this install? [y/N] ' \
		"$C_AMBER" "$G_WARN" "$C_RESET" "$C_BOLD" "$C_RESET" "$ap_command" "$INSTALL_ESCALATOR" >/dev/tty
	IFS= read -r ap_answer </dev/tty || ap_answer=""
	case $ap_answer in
	[yY] | [yY][eE][sS])
		PRIVILEGE_APPROVED=1
		gap
		return 0
		;;
	*)
		PRIVILEGE_DENIED=1
		warn "permission declined — no privileged changes were made"
		return 1
		;;
	esac
}

# use_install_dir DIR [ALLOW_PRIVILEGE] — use DIR directly when possible,
# otherwise optionally request permission for the preferred privilege tool.
use_install_dir() {
	uid_dir=$1 uid_privilege=${2:-1}
	if mkdir -p "$uid_dir" 2>/dev/null && writable_dir "$uid_dir"; then
		INSTALL_DIR=$uid_dir
		INSTALL_PRIVILEGED=0
		INSTALL_ESCALATOR=""
		return 0
	fi

	[ "$uid_privilege" = 1 ] || return 1
	[ "$(id -u)" = 0 ] && return 1
	find_escalator || return 1
	uid_cmd=$INSTALL_ESCALATOR
	# Selecting an existing protected directory is read-only. Defer the prompt
	# until install_binary_file has a file to write; an already-current rerun
	# will then finish without asking for unused privilege.
	if [ -d "$uid_dir" ]; then
		INSTALL_DIR=$uid_dir
		INSTALL_PRIVILEGED=1
		return 0
	fi
	uid_display="$uid_cmd mkdir -p $(quote_arg "$uid_dir")"
	[ "$PRIVILEGE_APPROVED" = 1 ] || gap
	approve_privilege "$uid_display" || return 1
	if "$uid_cmd" mkdir -p "$uid_dir" && [ -d "$uid_dir" ]; then
		INSTALL_DIR=$uid_dir
		INSTALL_PRIVILEGED=1
		return 0
	fi
	warn "$uid_cmd could not prepare $uid_dir"
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
	SunOS) printf '%s\n' '/opt/atomdrift/bin' ;;
	Darwin) printf '%s\n' '/usr/local/bin /opt/local/bin' ;;
	NetBSD) printf '%s\n' '/usr/pkg/bin /usr/local/bin' ;;
	*) printf '%s\n' '/usr/local/bin' ;;
	esac
	return 0
}

# Try OS-conventional local directories before following raw PATH order. Every
# REQUIRE_PATH defaults to 1. Non-Linux systems can deliberately select their
# native application prefix even when the user still needs PATH advice.
use_native_path_dir() {
	unpd_privilege=${1:-1}
	unpd_require_path=${2:-1}
	unpd_dirs=$(native_path_dirs "$HOST_OS")
	for unpd_dir in $unpd_dirs; do
		if [ "$unpd_require_path" = 1 ]; then on_path "$unpd_dir" || continue; fi
		managed_path_dir "$unpd_dir" && continue
		if use_install_dir "$unpd_dir" "$unpd_privilege"; then
			return 0
		fi
	done
	return 1
}

# Follow PATH order without word-splitting directory names. Native local
# directories were already attempted above; core directories such as /usr/bin
# are reached only here.
#
# The trailing colon means every entry is followed by one, so each pass consumes
# exactly one and the loop ends when nothing is left. Consuming before any test
# is what keeps `continue` safe to write here.
use_any_path_dir() {
	uap_privilege=${1:-1}
	uap_rest="$PATH:"
	while [ -n "$uap_rest" ]; do
		uap_dir=${uap_rest%%:*}
		uap_rest=${uap_rest#*:}

		# Relative and empty entries are unsafe escalation targets.
		case $uap_dir in /*) ;; *) continue ;; esac
		managed_path_dir "$uap_dir" && continue
		use_install_dir "$uap_dir" "$uap_privilege" && return 0
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

# Recognize an exact current install without requiring its directory to be
# writable. An idempotent rerun should not need Rust or privilege merely to do
# nothing.
use_current_if_exact() {
	[ "$OPT_FORCE" = 0 ] || return 1
	[ -n "$VERSION" ] || return 1
	ucie_path="" ucie_from_path=0
	if [ -n "$OPT_DIR" ]; then
		ucie_path="$OPT_DIR/$BIN"
	elif [ -n "$INSTALL_DIR" ]; then
		ucie_path="$INSTALL_DIR/$BIN"
	else
		ucie_path=$(current_install || :)
		ucie_from_path=1
	fi
	[ -n "$ucie_path" ] || return 1
	[ "$(installed_version "$ucie_path" || :)" = "$VERSION" ] || return 1

	ucie_dir=$(dirname "$ucie_path")
	if [ "$ucie_from_path" = 1 ]; then
		if [ -n "$BREW_PREFIX" ] && [ "${ucie_dir#"$BREW_PREFIX"}" != "$ucie_dir" ]; then
			return 1
		fi
		if [ "$HOST_OS" != Linux ]; then
			case $ucie_dir in /bin | /sbin | /usr/bin | /usr/sbin) return 1 ;; esac
		fi
	fi

	INSTALL_DIR=$ucie_dir
	INSTALLED=$ucie_path
	ALREADY_CURRENT=1
	return 0
}

resolve_install_dir() {
	INSTALL_PRIVILEGED=0
	INSTALL_ESCALATOR=""
	if [ -n "$OPT_DIR" ]; then
		if use_install_dir "$OPT_DIR"; then
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
		rid_system_core=0
		if [ -n "$BREW_PREFIX" ] && [ "${rid_dir#"$BREW_PREFIX"}" != "$rid_dir" ]; then
			rid_brewed=1
		fi
		# Linux distributions may legitimately own /usr/bin installs. On the
		# other Unix families, migrate toward the native local/application prefix
		# instead of perpetuating an old system-directory choice.
		if [ "$HOST_OS" != Linux ]; then
			case $rid_dir in /bin | /sbin | /usr/bin | /usr/sbin) rid_system_core=1 ;; esac
		fi
		if [ "$rid_brewed" = 0 ] && [ "$rid_system_core" = 0 ]; then
			if use_install_dir "$rid_dir"; then
				return 0
			fi
			die "the existing $rid_cur cannot be upgraded in place
   Re-run with --dir to choose a different destination, or install doas, pfexec, or sudo."
		fi
	fi

	# A PATH entry wins even when its directory has not been created yet. This
	# keeps a first install where the user already said they want binaries,
	# instead of escalating to a system directory just because ~/.local/bin
	# happens not to exist yet.
	if [ -n "${HOME:-}" ]; then
		if [ "$HOST_OS" = Haiku ]; then
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

	# Linux honors PATH throughout. Elsewhere, prefer the native application
	# prefix even when it needs PATH advice; never fall through to /usr/bin.
	if [ "$HOST_OS" = Linux ]; then
		use_native_path_dir 0 1 && return 0
		use_any_path_dir 0 && return 0
		use_native_path_dir 1 1 && return 0
		use_any_path_dir 1 && return 0
	else
		use_native_path_dir 0 0 && return 0
		use_any_path_dir 0 && return 0
		use_native_path_dir 1 0 && return 0
	fi
	die "no usable absolute directory was found on PATH
   Add \$HOME/.local/bin or \$HOME/bin to PATH, or choose one with --dir."
}

# ibf_fail MESSAGE — die without leaving a staging file behind. Reads ibf_tmp,
# which install_binary_file sets: shell has no locals, so the shared ibf_ prefix
# is the convention marking who owns the variable.
ibf_fail() {
	install_run rm -f "$ibf_tmp" 2>/dev/null || :
	die "$1"
}

# ibf_approve COMMAND [LABEL] — clear a privileged command with the user, or
# die. Approval given earlier in this run is not asked for again, but every
# privileged command is still printed before it runs. LABEL stands in for the
# progress line when COMMAND is a chain too long to echo in full.
ibf_approve() {
	if [ "$PRIVILEGE_APPROVED" = 1 ]; then
		step privilege "${2:-$1}"
		return 0
	fi
	gap
	approve_privilege "$1" || die "permission is required to install $ibf_dest"
}

# install_binary_file SRC — install SRC at INSTALL_DIR/BIN with mode 0755.
#
# Whichever route is taken, an interrupted install leaves either the old binary
# or the new one in place, never a partial file.
install_binary_file() {
	ibf_dest="$INSTALL_DIR/$BIN"
	ibf_tmp="$INSTALL_DIR/.$BIN.new.$$"
	# Names the escalator in a diagnostic, and is empty when there is not one.
	ibf_via=""

	if [ "$INSTALL_PRIVILEGED" = 1 ]; then
		ibf_via=" with $INSTALL_ESCALATOR"

		# BSD and macOS install(1) do the same-directory copy and atomic rename
		# themselves; only the flag that asks for it differs. GNU install has no
		# such mode, but one direct operation still beats staging by hand, so
		# Linux uses it flagless. BusyBox and toybox systems, which may have no
		# install applet at all, fall through to the staging path below.
		ibf_flag=""
		case $HOST_OS in
		Darwin | FreeBSD | OpenBSD) ibf_flag=-S ;;
		NetBSD) ibf_flag=-r ;;
		esac
		if { [ -n "$ibf_flag" ] || [ "$HOST_OS" = Linux ] || [ "$HOST_OS" = GNU ]; } &&
			command -v install >/dev/null 2>&1; then
			ibf_approve "$INSTALL_ESCALATOR install${ibf_flag:+ $ibf_flag} -m 755 $(quote_arg "$1") $(quote_arg "$ibf_dest")"
			install_run install ${ibf_flag:+"$ibf_flag"} -m 755 "$1" "$ibf_dest" ||
				die "cannot install $ibf_dest$ibf_via"
			INSTALLED=$ibf_dest
			CHANGED=1
			return 0
		fi

		ibf_approve \
			"$INSTALL_ESCALATOR cp $(quote_arg "$1") $(quote_arg "$ibf_tmp") && $INSTALL_ESCALATOR chmod 755 $(quote_arg "$ibf_tmp") && $INSTALL_ESCALATOR mv -f $(quote_arg "$ibf_tmp") $(quote_arg "$ibf_dest")" \
			"$INSTALL_ESCALATOR  ${C_DIM}(atomic binary install)${C_RESET}"
	fi

	# Stage inside the destination directory so the rename that follows stays on
	# one filesystem, where it is atomic.
	INSTALL_TMP=$ibf_tmp
	install_run cp "$1" "$ibf_tmp" || ibf_fail "cannot write to $INSTALL_DIR$ibf_via"
	install_run chmod 755 "$ibf_tmp" || ibf_fail "cannot make $ibf_tmp executable"
	install_run mv -f "$ibf_tmp" "$ibf_dest" || ibf_fail "cannot replace $ibf_dest$ibf_via"

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

# Homebrew installs to a fixed prefix and leaves exporting it to a profile
# snippet, which a non-login `curl | sh` never reads. Look in the three prefixes
# it uses before concluding there is no Homebrew: on an image-based system like
# Bluefin, an unseen Homebrew would demote us to rpm-ostree, which cannot
# install anything without a reboot. The prefix is appended rather than
# prepended — brew itself is all we are missing, and every other tool this run
# already resolved should keep the priority it had.
brew_works() {
	if ! command -v brew >/dev/null 2>&1; then
		for bw_dir in /opt/homebrew/bin /home/linuxbrew/.linuxbrew/bin "${HOME:-}/.linuxbrew/bin"; do
			[ -x "$bw_dir/brew" ] || continue
			PATH="$PATH:$bw_dir"
			export PATH
			break
		done
	fi
	command -v brew >/dev/null 2>&1 && brew --version >/dev/null 2>&1
}

# Resolve Homebrew's root into BREW_PREFIX, empty when there is no Homebrew.
#
# The order here is the whole point, which is why it is a function and not two
# lines in main: brew_works is what puts an unexported Homebrew back on PATH, so
# reading the prefix first would report "no Homebrew" on exactly the machines
# that repair exists for. An empty BREW_PREFIX then stops managed_path_dir from
# recognising Homebrew's directories — the very directories the repair has just
# added to PATH, and so to the list of places we might install.
find_brew_prefix() {
	BREW_PREFIX=""
	brew_works || return 1
	BREW_PREFIX=$(brew --prefix 2>/dev/null || :)
	[ -n "$BREW_PREFIX" ]
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
	case $HOST_OS in
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
			ALREADY_CURRENT=1
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

	ib_name="$BIN-$VERSION-$TARGET.tar.gz"
	ib_base="https://github.com/$REPO/releases/download/v$VERSION"

	if ! http_ok "$ib_base/$ib_name"; then
		warn "release v$VERSION publishes no binary for $TARGET"
		return 1
	fi
	use_current_if_exact && return 0

	# Do not prepare or elevate into a destination until the release asset this
	# path intends to install is known to exist.
	[ -n "$INSTALL_DIR" ] || resolve_install_dir

	# Idempotence: an install that is already what we would install is done.
	ib_have=$(installed_version "$INSTALL_DIR/$BIN" || :)
	if [ "$OPT_FORCE" = 0 ] && [ "$ib_have" = "$VERSION" ]; then
		INSTALLED="$INSTALL_DIR/$BIN"
		ALREADY_CURRENT=1
		return 0
	fi

	step method "release binary  ${C_DIM}$TARGET${C_RESET}"
	download "$ib_base/$ib_name" "$TMP/$ib_name" "$ib_name" || {
		warn "download failed"
		return 1
	}

	http_get "$ib_base/SHA256SUMS" "$TMP/SHA256SUMS" ||
		die "release v$VERSION publishes no SHA256SUMS — refusing to install unverified"
	ib_sigstore_identity=''
	if command -v cosign >/dev/null 2>&1 &&
		http_get "$ib_base/SHA256SUMS.sigstore.json" "$TMP/SHA256SUMS.sigstore.json" 2>/dev/null; then
		ib_sigstore_identity=$(verify_sigstore_manifest \
			"$TMP/SHA256SUMS" "$TMP/SHA256SUMS.sigstore.json" "$VERSION") ||
			die "SHA256SUMS has an invalid Sigstore signature — refusing to install"
	fi
	ib_digest=$(verify_checksum "$TMP/$ib_name" "$TMP/SHA256SUMS" "$ib_name") ||
		die "$ib_name failed verification — refusing to install"

	ib_attested=0
	verify_provenance "$TMP/$ib_name" && ib_attested=1
	if [ -n "$ib_sigstore_identity" ] && [ "$ib_attested" = 1 ]; then
		ok verified "sha256 $ib_digest  ${C_DIM}·  sigstore signed  ·  provenance attested${C_RESET}"
	elif [ -n "$ib_sigstore_identity" ]; then
		ok verified "sha256 $ib_digest  ${C_DIM}·  sigstore signed${C_RESET}"
	elif [ "$ib_attested" = 1 ]; then
		ok verified "sha256 $ib_digest  ${C_DIM}·  provenance attested${C_RESET}"
	else
		ok verified "sha256 $ib_digest"
	fi
	[ -z "$ib_sigstore_identity" ] || note "sigstore signer  $ib_sigstore_identity"

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
	elif [ "$HOST_OS" = Darwin ] && brew_works; then
		if command -v rustc >/dev/null 2>&1; then printf 'brew upgrade rust'; else printf 'brew install rust'; fi
	elif [ "$HOST_OS" = FreeBSD ] && command -v pkg >/dev/null 2>&1; then
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
	use_current_if_exact && return 0

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

	# Source prerequisites and the requested release are now known-good. Only at
	# this point may destination preparation ask for privilege or change a prefix.
	[ -n "$INSTALL_DIR" ] || resolve_install_dir
	is_have=$(installed_version "$INSTALL_DIR/$BIN" || :)
	if [ "$OPT_FORCE" = 0 ] && [ -n "$is_have" ] && [ "$is_have" = "$VERSION" ]; then
		INSTALLED="$INSTALL_DIR/$BIN"
		ALREADY_CURRENT=1
		return 0
	fi

	# Guarded because a service manager or `env -i` can leave HOME unset, and
	# under `set -u` a bare $HOME would abort with a shell error rather than
	# something a reader could act on.
	is_cache=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
	[ -n "$is_cache" ] || die "a source build needs a cache directory; set HOME or XDG_CACHE_HOME"
	is_src="$is_cache/atomdrift/scan"
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
	if [ "$HOST_OS" = Darwin ] && command -v codesign >/dev/null 2>&1; then
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
# file types. Install only packages advertised by the configured repositories;
# failed queries and unknown package names are treated as unavailable.
# ---------------------------------------------------------------------------

have_tool() {
	for ht_n in $1; do
		command -v "$ht_n" >/dev/null 2>&1 && return 0
	done
	return 1
}

# emerge and rpm-ostree are detected but never run — see install_tool_packages.
# They earn their place here anyway: knowing the manager is what lets us name
# packages the machine can actually resolve.
detect_pkg_manager() {
	PM="" PM_INSTALL=""
	if brew_works; then
		PM=brew PM_INSTALL="brew install"
		return 0
	fi
	# rpm-ostree comes before dnf: an image-based system may carry both, but its
	# /usr is read-only, so dnf is the wrong half of the pair to reach for.
	for pm_c in rpm-ostree apt-get dnf yum pacman zypper apk xbps-install emerge pkg pkgin pkg_add port; do
		command -v "$pm_c" >/dev/null 2>&1 || continue
		case $pm_c in
		rpm-ostree) PM=rpm-ostree PM_INSTALL="rpm-ostree install" ;;
		apt-get) PM=apt PM_INSTALL="apt-get install -y" ;;
		dnf) PM=dnf PM_INSTALL="dnf install -y" ;;
		yum) PM=yum PM_INSTALL="yum install -y" ;;
		pacman) PM=pacman PM_INSTALL="pacman -S --noconfirm --needed" ;;
		zypper) PM=zypper PM_INSTALL="zypper --non-interactive install" ;;
		apk) PM=apk PM_INSTALL="apk add" ;;
		xbps-install) PM=xbps PM_INSTALL="xbps-install -Sy" ;;
		emerge) PM=emerge PM_INSTALL="emerge" ;;
		pkg)
			# Solaris/illumos `pkg` is IPS, not FreeBSD pkg(8); its package
			# names and flags are unrelated. Prefer pkgsrc's pkgin when present.
			case $HOST_OS in FreeBSD | DragonFly) PM=pkg PM_INSTALL="pkg install -y" ;; *) continue ;; esac
			;;
		pkgin) PM=pkgin PM_INSTALL="pkgin -y install" ;;
		pkg_add)
			# OpenBSD pkg_add. NetBSD ships the same command name from a
			# different pkg_install: there `pkg_info -Q` prints a build variable
			# instead of searching, and pkg_add needs a hand-set PKG_PATH — so
			# pkgin, checked just above, is NetBSD's supported route.
			case $HOST_OS in OpenBSD) PM=pkg_add PM_INSTALL="pkg_add" ;; *) continue ;; esac
			;;
		port)
			# MacPorts, reached only when there is no Homebrew. Guarded because
			# `port` is a common enough name elsewhere.
			case $HOST_OS in Darwin) PM=port PM_INSTALL="port install" ;; *) continue ;; esac
			;;
		esac
		break
	done
	[ -n "$PM" ]
}

# True only when the configured repositories currently advertise PACKAGE.
# A failed/offline query is conservative: do not suggest or attempt an install.
package_available() {
	pa_pkg=$1
	case $PM in
	brew) brew info --formula "$pa_pkg" >/dev/null 2>&1 ;;
	apt) apt-cache show "$pa_pkg" >/dev/null 2>&1 ;;
	dnf) dnf --quiet info "$pa_pkg" >/dev/null 2>&1 ;;
	yum) yum --quiet info "$pa_pkg" >/dev/null 2>&1 ;;
	# `rpm-ostree search` prints "name : summary" under a matched-by heading,
	# and only from 2023.6 onward. An older build prints nothing we match, which
	# lands on the same conservative answer as a package that is not there.
	rpm-ostree) rpm-ostree search "$pa_pkg" 2>/dev/null | grep -q "^${pa_pkg} : " ;;
	pacman) pacman -Si "$pa_pkg" >/dev/null 2>&1 ;;
	zypper) zypper --non-interactive info "$pa_pkg" >/dev/null 2>&1 ;;
	apk) apk search -e "$pa_pkg" 2>/dev/null | grep -q "^${pa_pkg}-[0-9]" ;;
	xbps) xbps-query -R --property=pkgver "$pa_pkg" 2>/dev/null | grep -q "^${pa_pkg}-[0-9]" ;;
	# portageq is part of portage itself, so it is there whenever emerge is. It
	# prints the best visible atom, e.g. app-arch/upx-4.2.4.
	emerge) portageq best_visible / "$pa_pkg" 2>/dev/null | grep -q "^${pa_pkg}-[0-9]" ;;
	pkg) pkg search -q -x "^${pa_pkg}-[0-9]" 2>/dev/null | grep -q . ;;
	pkgin) pkgin -n search "^${pa_pkg}-[0-9]" 2>/dev/null | grep -q "^${pa_pkg}-" ;;
	pkg_add) pkg_info -Q "$pa_pkg" 2>/dev/null | grep -q "^${pa_pkg}-" ;;
	# --index answers from the local port index, so this stays offline and fast.
	port) port -q info --index --name "$pa_pkg" >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# pkg_names TOOL — preferred packages that can provide TOOL under the detected
# manager. The first one advertised by the active repositories wins.
pkg_names() {
	[ -n "$PM" ] || return 1
	case "$PM:$1" in
	# Rizin, falling back to radare2 on the trees that never picked rizin up.
	zypper:rizin | pkgin:rizin) printf radare2 ;;
	emerge:rizin) printf 'dev-util/rizin dev-util/radare2' ;;
	*:rizin) printf 'rizin radare2' ;;
	apt:upx) printf upx-ucl ;;
	emerge:upx) printf app-arch/upx ;;
	*:upx) printf upx ;;
	# Upstream 7-Zip (`7zz`) first, p7zip (`7z`) as fallback: p7zip is a fork of
	# 7-Zip 16.02 with no APFS handler, so .dmg contents go unscanned. Listing
	# both is safe — the caller takes the first name the repos advertise.
	brew:7z) printf sevenzip ;;
	apt:7z) printf '7zip p7zip-full' ;;
	pkg:7z) printf '7-zip p7zip' ;;
	emerge:7z) printf 'app-arch/7zip app-arch/p7zip' ;;
	*:7z) printf '7zip p7zip' ;;
	emerge:innoextract) printf app-arch/innoextract ;;
	*:innoextract) printf innoextract ;;
	*) : ;;
	esac
}

install_tool_packages() {
	[ "$#" -gt 0 ] || return 0
	itp_display="$PM_INSTALL $*"

	# Two managers we detect but never drive: Portage would build every package
	# from source, and rpm-ostree only stages an image the next boot picks up.
	# Name the command and let the reader choose the moment.
	case $PM in
	emerge)
		note "these build from source; run when you have the time:  $itp_display"
		return 1
		;;
	rpm-ostree)
		note "these need a reboot to take effect:  $itp_display"
		return 1
		;;
	esac

	# Homebrew installs under its own prefix and refuses to run as root. Every
	# other manager writes to system paths we may not already hold.
	itp_sudo=""
	if [ "$PM" != brew ] && [ "$(id -u)" != 0 ]; then
		[ -n "$INSTALL_ESCALATOR" ] || find_escalator || {
			note "available tools not installed:  $itp_display"
			return 1
		}
		itp_sudo=$INSTALL_ESCALATOR
		itp_display="$itp_sudo $itp_display"
		approve_privilege "$itp_display" || {
			note "tools skipped; run later:  $itp_display"
			return 1
		}
	fi

	step tools "$itp_display"
	# Deliberately unquoted: PM_INSTALL is a fixed command line chosen above,
	# and an empty itp_sudo has to vanish rather than become an argument.
	# shellcheck disable=SC2086 # installer-owned words, as are the package names.
	$itp_sudo $PM_INSTALL "$@"
}

check_tools() {
	if [ "$OPT_TOOLS" = 0 ]; then
		return 0
	fi
	gap
	detect_pkg_manager || :
	ct_ready="" ct_unavailable="" ct_not_installed="" ct_packages="" ct_installing=""

	# tool : binaries that provide it
	for ct_spec in "rizin:rizin radare2 r2" "upx:upx" "7z:7zz 7z" "innoextract:innoextract"; do
		ct_tool=${ct_spec%%:*}
		ct_bins=${ct_spec#*:}

		if have_tool "$ct_bins"; then
			ct_ready="$ct_ready $ct_tool"
			continue
		fi

		ct_pkg=""
		ct_candidates=$(pkg_names "$ct_tool")
		for ct_candidate in $ct_candidates; do
			if package_available "$ct_candidate"; then
				ct_pkg=$ct_candidate
				break
			fi
		done
		if [ -n "$ct_pkg" ]; then
			ct_packages="$ct_packages $ct_pkg"
			ct_installing="$ct_installing $ct_tool"
		else
			ct_unavailable="$ct_unavailable $ct_tool"
		fi
	done

	if [ -n "$ct_packages" ]; then
		# shellcheck disable=SC2086 # package names are installer-owned words.
		if install_tool_packages $ct_packages; then
			ct_ready="$ct_ready$ct_installing"
		else
			ct_not_installed="$ct_not_installed$ct_installing"
		fi
	fi
	if [ -n "$ct_ready" ]; then
		ok tools "${ct_ready# }  ${C_DIM}deeper analysis ready${C_RESET}"
	else
		step tools "core scanner ready"
	fi
	if [ -n "$ct_unavailable" ]; then
		# Only claim the repositories were consulted when there was something to
		# consult; with no package manager we never asked anyone anything.
		if [ -n "$PM" ]; then
			note "not available from configured repositories:${ct_unavailable}"
		else
			note "no package manager found, so these went unchecked:${ct_unavailable}"
		fi
	fi
	if [ -n "$ct_not_installed" ]; then
		note "available, but not installed:${ct_not_installed}"
	fi
	seven_zip_advice
}

# Warn when the only 7-Zip is p7zip's `7z`. It satisfies the check above, so
# nothing else would mention it — but without an APFS handler a .dmg yields one
# opaque blob and its contents go unscanned.
seven_zip_advice() {
	[ "$HOST_OS" = Windows_NT ] && return 0
	have_tool 7zz && return 0
	have_tool 7z || return 0

	sza_pkg=$(pkg_names 7z | cut -d' ' -f1)
	gap
	warn "only p7zip's '7z' found — upstream 7-Zip ('7zz') also reads APFS/.dmg"
	[ -n "$sza_pkg" ] && [ -n "$PM_INSTALL" ] && note "$PM_INSTALL $sza_pkg"
}

# ---------------------------------------------------------------------------
# Wrap-up
# ---------------------------------------------------------------------------

path_advice() {
	pa_dir=$(dirname "$INSTALLED")
	on_path "$pa_dir" && return 0

	gap
	warn "$pa_dir is not on your PATH"
	case "$(basename "${SHELL:-sh}")" in
	fish) note "fish_add_path $pa_dir" ;;
	zsh) note "echo 'export PATH=\"$pa_dir:\$PATH\"' >> ~/.zshrc" ;;
	bash)
		if [ "$HOST_OS" = Darwin ]; then
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
	gap
	warn "an earlier $BIN on your PATH will still win: $sc_found"
}

summary() {
	if [ "$OPT_QUIET" = 1 ]; then
		return 0
	fi
	sm_v=$(installed_version "$INSTALLED" || printf '%s' "${VERSION:-}")
	sm_current=""
	[ "$ALREADY_CURRENT" = 1 ] && sm_current="  ${C_DIM}· already current${C_RESET}"
	printf '\n %s%s%s %sReady to scan%s  %s %s%s\n' \
		"$C_GREEN" "$G_OK" "$C_RESET" "$C_BOLD" "$C_RESET" "$BIN" "$sm_v" "$sm_current"
	printf '   %s%s%s\n\n' "$C_DIM" "$INSTALLED" "$C_RESET"
	printf '   %sTry it%s\n' "$C_BRAND" "$C_RESET"
	printf '   %sproject%s     %s ./project\n' "$C_DIM" "$C_RESET" "$BIN"
	printf '   %spackage%s     %s purl npm/left-pad@1.3.0\n' "$C_DIM" "$C_RESET" "$BIN"
	printf '   %sexplore%s     %s --help\n' "$C_DIM" "$C_RESET" "$BIN"
	printf '\n   %sFirst scan fetches the model, rule, and bloom-filter bundles.%s\n\n' \
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

	find_brew_prefix || :

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
		if [ -z "$TARGET" ]; then
			warn "no published binary for this platform"
			if [ "$main_auto" = 1 ]; then
				METHOD=source
			else
				die "the requested binary install could not be completed"
			fi
		else
			install_binary || {
				if [ "$main_auto" = 1 ]; then
					METHOD=source
				else
					die "the requested binary install could not be completed"
				fi
			}
		fi
	fi

	if [ "$METHOD" = source ]; then
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
