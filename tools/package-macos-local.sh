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
SOURCE_APP="$BUILD_ROOT/macos/release64/Fritzing.app"
DESTINATION_ROOT="$BUILD_ROOT/macos/installable"
DESTINATION_APP="$DESTINATION_ROOT/Fritzing.app"
MACDEPLOYQT="$BUILD_ROOT/Qt/$QT_VERSION/macos/bin/macdeployqt"
LRELEASE="$BUILD_ROOT/Qt/$QT_VERSION/macos/bin/lrelease"
QUAZIP_LIB="$BUILD_ROOT/deps/quazip-$QT_VERSION-1.4-intuisphere/lib"
EXECUTABLE="$DESTINATION_APP/Contents/MacOS/Fritzing"
DATA_DIR="$DESTINATION_APP/Contents/Resources"
ENV_MANIFEST="$BUILD_ROOT/macos-build-env.txt"

die() {
	echo "error: $*" >&2
	exit 1
}

require_file() {
	[[ -f "$1" ]] || die "missing $1"
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

copy_linked_directory() {
	local link="$1"
	local destination="$2"
	local include_git="${3:-false}"
	local source
	[[ -L "$link" ]] || die "expected local runtime symlink: $link"
	source="$(readlink "$link")"
	[[ -d "$source" ]] || die "symlink target is not a directory: $source"
	unlink "$link"
	mkdir -p "$destination"
	if [[ "$include_git" == "true" ]]; then
		rsync -a "$source/" "$destination/"
	else
		rsync -a --exclude='.git/' "$source/" "$destination/"
	fi
}

copy_linked_file() {
	local destination="$1"
	local source
	[[ -L "$destination" ]] || die "expected local runtime symlink: $destination"
	source="$(readlink "$destination")"
	[[ -f "$source" ]] || die "symlink target is not a file: $source"
	unlink "$destination"
	install -m 0755 "$source" "$destination"
}

require_file "$SOURCE_APP/Contents/MacOS/Fritzing"
require_file "$MACDEPLOYQT"
require_file "$LRELEASE"
require_file "$QUAZIP_LIB/libquazip1-qt6.1.4.0.dylib"
require_file "$ENV_MANIFEST"
[[ ! -e "$DESTINATION_APP" ]] || die "$DESTINATION_APP already exists; move it aside before packaging again"

DEPLOYMENT_TARGET="$(awk -F= '$1 == "deployment_target" { print $2 }' "$ENV_MANIFEST")"
[[ -n "$DEPLOYMENT_TARGET" ]] || die "deployment target is missing from $ENV_MANIFEST"

mkdir -p "$DESTINATION_ROOT"
ditto "$SOURCE_APP" "$DESTINATION_APP"
rm -rf "$DESTINATION_APP/Contents/_CodeSignature"

copy_linked_directory \
	"$DESTINATION_APP/Contents/MacOS/fritzing-parts" \
	"$DATA_DIR/fritzing-parts" true
for directory in help sketches translations; do
	copy_linked_directory \
		"$DESTINATION_APP/Contents/MacOS/$directory" \
		"$DATA_DIR/$directory"
done
copy_linked_file "$DESTINATION_APP/Contents/lib/libngspice.0.dylib"
copy_linked_directory \
	"$DESTINATION_APP/Contents/lib/ngspice" \
	"$DESTINATION_APP/Contents/lib/ngspice"
install_name_tool -id '@loader_path/libngspice.0.dylib' \
	"$DESTINATION_APP/Contents/lib/libngspice.0.dylib"

for ts_file in "$DATA_DIR/translations"/*.ts; do
	"$LRELEASE" "$ts_file"
done
find "$DATA_DIR/translations" -type f -name '*.ts' -delete
if ! find "$DATA_DIR/translations" -type f -name '*.qm' -print -quit | grep -q .; then
	die "translation compilation produced no .qm files"
fi

for document in README.md THIRD_PARTY_PARTS.md INSTALL.txt LICENSE.CC-BY-SA LICENSE.GPL2 LICENSE.GPL3; do
	install -m 0644 "$REPO_ROOT/$document" "$DATA_DIR/$document"
done

python3 "$REPO_ROOT/tools/package-third-party-parts.py" \
	"$DATA_DIR/third-party-parts"

"$EXECUTABLE" \
	-db "$DATA_DIR/fritzing-parts/parts.db" \
	-pp "$DATA_DIR/fritzing-parts" \
	-f "$DATA_DIR"
require_file "$DATA_DIR/fritzing-parts/parts.db"
[[ "$(sqlite3 "$DATA_DIR/fritzing-parts/parts.db" 'pragma integrity_check')" == "ok" ]] || \
	die "parts database integrity check failed"
rm -rf "$DATA_DIR/fritzing-parts/.git"

mkdir -p "$DESTINATION_APP/Contents/Frameworks"
install -m 0755 "$QUAZIP_LIB/libquazip1-qt6.1.4.0.dylib" \
	"$DESTINATION_APP/Contents/Frameworks/libquazip1-qt6.1.4.0.dylib"

"$MACDEPLOYQT" "$DESTINATION_APP" \
	-libpath="$QUAZIP_LIB" \
	-always-overwrite \
	-appstore-compliant \
	-verbose=2

if [[ -d "$DESTINATION_APP/Contents/PlugIns/sqldrivers" ]]; then
	find "$DESTINATION_APP/Contents/PlugIns/sqldrivers" -type f \
		! -name 'libqsqlite.dylib' -delete
fi

# The local Fritzing executable is arm64, while Qt's binary distribution is
# universal. Keep only the architecture that can be loaded by this app.
while IFS= read -r -d '' binary; do
	file "$binary" | grep -q 'Mach-O' || continue
	architectures="$(lipo -archs "$binary")"
	case " $architectures " in
		*" arm64 "*) ;;
		*) die "packaged Mach-O has no arm64 slice: $binary ($architectures)" ;;
	esac
	if [[ "$architectures" != "arm64" ]]; then
		thin_binary="$binary.arm64"
		lipo "$binary" -thin arm64 -output "$thin_binary"
		chmod "$(stat -f '%Lp' "$binary")" "$thin_binary"
		mv "$thin_binary" "$binary"
	fi
done < <(find "$DESTINATION_APP" -type f -print0)

while IFS= read -r rpath; do
	case "$rpath" in
		"$BUILD_ROOT"/*)
			install_name_tool -delete_rpath "$rpath" "$EXECUTABLE"
			;;
	esac
done < <(otool -l "$EXECUTABLE" | awk '/LC_RPATH/{found=1; next} found && /path /{print $2; found=0}')

if otool -L "$EXECUTABLE" | tail -n +2 | grep -Fq "$BUILD_ROOT"; then
	die "packaged executable still links into $BUILD_ROOT"
fi
remaining_executable_rpaths="$(
	otool -l "$EXECUTABLE" | \
		awk '/LC_RPATH/{found=1; next} found && /path /{print $2; found=0}'
)"
if [[ "$remaining_executable_rpaths" == *"$BUILD_ROOT"* ]]; then
	die "packaged executable still has an rpath into $BUILD_ROOT"
fi
while IFS= read -r -d '' binary; do
	file "$binary" | grep -q 'Mach-O' || continue
	[[ "$(lipo -archs "$binary")" == "arm64" ]] || \
		die "packaged Mach-O is not arm64-only: $binary"
	if otool -L "$binary" | sed -n '/^[[:space:]]/p' | \
		grep -Eq '(/Users/|\.build/|/opt/homebrew|/usr/local|/Applications/Postgres\.app|/System/Library/Frameworks/AGL\.framework/)'; then
		die "packaged Mach-O has a forbidden dependency: $binary"
	fi
	while IFS= read -r rpath; do
		case "$rpath" in
			/Users/*|*/.build/*|/opt/homebrew/*|/usr/local/*|/Applications/Postgres.app/*)
				die "packaged Mach-O has a forbidden rpath: $binary -> $rpath"
				;;
		esac
	done < <(otool -l "$binary" | awk '/LC_RPATH/{found=1; next} found && /path /{print $2; found=0}')
	while IFS= read -r minimum_version; do
		if version_is_greater_than "$minimum_version" "$DEPLOYMENT_TARGET"; then
			die "packaged Mach-O requires macOS $minimum_version but Info.plist declares $DEPLOYMENT_TARGET: $binary"
		fi
	done < <(otool -l "$binary" | awk '
		/LC_BUILD_VERSION/ { build_version=1; next }
		build_version && /minos / { print $2; build_version=0 }
		/LC_VERSION_MIN_MACOSX/ { legacy_version=1; next }
		legacy_version && /version / { print $2; legacy_version=0 }
	')
done < <(find "$DESTINATION_APP" -type f -print0)
while IFS= read -r -d '' link; do
	target="$(readlink "$link")"
	[[ "$target" != /* ]] || die "packaged bundle contains an absolute symlink: $link -> $target"
done < <(find "$DESTINATION_APP" -type l -print0)

plutil -replace LSMinimumSystemVersion -string "$DEPLOYMENT_TARGET" \
	"$DESTINATION_APP/Contents/Info.plist"
xattr -cr "$DESTINATION_APP"

while IFS= read -r -d '' binary; do
	if file "$binary" | grep -q 'Mach-O'; then
		case "$binary" in
			*.framework/*) ;;
			*) codesign --force --sign - --timestamp=none "$binary" ;;
		esac
	fi
done < <(find \
	"$DESTINATION_APP/Contents/Frameworks" \
	"$DESTINATION_APP/Contents/PlugIns" \
	"$DESTINATION_APP/Contents/lib" \
	-type f -print0)
for framework in "$DESTINATION_APP/Contents/Frameworks"/*.framework; do
	[[ -d "$framework" ]] || continue
	codesign --force --sign - --timestamp=none "$framework"
done
codesign --force --sign - --timestamp=none "$DESTINATION_APP"
codesign --verify --deep --strict --verbose=2 "$DESTINATION_APP"

version_output="$("$EXECUTABLE" --version)"
[[ "$version_output" == Fritzing\ 1.0.8* ]] || die "unexpected executable version: $version_output"

echo ">> smoke test: $version_output"
echo ">> installable local app ready: $DESTINATION_APP"
