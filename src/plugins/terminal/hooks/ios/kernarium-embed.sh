#!/bin/bash
# Xcode "Run Script" build phase installed by add-kernarium-runtime.js.
#
# Embeds the Kernarium runtime and the GPU frameworks it loads, plus the guest
# image, into the app being built, and marks the app to use the Kernarium
# terminal backend. Inputs come from kernarium-embed.env, which the hook writes
# next to this script.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$here/kernarium-embed.env"

case "${PLATFORM_NAME:-}" in
iphoneos) slice=ios-arm64 ;;
iphonesimulator) slice=ios-arm64-simulator ;;
*) echo "error: Kernarium embeds only for iOS device and Simulator (got ${PLATFORM_NAME:-none})" >&2; exit 1 ;;
esac

frameworks_dir="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "$frameworks_dir"

sign() {
	if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
		/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
			--preserve-metadata=identifier,entitlements,flags "$1"
	fi
}

# The runtime first; the GPU frameworks it links follow. KosmicKrisp needs
# Metal 4 and has no Simulator slice, so a missing slice is skipped only there.
for name in KRuntime_6_18_4K MesaEGL MesaGallium KosmicKrisp; do
	source_framework="$KERNARIUM_XCFRAMEWORKS/$name.xcframework/$slice/$name.framework"
	if [ ! -d "$source_framework" ]; then
		if [ "$name" = KosmicKrisp ] && [ "$slice" = ios-arm64-simulator ]; then
			continue
		fi
		echo "error: $source_framework is missing; package Kernarium's frameworks first" >&2
		exit 1
	fi
	rsync -a --delete "$source_framework" "$frameworks_dir/"
	sign "$frameworks_dir/$name.framework"
done

if [ ! -f "$ACODE_KERNARIUM_IMAGE" ]; then
	echo "error: $ACODE_KERNARIUM_IMAGE is missing; run src/plugins/terminal/kernarium/build-guest-image.sh" >&2
	exit 1
fi
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/kernarium"
mkdir -p "$resources"
install -m 0444 "$ACODE_KERNARIUM_IMAGE" "$resources/acode-kernarium-rootfs.ext4"

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
/usr/libexec/PlistBuddy -c "Delete :AcodeTerminalRuntime" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :AcodeTerminalRuntime string kernarium" "$plist"
