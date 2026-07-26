#!/usr/bin/env bash
# Cross-compile pianobar for armv6hf (Raspberry Pi Zero W / Nerves)
# Builds minimal ffmpeg + libcurl from source to keep deps small.
#
# Prerequisites:
#   docker installed and running
#
# Usage:
#   ./cross-build-armv6.sh
#
# Output:
#   pianobar          (ELF 32-bit ARM, armv6 hard-float, dynamically linked)
#   armv6-libs/       (shared libraries to deploy alongside the binary)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Build custom cross image (includes minimal ffmpeg + curl from source)
if ! docker image inspect pianobar-armv6-cross >/dev/null 2>&1; then
    echo "==> Building pianobar-armv6-cross Docker image (this compiles ffmpeg + curl, may take a few minutes)..."
    docker build --platform linux/amd64 \
        -t pianobar-armv6-cross \
        -f "$SCRIPT_DIR/Dockerfile.armv6" \
        "$SCRIPT_DIR"
else
    echo "==> Docker image pianobar-armv6-cross already exists, skipping build."
    echo "    (To rebuild: docker rmi pianobar-armv6-cross)"
fi

# Step 2: Generate dockcross wrapper if not present
if [ ! -x "$SCRIPT_DIR/dockcross-armv6-cross" ]; then
    echo "==> Generating dockcross wrapper..."
    docker run --rm --platform linux/amd64 pianobar-armv6-cross > "$SCRIPT_DIR/dockcross-armv6-cross"
    chmod +x "$SCRIPT_DIR/dockcross-armv6-cross"
    sed -i '' 's|DEFAULT_DOCKCROSS_IMAGE=.*|DEFAULT_DOCKCROSS_IMAGE=pianobar-armv6-cross|' \
        "$SCRIPT_DIR/dockcross-armv6-cross" 2>/dev/null || \
    sed -i 's|DEFAULT_DOCKCROSS_IMAGE=.*|DEFAULT_DOCKCROSS_IMAGE=pianobar-armv6-cross|' \
        "$SCRIPT_DIR/dockcross-armv6-cross"
fi

# Step 3: Cross-compile pianobar
echo "==> Cross-compiling pianobar for armv6hf..."
"$SCRIPT_DIR/dockcross-armv6-cross" bash -c '
    cd /work
    SYSROOT=/usr/xcc/armv6-unknown-linux-gnueabihf/armv6-unknown-linux-gnueabihf/sysroot
    make clean 2>/dev/null || true
    PKG_CONFIG_PATH=$SYSROOT/usr/lib/pkgconfig \
    make \
        CC="armv6-unknown-linux-gnueabihf-gcc -std=c99 --sysroot=$SYSROOT" \
        CFLAGS="-O2 -DNDEBUG" \
        LDFLAGS="-Wl,--allow-shlib-undefined -Wl,-rpath,/root/pianobar/lib" \
        MINIAUDIO_LDFLAGS="-ldl"
'

echo ""
echo "==> Verifying binary architecture..."
"$SCRIPT_DIR/dockcross-armv6-cross" bash -c 'readelf -A /work/pianobar | grep -E "Tag_CPU|Tag_FP"'
echo ""

# Step 4: Collect shared libraries needed on device
echo "==> Collecting shared libraries..."
rm -rf "$SCRIPT_DIR/armv6-libs"
mkdir -p "$SCRIPT_DIR/armv6-libs"

"$SCRIPT_DIR/dockcross-armv6-cross" bash -c '
    cd /work
    SYSROOT=/usr/xcc/armv6-unknown-linux-gnueabihf/armv6-unknown-linux-gnueabihf/sysroot

    # Libraries already on the Nerves device — do NOT bundle
    SKIP="linux-vdso|ld-linux-armhf|libc\.so|libm\.so|libdl\.so|libpthread\.so|libresolv\.so|librt\.so|libgcc_s|libstdc\+\+|libasound\.so|libssl\.so|libcrypto\.so|libz\.so"

    copy_lib() {
        local name="$1"
        local search_dirs="$SYSROOT/usr/lib $SYSROOT/lib"
        for dir in $search_dirs; do
            local found=$(find "$dir" -maxdepth 1 -name "${name}*" -type f 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                local real=$(readlink -f "$found")
                local soname=$(readelf -d "$real" 2>/dev/null | grep SONAME | sed "s/.*\[//;s/\]//")
                cp "$real" "/work/armv6-libs/"
                # Create soname symlink if needed
                if [ -n "$soname" ] && [ "$soname" != "$(basename "$real")" ]; then
                    ln -sf "$(basename "$real")" "/work/armv6-libs/$soname"
                fi
                # Create short name symlink
                ln -sf "$(basename "$real")" "/work/armv6-libs/$name" 2>/dev/null || true
                echo "  $soname -> $(basename "$real")"
                return 0
            fi
        done
        echo "  WARNING: $name not found"
        return 1
    }

    echo "Bundling libraries:"

    # ffmpeg libs (from our minimal build)
    copy_lib libavcodec.so
    copy_lib libavformat.so
    copy_lib libavutil.so
    copy_lib libavfilter.so
    copy_lib libswresample.so

    # libcurl (from our minimal build)
    copy_lib libcurl.so

    # Debian packages (small, few deps)
    copy_lib libgcrypt.so
    copy_lib libgpg-error.so
    copy_lib libjson-c.so

    echo ""
    echo "Verifying no missing deps..."
    ALL_NEEDED=""
    for lib in /work/armv6-libs/*.so.*; do
        [ -L "$lib" ] && continue  # skip symlinks
        needs=$(readelf -d "$lib" 2>/dev/null | grep NEEDED | sed "s/.*\[//;s/\]//")
        ALL_NEEDED="$ALL_NEEDED $needs"
    done
    # Also check the pianobar binary itself
    needs=$(readelf -d /work/pianobar 2>/dev/null | grep NEEDED | sed "s/.*\[//;s/\]//")
    ALL_NEEDED="$ALL_NEEDED $needs"

    # Deduplicate
    ALL_NEEDED=$(echo "$ALL_NEEDED" | tr " " "\n" | sort -u)

    MISSING=""
    for dep in $ALL_NEEDED; do
        echo "$dep" | grep -qE "$SKIP" && continue
        # Check if we have it in our bundle
        if ! ls /work/armv6-libs/$dep* >/dev/null 2>&1; then
            MISSING="$MISSING $dep"
        fi
    done

    if [ -n "$MISSING" ]; then
        echo "WARNING: Missing libraries (need to bundle or verify on device):"
        echo "  $MISSING"
    else
        echo "All dependencies satisfied!"
    fi

    echo ""
    echo "=== Bundle contents ==="
    ls -lhS /work/armv6-libs/ | grep -v "^total"
    echo ""
    total=$(du -sh /work/armv6-libs/ | cut -f1)
    echo "Total bundle size: $total"
'

echo ""
echo "==> Build complete!"
echo ""
file "$SCRIPT_DIR/pianobar"
echo ""
echo "NEEDED entries:"
readelf -d "$SCRIPT_DIR/pianobar" 2>/dev/null | grep NEEDED || \
    "$SCRIPT_DIR/dockcross-armv6-cross" bash -c 'readelf -d /work/pianobar | grep NEEDED'
echo ""
echo "Deploy with:"
echo "  sftp 172.31.219.153 <<'EOF'"
echo "  mkdir /root/pianobar"
echo "  mkdir /root/pianobar/lib"
echo "  put pianobar /root/pianobar/pianobar"
echo "  put armv6-libs/* /root/pianobar/lib/"
echo "  EOF"
echo ""
echo "Then: ssh 172.31.219.153 'File.chmod!(\"/root/pianobar/pianobar\", 0o755)'"
echo "Test: ssh 172.31.219.153 ':os.cmd(~c\"LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar --help\") |> IO.puts()'"
