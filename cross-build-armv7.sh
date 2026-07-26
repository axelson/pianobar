#!/usr/bin/env bash
# Cross-compile pianobar for armv7 (Nerves rpi3 / armhf)
# Uses dockcross/linux-armv7 with armhf deps pre-installed.
#
# Prerequisites:
#   docker installed and running
#
# Usage:
#   ./cross-build-armv7.sh
#
# Output:
#   pianobar  (ELF 32-bit ARM, dynamically linked)
#
# NOTE: The resulting binary dynamically links libavcodec, libavformat,
# libavutil, libavfilter, libcurl, libgcrypt, and libjson-c.
# These .so files must be present on the Nerves rootfs at runtime.
# See docs/plans/option-a-dockcross.md for the static linking goal
# and docs/reports/nerves-cross-compilation.md for background.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Build custom cross image if not already present
if ! docker image inspect pianobar-armv7-cross >/dev/null 2>&1; then
    echo "==> Building pianobar-armv7-cross Docker image..."
    docker build --platform linux/amd64 \
        -t pianobar-armv7-cross \
        -f "$SCRIPT_DIR/Dockerfile.armv7" \
        "$SCRIPT_DIR"
else
    echo "==> Docker image pianobar-armv7-cross already exists, skipping build."
fi

# Step 2: Generate dockcross wrapper if not present
if [ ! -x "$SCRIPT_DIR/dockcross-armv7-cross" ]; then
    echo "==> Generating dockcross wrapper..."
    docker run --rm --platform linux/amd64 pianobar-armv7-cross > "$SCRIPT_DIR/dockcross-armv7-cross"
    chmod +x "$SCRIPT_DIR/dockcross-armv7-cross"
    # Point wrapper at our custom image (not the upstream base)
    sed -i '' 's|DEFAULT_DOCKCROSS_IMAGE=.*|DEFAULT_DOCKCROSS_IMAGE=pianobar-armv7-cross|' \
        "$SCRIPT_DIR/dockcross-armv7-cross" 2>/dev/null || \
    sed -i 's|DEFAULT_DOCKCROSS_IMAGE=.*|DEFAULT_DOCKCROSS_IMAGE=pianobar-armv7-cross|' \
        "$SCRIPT_DIR/dockcross-armv7-cross"
fi

# Step 3: Cross-compile
echo "==> Cross-compiling pianobar for armv7..."
"$SCRIPT_DIR/dockcross-armv7-cross" bash -c '
    cd /work
    make clean 2>/dev/null || true
    PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig \
    make \
        CC="armv7-unknown-linux-gnueabi-gcc -std=c99" \
        CFLAGS="-O2 -DNDEBUG -I/usr/include -I/usr/include/arm-linux-gnueabihf" \
        LDFLAGS="-L/usr/lib/arm-linux-gnueabihf -Wl,--allow-shlib-undefined" \
        MINIAUDIO_LDFLAGS="-ldl"
'

echo ""
echo "==> Build complete."
echo ""
file "$SCRIPT_DIR/pianobar"
echo ""
echo "Dynamic dependencies (NEEDED entries):"
readelf -d "$SCRIPT_DIR/pianobar" 2>/dev/null | grep NEEDED || \
    "$SCRIPT_DIR/dockcross-armv7-cross" bash -c 'readelf -d /work/pianobar | grep NEEDED'
echo ""
echo "To deploy:"
echo "  scp pianobar nerves.local:/usr/local/bin/pianobar"
echo "  ssh nerves.local chmod +x /usr/local/bin/pianobar"
