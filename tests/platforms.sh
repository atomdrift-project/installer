#!/bin/sh
# Exercise every release target in ../scan/.github/workflows/release.yml without
# touching the network or filesystem outside this test process.

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

# In the monorepo checkout, fail immediately if Scan's release inventory gains
# or loses a target without a corresponding installer update. Windows belongs
# to scan.ps1; every other published target belongs to this shell script.
SCAN_WORKFLOW=${SCAN_RELEASE_WORKFLOW:-"$TEST_ROOT/../scan/.github/workflows/release.yml"}
if [ -f "$SCAN_WORKFLOW" ]; then
	expected_targets=$(awk '
		/^[[:space:]]+EXPECTED: >-/ { inventory = 1; next }
		inventory && /^[[:space:]]+REQUESTED_TARGET:/ { exit }
		inventory {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^[[:alnum:]_]+-[[:alnum:]_-]+-[[:alnum:]_-]+/) print $i
			}
		}' "$SCAN_WORKFLOW" | sort)
	# shellcheck disable=SC2086 # TARGETS is intentionally a newline-separated list.
	installer_targets=$(printf '%s\n' $TARGETS x86_64-pc-windows-msvc | sort)
	[ "$installer_targets" = "$expected_targets" ] || fail 'installer target list has drifted from release.yml'
	printf 'ok - installer target inventory matches release.yml\n'
fi

MOCK_OS=unknown
MOCK_ARCH=unknown
MOCK_RELEASE='test'
MOCK_OPERATING=unknown
MOCK_VERSION='test'
MOCK_ARM64=0
MOCK_MUSL=0

uname() {
	case ${1:-} in
	-s) printf '%s\n' "$MOCK_OS" ;;
	-m) printf '%s\n' "$MOCK_ARCH" ;;
	-r) printf '%s\n' "$MOCK_RELEASE" ;;
	-o) printf '%s\n' "$MOCK_OPERATING" ;;
	-v) printf '%s\n' "$MOCK_VERSION" ;;
	*) printf '%s\n' "$MOCK_OS" ;;
	esac
}

sysctl() {
	printf '%s\n' "$MOCK_ARM64"
}

ldd() {
	if [ "$MOCK_MUSL" = 1 ]; then
		printf '%s\n' 'musl libc' >&2
		return 1
	fi
	printf '%s\n' 'ldd (GNU libc)'
}

ls() {
	for ls_arg in "$@"; do
		case $ls_arg in
		/lib/ld-musl-*) [ "$MOCK_MUSL" = 1 ] && return 0 ;;
		esac
	done
	command ls "$@"
}

assert_platform() {
	ap_label=$1
	MOCK_OS=$2 MOCK_ARCH=$3 MOCK_OPERATING=$4 MOCK_VERSION=$5
	MOCK_ARM64=$6 MOCK_MUSL=$7 ap_expected=$8
	detect_platform
	[ "$SELF" = "$ap_expected" ] || fail "$ap_label: got $SELF, expected $ap_expected"
	[ "$TARGET" = "$ap_expected" ] || fail "$ap_label: $ap_expected is not release-backed"
	printf 'ok - %s -> %s\n' "$ap_label" "$SELF"
}

assert_platform 'Linux/openEuler x86_64 glibc' Linux x86_64 GNU/Linux test 0 0 x86_64-unknown-linux-gnu
assert_platform 'Linux arm64 glibc' Linux arm64 GNU/Linux test 0 0 aarch64-unknown-linux-gnu
assert_platform 'Linux x86_64 musl' Linux x86_64 GNU/Linux test 0 1 x86_64-unknown-linux-musl
assert_platform 'Linux arm64 musl' Linux aarch64 GNU/Linux test 0 1 aarch64-unknown-linux-musl
assert_platform 'Linux ARMv6 glibc' Linux armv6l GNU/Linux test 0 0 arm-unknown-linux-musleabihf
assert_platform 'Linux ARMv6 musl' Linux armv6l GNU/Linux test 0 1 arm-unknown-linux-musleabihf
assert_platform 'Linux ARMv7 glibc' Linux armv7l GNU/Linux test 0 0 armv7-unknown-linux-musleabihf
assert_platform 'Linux ARMv7 musl' Linux armv7l GNU/Linux test 0 1 armv7-unknown-linux-musleabihf
assert_platform 'Linux 32-bit ARMv8 userland' Linux armv8l GNU/Linux test 0 0 armv7-unknown-linux-musleabihf
assert_platform 'Linux LoongArch64 glibc' Linux loongarch64 GNU/Linux test 0 0 loongarch64-unknown-linux-musl
assert_platform 'Linux LoongArch64 musl' Linux loongarch64 GNU/Linux test 0 1 loongarch64-unknown-linux-musl
assert_platform 'Android' Linux x86_64 Android test 0 0 x86_64-unknown-linux-musl
assert_platform 'Android ARMv7' Linux armv7l Android test 0 0 armv7-unknown-linux-musleabihf
assert_platform 'Linux s390x' Linux s390x GNU/Linux test 0 0 s390x-unknown-linux-gnu
assert_platform 'Linux riscv64' Linux riscv64 GNU/Linux test 0 0 riscv64gc-unknown-linux-gnu
assert_platform 'Linux powerpc64le' Linux ppc64le GNU/Linux test 0 0 powerpc64le-unknown-linux-gnu
assert_platform 'macOS arm64' Darwin arm64 Darwin test 0 0 aarch64-apple-darwin
assert_platform 'macOS x86_64' Darwin x86_64 Darwin test 0 0 x86_64-apple-darwin
assert_platform 'macOS Rosetta' Darwin x86_64 Darwin test 1 0 aarch64-apple-darwin
assert_platform 'FreeBSD' FreeBSD amd64 FreeBSD test 0 0 x86_64-unknown-freebsd
[ "$PLATFORM" = "FreeBSD test  · x86_64" ] || fail "FreeBSD display repeats its target triple: $PLATFORM"
printf 'ok - platform display is concise and human-readable\n'
assert_platform 'OpenBSD' OpenBSD amd64 OpenBSD test 0 0 x86_64-unknown-openbsd
assert_platform 'NetBSD' NetBSD amd64 NetBSD test 0 0 x86_64-unknown-netbsd
assert_platform 'DragonFly BSD' DragonFly x86_64 DragonFly test 0 0 x86_64-unknown-dragonfly
assert_platform 'experimental Haiku mapping' Haiku x86_64 Haiku test 0 0 x86_64-unknown-haiku
assert_platform 'experimental GNU/Hurd mapping' GNU x86_64 GNU test 0 0 x86_64-unknown-hurd-gnu
assert_platform 'illumos/OpenIndiana/Tribblix' SunOS i86pc illumos 'omnios-r151058' 0 0 x86_64-unknown-illumos
assert_platform 'Solaris' SunOS i86pc Solaris '11.4' 0 0 x86_64-pc-solaris

MOCK_OS=Linux MOCK_ARCH=mipsel MOCK_OPERATING=GNU/Linux MOCK_VERSION=test
MOCK_ARM64=0 MOCK_MUSL=0
detect_platform
[ "$SELF" = mipsel-unknown-linux-gnu ] || fail "unsupported Linux target: got $SELF"
[ -z "$TARGET" ] || fail "unsupported Linux target unexpectedly selected $TARGET"
printf 'ok - unsupported MIPS targets select the source path\n'

MOCK_OS=MINGW64_NT MOCK_ARCH=x86_64
if windows_output=$(detect_platform 2>&1); then
	fail 'Windows shell did not stop and hand off to PowerShell'
fi
case $windows_output in
*install.ps1*) printf 'ok - Windows shell hands off to install.ps1\n' ;;
*) fail 'Windows handoff did not mention install.ps1' ;;
esac
