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
DOWNLOAD_DIR="$BUILD_ROOT/downloads"
SOURCE_DIR="$BUILD_ROOT/sources"
DEPS_DIR="$BUILD_ROOT/deps"
DEP_BUILD_DIR="$BUILD_ROOT/dependency-build"
VENV_DIR="$BUILD_ROOT/venv"
QT_ROOT="$BUILD_ROOT/Qt"
NGSPICE_LIBCXX_PATCH="$REPO_ROOT/tools/patches/ngspice-42-libcxx-is-compound.patch"

QT_VERSION="6.10.3"
QT_ARCH="clang_64"
# qtsvg and qttools are resolved as dependencies of qtserialport in the
# Qt macOS repository; they are not valid aqt addon module names.
QT_MODULES=(qtserialport)
AQT_VERSION="3.3.0"
CMAKE_VERSION="4.4.3"
NINJA_VERSION="1.13.2"

BOOST_VERSION="1.85.0"
BOOST_DIR_NAME="boost_1_85_0"
BOOST_ARCHIVE="$BOOST_DIR_NAME.tar.bz2"
BOOST_URL="https://archives.boost.io/release/$BOOST_VERSION/source/$BOOST_ARCHIVE"
BOOST_SHA256="7009fe1faa1697476bdc7027703a2badb84e849b7b0baad5086b087b971f8617"

LIBGIT2_VERSION="1.7.1"
LIBGIT2_COMMIT="a2bde63741977ca0f4ef7db2f609df320be67a08"
SVGPP_VERSION="1.3.1"
SVGPP_COMMIT="fda1fd889548289178261d7aa02dd5d647247f94"
QUAZIP_VERSION="1.4"
QUAZIP_COMMIT="b6943c314188873f410dfaf8a21fc765adf17825"
PARTS_COMMIT="e64ffe973e92176b989ab390ab668638a85ee305"

NGSPICE_VERSION="42"
NGSPICE_ARCHIVE="ngspice-$NGSPICE_VERSION.tar.gz"
NGSPICE_URL="https://downloads.sourceforge.net/project/ngspice/ng-spice-rework/old-releases/$NGSPICE_VERSION/$NGSPICE_ARCHIVE"
NGSPICE_SHA256="737fe3846ab2333a250dfadf1ed6ebe1860af1d8a5ff5e7803c772cc4256e50a"

CLIPPER_VERSION="6.4.2"
CLIPPER_ARCHIVE="clipper_ver$CLIPPER_VERSION.zip"
CLIPPER_URL="https://downloads.sourceforge.net/project/polyclipping/$CLIPPER_ARCHIVE"
CLIPPER_SHA256="a14320d82194807c4480ce59c98aa71cd4175a5156645c4e2b3edd330b930627"

MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
APPLE_ARCHS="arm64"

usage() {
	cat <<'EOF'
Usage: tools/setup-macos-build.sh [--check]

Without arguments, download and build the pinned macOS dependencies in .build/.
--check validates the host and prints the pins without downloading anything.
EOF
}

die() {
	echo "error: $*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_repo_text() {
	local file="$1"
	local text="$2"
	grep -Fq "$text" "$REPO_ROOT/$file" || die "$file no longer declares: $text"
}

sha256_file() {
	shasum -a 256 "$1" | awk '{print $1}'
}

download_verified() {
	local url="$1"
	local destination="$2"
	local expected_sha="$3"
	local actual_sha

	if [[ -f "$destination" ]]; then
		actual_sha="$(sha256_file "$destination")"
		if [[ "$actual_sha" == "$expected_sha" ]]; then
			echo ">> verified cached $(basename "$destination")"
			return
		fi
		die "checksum mismatch for cached $destination (remove it and retry)"
	fi

	echo ">> downloading $(basename "$destination")"
	curl --fail --location --retry 3 --output "$destination.part" "$url"
	actual_sha="$(sha256_file "$destination.part")"
	[[ "$actual_sha" == "$expected_sha" ]] || die "checksum mismatch for $url"
	mv "$destination.part" "$destination"
}

checkout_commit() {
	local name="$1"
	local url="$2"
	local destination="$3"
	local commit="$4"
	local actual_remote

	if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
		die "$destination exists but is not a Git checkout"
	fi

	if [[ ! -d "$destination/.git" ]]; then
		echo ">> fetching $name at $commit"
		mkdir -p "$destination"
		git -C "$destination" init --quiet
		git -C "$destination" remote add origin "$url"
		git -C "$destination" fetch --quiet --depth 1 origin "$commit"
		git -C "$destination" checkout --quiet --detach "$commit"
	else
		actual_remote="$(git -C "$destination" remote get-url origin)"
		[[ "$actual_remote" == "$url" ]] || die "$name remote mismatch: $actual_remote"
		[[ -z "$(git -C "$destination" status --porcelain)" ]] || die "$name checkout has local changes: $destination"
		if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
			git -C "$destination" fetch --quiet --depth 1 origin "$commit"
		fi
		git -C "$destination" checkout --quiet --detach "$commit"
	fi

	[[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] || die "$name commit verification failed"
}

verify_arm64_binary() {
	local binary="$1"
	local archs
	[[ -f "$binary" ]] || die "expected build output not found: $binary"
	archs="$(lipo -archs "$binary")"
	[[ " $archs " == *" arm64 "* ]] || die "$binary has no arm64 slice"
}

version_is_greater_than() {
	awk -v left="$1" -v right="$2" 'BEGIN {
		split(left, l, "."); split(right, r, ".")
		for (i = 1; i <= 3; ++i) {
			if ((l[i] + 0) > (r[i] + 0)) exit 0
			if ((l[i] + 0) < (r[i] + 0)) exit 1
		}
		exit 1
	}'
}

verify_deployment_target() {
	local binary="$1"
	local minimum_version
	while IFS= read -r minimum_version; do
		if version_is_greater_than "$minimum_version" "$MACOSX_DEPLOYMENT_TARGET"; then
			die "$binary requires macOS $minimum_version; expected at most $MACOSX_DEPLOYMENT_TARGET"
		fi
	done < <(otool -l "$binary" | awk '
		/LC_BUILD_VERSION/ { build_version=1; next }
		build_version && /minos / { print $2; build_version=0 }
		/LC_VERSION_MIN_MACOSX/ { legacy_version=1; next }
		legacy_version && /version / { print $2; legacy_version=0 }
	')
}

print_pins() {
	cat <<EOF
Qt $QT_VERSION ($QT_ARCH; modules: ${QT_MODULES[*]})
Boost $BOOST_VERSION sha256=$BOOST_SHA256
libgit2 $LIBGIT2_VERSION commit=$LIBGIT2_COMMIT
ngspice $NGSPICE_VERSION sha256=$NGSPICE_SHA256
QuaZip $QUAZIP_VERSION INTUISPHERE commit=$QUAZIP_COMMIT
svgpp $SVGPP_VERSION commit=$SVGPP_COMMIT
Clipper1 $CLIPPER_VERSION sha256=$CLIPPER_SHA256
fritzing-parts master snapshot commit=$PARTS_COMMIT
Architectures: $APPLE_ARCHS
Deployment target: macOS $MACOSX_DEPLOYMENT_TARGET
EOF
}

check_host() {
	[[ "$(uname -s)" == "Darwin" ]] || die "this script supports macOS only"
	[[ "$(uname -m)" == "arm64" ]] || die "this setup is intended to run on Apple Silicon"
	require_command xcodebuild
	require_command xcrun
	require_command python3
	require_command git
	require_command curl
	require_command shasum
	require_command tar
	require_command unzip
	require_command patch
	require_command make
	xcodebuild -version >/dev/null
}

check_source_contract() {
	require_repo_text phoenix.pro "QT_LEAST=6.5.3"
	require_repo_text phoenix.pro "QT_MOST=6.10.10"
	require_repo_text pri/boostdetect.pri "BOOSTS = 85"
	require_repo_text pri/libgit2detect.pri "LIBGIT_VERSION=1.7.1"
	require_repo_text pri/spicedetect.pri "NGSPICEPATH = ../../ngspice-42"
	require_repo_text pri/quazipdetect.pri "QUAZIP_VERSION=1.4"
	require_repo_text pri/svgppdetect.pri "svgpp-1.3.1"
	require_repo_text pri/clipper1detect.pri "Clipper1-6.4.2"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	usage
	exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
	usage >&2
	exit 2
fi

check_host
check_source_contract
print_pins
if [[ "${1:-}" == "--check" ]]; then
	exit 0
fi

mkdir -p "$DOWNLOAD_DIR" "$SOURCE_DIR" "$DEPS_DIR" "$DEP_BUILD_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
	python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --upgrade \
	"pip==26.0.1" \
	"aqtinstall==$AQT_VERSION" \
	"cmake==$CMAKE_VERSION" \
	"ninja==$NINJA_VERSION"

AQT="$VENV_DIR/bin/aqt"
CMAKE="$VENV_DIR/bin/cmake"
NINJA="$VENV_DIR/bin/ninja"
QMAKE="$QT_ROOT/$QT_VERSION/macos/bin/qmake"

if [[ ! -x "$QMAKE" ]]; then
	"$AQT" install-qt mac desktop "$QT_VERSION" "$QT_ARCH" \
		--outputdir "$QT_ROOT" --modules "${QT_MODULES[@]}"
fi
[[ "$("$QMAKE" -query QT_VERSION)" == "$QT_VERSION" ]] || die "qmake version is not $QT_VERSION"
for framework in QtSerialPort QtSvg QtSvgWidgets QtUiTools; do
	[[ -d "$QT_ROOT/$QT_VERSION/macos/lib/$framework.framework" ]] || die "Qt module is missing: $framework"
done
while IFS= read -r -d '' prl_file; do
	sed -i '' -e 's/-framework AGL//g' "$prl_file"
done < <(find "$QT_ROOT/$QT_VERSION/macos/lib" -type f -name '*.prl' -print0)
if grep -Fq -- '-framework AGL' \
	"$QT_ROOT/$QT_VERSION/macos/mkspecs/common/mac.conf" \
	"$QT_ROOT/$QT_VERSION/macos/mkspecs/modules/qt_lib_gui_private.pri"; then
	die "Qt $QT_VERSION metadata unexpectedly references removed AGL framework"
fi
if find "$QT_ROOT/$QT_VERSION/macos/lib" -type f -name '*.prl' -exec grep -Fl -- '-framework AGL' {} + | grep -q .; then
	die "Qt library metadata still references AGL"
fi

download_verified "$BOOST_URL" "$DOWNLOAD_DIR/$BOOST_ARCHIVE" "$BOOST_SHA256"
if [[ ! -f "$DEPS_DIR/$BOOST_DIR_NAME/boost/version.hpp" ]]; then
	tar -xjf "$DOWNLOAD_DIR/$BOOST_ARCHIVE" -C "$DEPS_DIR"
fi
grep -q 'BOOST_VERSION 108500' "$DEPS_DIR/$BOOST_DIR_NAME/boost/version.hpp" || die "Boost header version verification failed"

checkout_commit "libgit2" "https://github.com/libgit2/libgit2.git" \
	"$SOURCE_DIR/libgit2-$LIBGIT2_VERSION" "$LIBGIT2_COMMIT"
"$CMAKE" -S "$SOURCE_DIR/libgit2-$LIBGIT2_VERSION" -B "$DEP_BUILD_DIR/libgit2-$LIBGIT2_VERSION" -G Ninja \
	-DCMAKE_MAKE_PROGRAM="$NINJA" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$DEPS_DIR/libgit2-$LIBGIT2_VERSION" \
	-DCMAKE_OSX_ARCHITECTURES="$APPLE_ARCHS" \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
	-DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF \
	-DUSE_SSH=OFF -DUSE_HTTPS=SecureTransport -DREGEX_BACKEND=builtin
"$CMAKE" --build "$DEP_BUILD_DIR/libgit2-$LIBGIT2_VERSION" --parallel
"$CMAKE" --install "$DEP_BUILD_DIR/libgit2-$LIBGIT2_VERSION"
verify_arm64_binary "$DEPS_DIR/libgit2-$LIBGIT2_VERSION/lib/libgit2.a"
verify_deployment_target "$DEPS_DIR/libgit2-$LIBGIT2_VERSION/lib/libgit2.a"

download_verified "$NGSPICE_URL" "$DOWNLOAD_DIR/$NGSPICE_ARCHIVE" "$NGSPICE_SHA256"
if [[ ! -x "$SOURCE_DIR/ngspice-$NGSPICE_VERSION/configure" ]]; then
	tar -xzf "$DOWNLOAD_DIR/$NGSPICE_ARCHIVE" -C "$SOURCE_DIR"
fi
if grep -Fq 'struct is_compound<duals::dual<T>> : true_type {};' \
	"$SOURCE_DIR/ngspice-$NGSPICE_VERSION/src/include/cppduals/duals/dual"; then
	patch -d "$SOURCE_DIR/ngspice-$NGSPICE_VERSION" -p1 < "$NGSPICE_LIBCXX_PATCH"
fi
if grep -Fq 'struct is_compound<duals::dual<T>> : true_type {};' \
	"$SOURCE_DIR/ngspice-$NGSPICE_VERSION/src/include/cppduals/duals/dual"; then
	die "ngspice libc++ compatibility patch did not apply"
fi
NGSPICE_BUILD_DIR="$DEP_BUILD_DIR/ngspice-$NGSPICE_VERSION-macos-$APPLE_ARCHS-$MACOSX_DEPLOYMENT_TARGET"
mkdir -p "$NGSPICE_BUILD_DIR"
(
	cd "$NGSPICE_BUILD_DIR"
	export MACOSX_DEPLOYMENT_TARGET
	CFLAGS="-arch arm64 -O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
	CXXFLAGS="-arch arm64 -O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
	LDFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
		"$SOURCE_DIR/ngspice-$NGSPICE_VERSION/configure" \
		--prefix="$DEPS_DIR/ngspice-$NGSPICE_VERSION" \
		--with-ngshared --enable-xspice --enable-cider --without-x --without-readline \
		--disable-openmp --disable-debug
	make -j"$(sysctl -n hw.logicalcpu)"
	make install
)
verify_arm64_binary "$DEPS_DIR/ngspice-$NGSPICE_VERSION/lib/libngspice.0.dylib"
verify_deployment_target "$DEPS_DIR/ngspice-$NGSPICE_VERSION/lib/libngspice.0.dylib"

checkout_commit "QuaZip" "https://github.com/INTUISPHERE/quazip_qt6.git" \
	"$SOURCE_DIR/quazip-$QUAZIP_VERSION-intuisphere" "$QUAZIP_COMMIT"
QUAZIP_BUILD_DIR="$DEP_BUILD_DIR/quazip-$QT_VERSION-$QUAZIP_VERSION-intuisphere"
"$CMAKE" -S "$SOURCE_DIR/quazip-$QUAZIP_VERSION-intuisphere" -B "$QUAZIP_BUILD_DIR" -G Ninja \
	-DCMAKE_MAKE_PROGRAM="$NINJA" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$DEPS_DIR/quazip-$QT_VERSION-$QUAZIP_VERSION-intuisphere" \
	-DCMAKE_PREFIX_PATH="$QT_ROOT/$QT_VERSION/macos" \
	-DCMAKE_OSX_ARCHITECTURES="$APPLE_ARCHS" \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
	-DBUILD_SHARED_LIBS=ON -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_ENABLE_TESTS=OFF \
	-DCMAKE_DISABLE_FIND_PACKAGE_Qt6Core5Compat=TRUE
"$CMAKE" --build "$QUAZIP_BUILD_DIR" --parallel
"$CMAKE" --install "$QUAZIP_BUILD_DIR"
verify_arm64_binary "$DEPS_DIR/quazip-$QT_VERSION-$QUAZIP_VERSION-intuisphere/lib/libquazip1-qt6.1.4.dylib"
verify_deployment_target "$DEPS_DIR/quazip-$QT_VERSION-$QUAZIP_VERSION-intuisphere/lib/libquazip1-qt6.1.4.dylib"

checkout_commit "svgpp" "https://github.com/svgpp/svgpp.git" \
	"$SOURCE_DIR/svgpp-$SVGPP_VERSION" "$SVGPP_COMMIT"
ln -sfn "../sources/svgpp-$SVGPP_VERSION" "$DEPS_DIR/svgpp-$SVGPP_VERSION"
[[ -f "$DEPS_DIR/svgpp-$SVGPP_VERSION/include/svgpp/svgpp.hpp" ]] || die "svgpp headers are incomplete"

download_verified "$CLIPPER_URL" "$DOWNLOAD_DIR/$CLIPPER_ARCHIVE" "$CLIPPER_SHA256"
if [[ ! -f "$SOURCE_DIR/Clipper1-$CLIPPER_VERSION/cpp/CMakeLists.txt" ]]; then
	mkdir -p "$SOURCE_DIR/Clipper1-$CLIPPER_VERSION"
	unzip -q "$DOWNLOAD_DIR/$CLIPPER_ARCHIVE" -d "$SOURCE_DIR/Clipper1-$CLIPPER_VERSION"
fi
"$CMAKE" -S "$SOURCE_DIR/Clipper1-$CLIPPER_VERSION/cpp" -B "$DEP_BUILD_DIR/Clipper1-$CLIPPER_VERSION" -G Ninja \
	-DCMAKE_MAKE_PROGRAM="$NINJA" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$DEPS_DIR/Clipper1-$CLIPPER_VERSION" \
	-DCMAKE_OSX_ARCHITECTURES="$APPLE_ARCHS" \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF
"$CMAKE" --build "$DEP_BUILD_DIR/Clipper1-$CLIPPER_VERSION" --parallel
"$CMAKE" --install "$DEP_BUILD_DIR/Clipper1-$CLIPPER_VERSION"
verify_arm64_binary "$DEPS_DIR/Clipper1-$CLIPPER_VERSION/lib/libpolyclipping.a"
verify_deployment_target "$DEPS_DIR/Clipper1-$CLIPPER_VERSION/lib/libpolyclipping.a"

checkout_commit "fritzing-parts" "https://github.com/fritzing/fritzing-parts.git" \
	"$DEPS_DIR/fritzing-parts" "$PARTS_COMMIT"

cat > "$BUILD_ROOT/macos-build-env.txt" <<EOF
qt=$QT_VERSION
boost=$BOOST_VERSION sha256=$BOOST_SHA256
libgit2=$LIBGIT2_VERSION commit=$LIBGIT2_COMMIT
ngspice=$NGSPICE_VERSION sha256=$NGSPICE_SHA256
quazip=$QUAZIP_VERSION commit=$QUAZIP_COMMIT
svgpp=$SVGPP_VERSION commit=$SVGPP_COMMIT
clipper1=$CLIPPER_VERSION sha256=$CLIPPER_SHA256
fritzing-parts=$PARTS_COMMIT
architectures=$APPLE_ARCHS
deployment_target=$MACOSX_DEPLOYMENT_TARGET
xcode=$(xcodebuild -version | tr '\n' ' ')
EOF

echo ">> macOS build environment is ready under $BUILD_ROOT"
echo ">> next: tools/build-macos-local.sh"
