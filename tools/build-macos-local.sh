#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${FRITZING_BUILD_ROOT:-$REPO_ROOT/.build}"
if [[ "$BUILD_ROOT" != /* ]]; then
	BUILD_ROOT="$REPO_ROOT/$BUILD_ROOT"
fi
[[ "$BUILD_ROOT" != *[$' \t\n']* ]] || {
	echo "error: FRITZING_BUILD_ROOT must not contain whitespace" >&2
	exit 1
}
QT_VERSION="6.10.3"
QMAKE="$BUILD_ROOT/Qt/$QT_VERSION/macos/bin/qmake"
QMAKE_BUILD_DIR="$BUILD_ROOT/macos/qmake-$QT_VERSION"
APP="$BUILD_ROOT/macos/release64/Fritzing.app"
APP_EXECUTABLE="$APP/Contents/MacOS/Fritzing"
DEPS_DIR="$BUILD_ROOT/deps"
ENV_MANIFEST="$BUILD_ROOT/macos-build-env.txt"

BOOST_ROOT="$DEPS_DIR/boost_1_85_0"
LIBGIT_ROOT="$DEPS_DIR/libgit2-1.7.1"
NGSPICE_ROOT="$DEPS_DIR/ngspice-42"
QUAZIP_ROOT="$DEPS_DIR/quazip-$QT_VERSION-1.4-intuisphere"
SVGPP_ROOT="$DEPS_DIR/svgpp-1.3.1"
CLIPPER1_ROOT="$DEPS_DIR/Clipper1-6.4.2"
PARTS_ROOT="$DEPS_DIR/fritzing-parts"

usage() {
	cat <<'EOF'
Usage: tools/build-macos-local.sh [--configure-only]

Configure and incrementally build a Release Fritzing.app from the pinned .build/ environment.
--configure-only stops after generating and validating the qmake Makefile.
EOF
}

die() {
	echo "error: $*" >&2
	exit 1
}

require_file() {
	[[ -f "$1" ]] || die "missing $1; run tools/setup-macos-build.sh first"
}

require_dir() {
	[[ -d "$1" ]] || die "missing $1; run tools/setup-macos-build.sh first"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--configure-only" ) ]]; then
	usage >&2
	exit 2
fi

[[ "$(uname -s)" == "Darwin" ]] || die "this script supports macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "this build is intended to run on Apple Silicon"
require_file "$QMAKE"
require_file "$BOOST_ROOT/boost/version.hpp"
require_file "$LIBGIT_ROOT/lib/libgit2.a"
require_file "$NGSPICE_ROOT/include/ngspice/sharedspice.h"
require_file "$NGSPICE_ROOT/lib/libngspice.0.dylib"
require_dir "$QUAZIP_ROOT/include/QuaZip-Qt6-1.4"
require_dir "$QUAZIP_ROOT/lib"
require_file "$SVGPP_ROOT/include/svgpp/svgpp.hpp"
require_file "$CLIPPER1_ROOT/include/polyclipping/clipper.hpp"
require_file "$CLIPPER1_ROOT/lib/libpolyclipping.a"
require_dir "$PARTS_ROOT/core"
require_file "$ENV_MANIFEST"

RECORDED_DEPLOYMENT_TARGET="$(awk -F= '$1 == "deployment_target" { print $2 }' "$ENV_MANIFEST")"
[[ -n "$RECORDED_DEPLOYMENT_TARGET" ]] || die "deployment target is missing from $ENV_MANIFEST"
if [[ -n "${MACOSX_DEPLOYMENT_TARGET:-}" && "$MACOSX_DEPLOYMENT_TARGET" != "$RECORDED_DEPLOYMENT_TARGET" ]]; then
	die "requested deployment target $MACOSX_DEPLOYMENT_TARGET differs from prepared dependencies ($RECORDED_DEPLOYMENT_TARGET)"
fi
[[ "$("$QMAKE" -query QT_VERSION)" == "$QT_VERSION" ]] || die "qmake version is not $QT_VERSION"

mkdir -p "$QMAKE_BUILD_DIR"
(
	cd "$QMAKE_BUILD_DIR"
	"$QMAKE" "$REPO_ROOT/phoenix.pro" -o Makefile \
		"boost_root=$BOOST_ROOT" \
		"libgit_root=$LIBGIT_ROOT" \
		"ngspice_root=$NGSPICE_ROOT" \
		"quazip_root=$QUAZIP_ROOT" \
		"svgpp_root=$SVGPP_ROOT" \
		"clipper1_root=$CLIPPER1_ROOT" \
		-after \
		"QMAKE_APPLE_DEVICE_ARCHS=arm64" \
		"QMAKE_MACOSX_DEPLOYMENT_TARGET=$RECORDED_DEPLOYMENT_TARGET" \
		"QMAKE_LIBS_OPENGL=-framework OpenGL" \
		"QMAKE_CXXFLAGS+=-include" \
		"QMAKE_CXXFLAGS+=arm_acle.h"
)

require_file "$QMAKE_BUILD_DIR/Makefile"
grep -q '^release:' "$QMAKE_BUILD_DIR/Makefile" || die "qmake did not generate a release target"
if grep -q -- '-framework AGL' "$QMAKE_BUILD_DIR/Makefile.Release"; then
	die "qmake retained the removed AGL framework"
fi
echo ">> qmake Release configuration verified at $QMAKE_BUILD_DIR/Makefile"

if [[ "${1:-}" == "--configure-only" ]]; then
	exit 0
fi

make -C "$QMAKE_BUILD_DIR" -j"$(sysctl -n hw.logicalcpu)" release
require_dir "$APP"

RUNTIME_DIR="$APP/Contents/MacOS"
RUNTIME_LIB_DIR="$APP/Contents/lib"
mkdir -p "$RUNTIME_DIR" "$RUNTIME_LIB_DIR"
ln -sfn "$PARTS_ROOT" "$RUNTIME_DIR/fritzing-parts"
ln -sfn "$REPO_ROOT/help" "$RUNTIME_DIR/help"
ln -sfn "$REPO_ROOT/sketches" "$RUNTIME_DIR/sketches"
ln -sfn "$REPO_ROOT/translations" "$RUNTIME_DIR/translations"
ln -sfn "$NGSPICE_ROOT/lib/libngspice.0.dylib" "$RUNTIME_LIB_DIR/libngspice.0.dylib"
if [[ -d "$NGSPICE_ROOT/lib/ngspice" ]]; then
	ln -sfn "$NGSPICE_ROOT/lib/ngspice" "$RUNTIME_LIB_DIR/ngspice"
fi

file "$APP_EXECUTABLE"
version_output="$("$APP_EXECUTABLE" --version)"
[[ "$version_output" == Fritzing\ 1.0.8* ]] || die "unexpected executable version: $version_output"
echo ">> smoke test: $version_output"
echo ">> local app ready: $APP"
echo ">> launch: open '$APP'"
