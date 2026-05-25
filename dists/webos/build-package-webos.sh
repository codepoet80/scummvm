#!/bin/bash
# build-package-webos.sh — Build and package ScummVM for webOS
#
# Run this from the ScummVM source tree root, or pass the source
# directory as the first argument.
#
# Usage:
#   ./dists/webos/build-package-webos.sh [source-dir] [build-dir]
#
# Defaults:
#   source-dir  = directory containing this script's parent (scummvm root)
#   build-dir   = ~/Projects/scummvm-webos-build
#
# Requirements:
#   - WebOS PDK at /opt/PalmPDK
#   - WebOS SDK at /opt/PalmSDK/0.2
#   - Linaro GCC 4.9.4 arm-linux-gnueabi cross-compiler
#     Default location: ~/Projects/qupzilla/toolchains/gcc-linaro/bin/
#     Override with LINARO_BIN env var.
#
# IMPORTANT — toolchain:
#   Always use Linaro GCC 4.9.4, NOT the system GCC.
#   The webOS device has glibc 2.5 (max symbol GLIBC_2.4).
#   GCC 5+ generates GLIBC_2.17+ symbols that crash on launch.

set -e

# ── Configurable paths ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BUILD_DIR="${2:-$HOME/Projects/scummvm-webos-build}"

WEBOS_PDK="${WEBOS_PDK:-/opt/PalmPDK}"
WEBOS_SDK="${WEBOS_SDK:-/opt/PalmSDK/0.2}"
LINARO_BIN="${LINARO_BIN:-$HOME/Projects/qupzilla/toolchains/gcc-linaro/bin}"

# ── Validate environment ──────────────────────────────────────────────────────

echo "==> Checking build environment"

if [ ! -d "$WEBOS_PDK" ]; then
    echo "ERROR: WebOS PDK not found at $WEBOS_PDK"
    echo "       Set WEBOS_PDK env var or install the PDK."
    exit 1
fi

if [ ! -d "$WEBOS_SDK" ]; then
    echo "ERROR: WebOS SDK not found at $WEBOS_SDK"
    echo "       Set WEBOS_SDK env var or install the SDK."
    exit 1
fi

if [ ! -x "$LINARO_BIN/arm-linux-gnueabi-g++" ]; then
    echo "ERROR: Linaro GCC not found at $LINARO_BIN/arm-linux-gnueabi-g++"
    echo "       Set LINARO_BIN env var to the Linaro bin directory."
    exit 1
fi

LINARO_GCC_VERSION=$("$LINARO_BIN/arm-linux-gnueabi-g++" --version 2>&1 | head -1)
echo "    Linaro: $LINARO_GCC_VERSION"
echo "    PDK:    $WEBOS_PDK"
echo "    SDK:    $WEBOS_SDK"
echo "    Source: $SOURCE_DIR"
echo "    Build:  $BUILD_DIR"

# ── Create build directory ────────────────────────────────────────────────────

mkdir -p "$BUILD_DIR"

# ── Configure (only if config.mk is missing or source configure is newer) ─────

CONFIG_MK="$BUILD_DIR/config.mk"
CONFIGURE="$SOURCE_DIR/configure"

if [ ! -f "$CONFIG_MK" ] || [ "$CONFIGURE" -nt "$CONFIG_MK" ]; then
    echo ""
    echo "==> Running configure"
    (
        cd "$BUILD_DIR"
        export WEBOS_PDK
        export WEBOS_SDK
        # Pass Linaro toolchain via env so configure bakes the full paths
        # into config.mk directly, avoiding any accidental system GCC pickup.
        CXX="$LINARO_BIN/arm-linux-gnueabi-g++" \
        AR="$LINARO_BIN/arm-linux-gnueabi-ar cr" \
        RANLIB="$LINARO_BIN/arm-linux-gnueabi-ranlib" \
        STRIP="$LINARO_BIN/arm-linux-gnueabi-strip" \
        AS="$LINARO_BIN/arm-linux-gnueabi-as" \
        "$CONFIGURE" \
            --host=webos \
            --enable-plugins \
            --default-dynamic \
            --enable-release
    )

    # Fix AR: configure appends the ar command twice (cr cru), keep only cr.
    sed -i 's|arm-linux-gnueabi-ar cr cru|arm-linux-gnueabi-ar cr|g' "$CONFIG_MK"

    # Remove stray host-system includes that configure picks up from the
    # build machine's freetype/libpng. Those headers reference symbols from
    # the host's glibc that do not exist on the device (glibc 2.5).
    sed -i 's| -I/usr/include/freetype2 -I/usr/include/libpng[^ ]*||g' "$CONFIG_MK"
    sed -i 's| -I/usr/include/freetype2||g; s| -I/usr/include/libpng[^ ]*||g' "$CONFIG_MK"
else
    echo ""
    echo "==> config.mk is up to date, skipping configure"
    echo "    (delete $CONFIG_MK to force reconfigure)"
fi

# ── Build ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Building ($(nproc) parallel jobs)"
make -C "$BUILD_DIR" -j"$(nproc)"

# ── Package ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Packaging"
make -C "$BUILD_DIR" package

echo ""
echo "==> Done"
ls -lh "$BUILD_DIR"/portdist/*.ipk
