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
        "$CONFIGURE" \
            --host=webos \
            --enable-plugins \
            --default-dynamic \
            --enable-release
    )

    # Patch config.mk to use full Linaro paths instead of bare tool names.
    # The bare names may resolve to system GCC (5+) which generates glibc
    # symbols the device cannot satisfy.
    echo "==> Patching config.mk with full Linaro tool paths"
    LINARO="$LINARO_BIN"
    sed -i "s|^CXX :=.*|CXX := $LINARO/arm-linux-gnueabi-g++|" "$CONFIG_MK"
    sed -i "s|^AR :=.*|AR := $LINARO/arm-linux-gnueabi-ar cr|" "$CONFIG_MK"
    sed -i "s|^AS :=.*|AS := $LINARO/arm-linux-gnueabi-as|" "$CONFIG_MK"
    sed -i "s|^LD :=.*|LD := $LINARO/arm-linux-gnueabi-g++|" "$CONFIG_MK"
    sed -i "s|^NM :=.*|NM := $LINARO/arm-linux-gnueabi-nm|" "$CONFIG_MK"
    sed -i "s|^RANLIB :=.*|RANLIB := $LINARO/arm-linux-gnueabi-ranlib|" "$CONFIG_MK"
    sed -i "s|^STRIP :=.*|STRIP := $LINARO/arm-linux-gnueabi-strip|" "$CONFIG_MK"
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
