#!/usr/bin/env bash
# Builds the WPNativeInput GDExtension into app/addons/wp_native_input/bin/:
#   macOS  template_debug/template_release  universal framework (inert host build for editor/tests)
#   iOS    template_debug/template_release  xcframework = device arm64 + simulator arm64/x86_64,
#          plus the matching libgodot-cpp xcframework the .gdextension lists as a dependency.
#   test   host C++ test of the contact/overflow queue (tests/), ASan + UBSan; runs first in `all`.
# Usage: native/ios_input/build.sh [all|test|macos|ios]   (default: all)
# Env:   GODOT_CPP_URL  clone source for godot-cpp (default: GitHub); the commit is always verified.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BIN="$REPO/app/addons/wp_native_input/bin"
BUILD="$HERE/build"
GODOT_CPP_DIR="$HERE/godot-cpp"
GODOT_CPP_URL="${GODOT_CPP_URL:-https://github.com/godotengine/godot-cpp}"
GODOT_CPP_TAG="10.0.0-stable"
GODOT_CPP_COMMIT="507ed9d840c01a3c5b2a39af8bb4000bfac30bf5"
BUILD_PROFILE="$HERE/build_profile.json"
SCONS_VERSION="4.9.1"
IOS_MIN_VERSION="17.0"
MACOS_MIN_VERSION="11.0"
TARGETS=(template_debug template_release)
WHAT="${1:-all}"

die() {
	echo "build.sh: $*" >&2
	exit 1
}

require_tools() {
	local tool
	for tool in git uvx xcrun xcodebuild; do
		command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
	done
}

scons() {
	(cd "$HERE" && uvx --from "scons==$SCONS_VERSION" scons "$@")
}

verify_godot_cpp_commit() {
	local dir="$1" head
	head="$(git -C "$dir" rev-parse HEAD)"
	[ "$head" = "$GODOT_CPP_COMMIT" ] || die "godot-cpp at $dir is $head, expected $GODOT_CPP_COMMIT ($GODOT_CPP_TAG)"
}

fetch_godot_cpp() {
	if [ -e "$GODOT_CPP_DIR" ]; then
		[ -d "$GODOT_CPP_DIR/.git" ] || die "$GODOT_CPP_DIR exists but is not a git checkout; remove it"
		verify_godot_cpp_commit "$GODOT_CPP_DIR"
		git -C "$GODOT_CPP_DIR" diff --quiet HEAD || die "godot-cpp checkout has local modifications; remove $GODOT_CPP_DIR"
		echo "godot-cpp: reusing verified checkout $GODOT_CPP_COMMIT"
		return
	fi
	local tmp="$HERE/godot-cpp.tmp.$$"
	rm -rf "$tmp"
	trap 'rm -rf "'"$tmp"'"' EXIT
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$GODOT_CPP_TAG" "$GODOT_CPP_URL" "$tmp"
	verify_godot_cpp_commit "$tmp"
	mv "$tmp" "$GODOT_CPP_DIR"
	trap - EXIT
	echo "godot-cpp: cloned and verified $GODOT_CPP_COMMIT"
}

# godot-cpp/gen keeps bindings of classes outside the current profile from earlier builds; such a
# stale header would satisfy an include the profile no longer provides. Regenerate on any change.
reset_bindings_if_profile_changed() {
	local stamp="$BUILD/godot-cpp-profile.sha256" want
	want="$(shasum -a 256 "$BUILD_PROFILE" | cut -d' ' -f1)"
	if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
		return
	fi
	echo "godot-cpp: build profile changed; regenerating bindings"
	rm -rf "$GODOT_CPP_DIR/gen" "$GODOT_CPP_DIR/bin"
	echo "$want" >"$stamp"
}

# xcodebuild refuses to overwrite an existing xcframework.
make_xcframework() {
	local device_lib="$1" simulator_lib="$2" output="$3"
	[ -f "$device_lib" ] || die "missing $device_lib"
	[ -f "$simulator_lib" ] || die "missing $simulator_lib"
	rm -rf "$output"
	xcodebuild -create-xcframework -library "$device_lib" -library "$simulator_lib" -output "$output"
}

run_host_tests() {
	local out="$BUILD/tests/test_touch_record_queue"
	mkdir -p "$BUILD/tests"
	xcrun clang++ -std=c++17 -Wall -Wextra -Werror -g -O1 -fsanitize=address,undefined \
		-fno-omit-frame-pointer -I"$HERE/src" \
		"$HERE/tests/test_touch_record_queue.cpp" "$HERE/src/touch_record_queue.cpp" -o "$out"
	"$out" || die "host queue tests failed"
}

build_macos() {
	local target
	for target in "${TARGETS[@]}"; do
		scons platform=macos arch=universal target="$target" macos_deployment_target="$MACOS_MIN_VERSION"
		[ -f "$BIN/libwp_native_input.macos.$target.framework/libwp_native_input.macos.$target" ] \
			|| die "macOS $target library was not produced"
	done
}

build_ios() {
	local target
	for target in "${TARGETS[@]}"; do
		scons platform=ios arch=arm64 ios_simulator=no target="$target" ios_min_version="$IOS_MIN_VERSION"
		scons platform=ios arch=universal ios_simulator=yes target="$target" ios_min_version="$IOS_MIN_VERSION"
		make_xcframework \
			"$BUILD/libwp_native_input.ios.$target.a" \
			"$BUILD/libwp_native_input.ios.$target.simulator.a" \
			"$BIN/libwp_native_input.ios.$target.xcframework"
		make_xcframework \
			"$GODOT_CPP_DIR/bin/libgodot-cpp.ios.$target.arm64.a" \
			"$GODOT_CPP_DIR/bin/libgodot-cpp.ios.$target.universal.simulator.a" \
			"$BIN/libgodot-cpp.ios.$target.xcframework"
	done
}

main() {
	case "$WHAT" in
		all | test | macos | ios) ;;
		*) die "unknown build selection '$WHAT' (expected all, test, macos or ios)" ;;
	esac
	require_tools
	if [ "$WHAT" = all ] || [ "$WHAT" = test ]; then
		mkdir -p "$BUILD"
		run_host_tests
	fi
	if [ "$WHAT" = test ]; then
		echo "build.sh: test done"
		return
	fi
	fetch_godot_cpp
	mkdir -p "$BIN" "$BUILD"
	reset_bindings_if_profile_changed
	if [ "$WHAT" = all ] || [ "$WHAT" = macos ]; then
		build_macos
	fi
	if [ "$WHAT" = all ] || [ "$WHAT" = ios ]; then
		build_ios
	fi
	echo "build.sh: $WHAT done -> $BIN"
}

main
