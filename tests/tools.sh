#!/bin/sh
# Optional analysis tools are installed only when the active repositories know
# about them. Package manager detection also has to disambiguate several
# commands that share a name across platforms: Solaris IPS `pkg` is not FreeBSD
# pkg(8), and NetBSD `pkg_add` is not OpenBSD's.

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

fake_bin="$TMP/bin"
mkdir -p "$fake_bin"

# expect_pm EXPECTED OS COMMAND... — with only COMMAND... on PATH and HOST_OS
# set to OS, detect_pkg_manager must settle on EXPECTED. An empty EXPECTED
# means no manager may be selected at all. Homebrew is stubbed out because it
# outranks everything, and CI runners carry it.
pm_case=0
expect_pm() {
	ep_expected=$1 ep_os=$2
	shift 2
	pm_case=$((pm_case + 1))
	ep_dir="$TMP/pm$pm_case"
	mkdir -p "$ep_dir"
	for ep_cmd in "$@"; do
		printf '%s\n' '#!/bin/sh' 'exit 0' >"$ep_dir/$ep_cmd"
		chmod 755 "$ep_dir/$ep_cmd"
	done
	# shellcheck disable=SC2030,SC2031 # PATH changes are intentionally subshell-local.
	(
		PATH=$ep_dir
		HOST_OS=$ep_os
		brew_works() { return 1; }
		PM="" PM_INSTALL=""
		detect_pkg_manager || :
		[ "$PM" = "$ep_expected" ] ||
			fail "$ep_os with [$*] selected '$PM', expected '$ep_expected'"
	)
	printf 'ok - %s with [%s] selects %s\n' "$ep_os" "$*" "${ep_expected:-no manager}"
}

# Commands whose name is claimed by unrelated tools on other platforms.
expect_pm '' SunOS pkg
expect_pm pkg FreeBSD pkg
expect_pm pkg DragonFly pkg
expect_pm port Darwin port
expect_pm '' Linux port

# NetBSD's pkg_add comes from a different pkg_install than OpenBSD's: pkg_info
# -Q prints a build variable rather than searching, and pkg_add wants a
# hand-set PKG_PATH. pkgin is the route we support there.
expect_pm pkg_add OpenBSD pkg_add
expect_pm pkgin NetBSD pkgin pkg_add
expect_pm '' NetBSD pkg_add

# Linux managers, including the two that may only advise.
expect_pm apt Linux apt-get
expect_pm dnf Linux dnf yum
expect_pm yum Linux yum
expect_pm pacman Linux pacman
expect_pm zypper Linux zypper
expect_pm apk Linux apk
expect_pm xbps Linux xbps-install
expect_pm emerge Linux emerge

# An image-based system has a read-only /usr, so dnf is the wrong half of the
# pair even when both are installed.
expect_pm rpm-ostree Linux rpm-ostree dnf

# ...but Homebrew outranks rpm-ostree on images that ship it, such as Bluefin:
# it installs immediately instead of staging packages for the next boot.
bluefin_bin="$TMP/bluefin"
mkdir -p "$bluefin_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$bluefin_bin/rpm-ostree"
chmod 755 "$bluefin_bin/rpm-ostree"
# shellcheck disable=SC2030,SC2031 # PATH changes are intentionally subshell-local.
(
	PATH=$bluefin_bin
	HOST_OS=Linux
	brew_works() { return 0; }
	PM="" PM_INSTALL=""
	detect_pkg_manager || fail 'no manager selected while Homebrew was present'
	[ "$PM" = brew ] || fail "Homebrew lost to $PM on an image-based system"
)
printf 'ok - Homebrew outranks rpm-ostree\n'

# Portage would build from source and rpm-ostree only stages the next boot, so
# neither may be driven unattended — the run reports the command instead.
gentoo_bin="$TMP/gentoo"
mkdir -p "$gentoo_bin"
cat >"$gentoo_bin/emerge" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TOOL_INSTALL_LOG"
EOF
chmod 755 "$gentoo_bin/emerge"
# shellcheck disable=SC2030,SC2031 # PATH changes are intentionally subshell-local.
(
	PATH=$gentoo_bin:$PATH
	TOOL_INSTALL_LOG="$TMP/advisory.log"
	export TOOL_INSTALL_LOG
	PM=emerge PM_INSTALL=emerge
	if install_tool_packages app-arch/upx >"$TMP/advisory.out"; then
		fail 'an advisory manager reported a successful install'
	fi
	if [ -f "$TMP/advisory.log" ]; then
		fail 'an advisory manager ran the package manager'
	fi
	grep -q 'emerge app-arch/upx' "$TMP/advisory.out" ||
		fail 'the advisory note did not name the command to run'
)
printf 'ok - advisory managers report instead of installing\n'

# Package name mappings, including the trees that were silently skipped for
# innoextract and the Portage atoms that carry a category.
check_names() {
	PM=$1
	cn_got=$(pkg_names "$2")
	[ "$cn_got" = "$3" ] || fail "$1:$2 mapped to '$cn_got', expected '$3'"
}
check_names apk innoextract innoextract
check_names pkgin innoextract innoextract
check_names pkg_add innoextract innoextract
check_names apk rizin 'rizin radare2'
check_names pkgin rizin radare2
check_names apt upx upx-ucl
check_names brew 7z sevenzip
check_names pkg 7z '7-zip p7zip'
check_names xbps 7z '7zip p7zip'
check_names port upx upx
check_names emerge 7z 'app-arch/7zip app-arch/p7zip'
check_names emerge innoextract app-arch/innoextract
check_names yum innoextract innoextract
printf 'ok - package names cover every detected manager\n'

cat >"$fake_bin/apt-cache" <<'EOF'
#!/bin/sh
[ "${1:-}" = show ] || exit 1
case ${2:-} in
upx-ucl | p7zip-full) exit 0 ;;
*) exit 1 ;;
esac
EOF
cat >"$fake_bin/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TOOL_INSTALL_LOG"
EOF
chmod 755 "$fake_bin/apt-cache" "$fake_bin/apt-get"

# shellcheck disable=SC2031 # The prior PATH assignments were subshell-local.
original_path=$PATH
PATH=$fake_bin
TOOL_INSTALL_LOG="$TMP/install.log"
export TOOL_INSTALL_LOG
BREW_PREFIX=""
INSTALL_ESCALATOR=""
PRIVILEGE_APPROVED=0
PRIVILEGE_DENIED=0
APPROVAL_COMMAND=""

HOST_OS=Linux
id() { printf '%s\n' 1000; }
doas() { command "$@"; }
have_tool() { return 1; }
brew_works() { return 1; }
approve_privilege() {
	APPROVAL_COMMAND=$1
	PRIVILEGE_APPROVED=1
	return 0
}

check_tools >"$TMP/output"
PATH=$original_path

[ "$(cat "$TOOL_INSTALL_LOG")" = 'install -y upx-ucl p7zip-full' ] ||
	fail 'installer did not limit apt packages to repository matches'
[ "$APPROVAL_COMMAND" = 'doas apt-get install -y upx-ucl p7zip-full' ] ||
	fail "approval did not show the exact package command: $APPROVAL_COMMAND"
grep -q 'not available from configured repositories: rizin innoextract' "$TMP/output" ||
	fail 'unavailable repository packages were not reported accurately'
if grep -q -- '-rizin\|-upx\|-7z\|-innoextract' "$TMP/output"; then
	fail 'tool output regressed to the negative +/- status row'
fi
printf 'ok - only available packages are approved and installed\n'
