# Plan: Cross-compile pianobar for Nerves rpi3 using dockcross (no musl)

Target: `armv7-nerves-linux-gnueabihf` (Nerves rpi3, Cortex-A53, hard-float)
Strategy: Statically link ffmpeg/libcurl/libgcrypt/json-c; keep glibc dynamic
See: `docs/reports/nerves-cross-compilation.md` for rationale

---

## Step 1 — Get the dockcross wrapper script

```bash
docker run --rm dockcross/linux-armv7 > ./dockcross-armv7
chmod +x ./dockcross-armv7
```

## Step 2 — Check the ffmpeg version in the container

pianobar requires ffmpeg ≤ 5.1. Confirm before proceeding:

```bash
./dockcross-armv7 bash -c 'apt-cache show libavcodec-dev | grep Version'
```

- If version is 4.x or 5.x → continue
- If version is 6.x or newer → pin 5.1 or build ffmpeg 5.1 from source (out of scope for this plan; use a Debian Bookworm-based image instead)

To check the base image:
```bash
./dockcross-armv7 bash -c 'cat /etc/os-release'
```

## Step 3 — Install armhf dependencies in the container

dockcross/linux-armv7 is Debian-based and supports multiarch. Run once to install the cross-compiled dev packages:

```bash
./dockcross-armv7 bash -c '
  dpkg --add-architecture armhf
  apt-get update
  apt-get install -y \
    libavcodec-dev:armhf \
    libavformat-dev:armhf \
    libavutil-dev:armhf \
    libavfilter-dev:armhf \
    libcurl4-openssl-dev:armhf \
    libgcrypt20-dev:armhf \
    libjson-c-dev:armhf \
    libasound2-dev:armhf
'
```

Note: `libasound2-dev` is needed because miniaudio links against ALSA. The target Nerves system has `libasound.so.2` at runtime so this stays dynamic.

## Step 4 — Build pianobar

From the repo root:

```bash
./dockcross-armv7 bash -c '
  cd /work
  gmake clean
  gmake \
    PKG_CONFIG="pkg-config --static" \
    PKG_CONFIG_PATH="/usr/lib/arm-linux-gnueabihf/pkgconfig" \
    CFLAGS="-O2 -DNDEBUG -std=c99" \
    LDFLAGS="-Wl,-Bstatic \
      -lavcodec -lavformat -lavutil -lavfilter -lavdevice \
      -ljson-c -lgcrypt -lgpg-error \
      -lcurl \
      -Wl,-Bdynamic \
      -lasound -lpthread -lm -ldl"
'
```

What this does:
- `-Wl,-Bstatic` ... `-Wl,-Bdynamic`: links the listed libs statically, everything after the switch dynamically
- glibc, pthreads, and ALSA remain dynamic — glibc's NSS (`libnss_dns.so`) resolves on the Nerves target correctly
- ALSA remains dynamic because miniaudio `dlopen`s it anyway; keeping it dynamic avoids duplication

## Step 5 — Verify the binary

Confirm it is an ARM binary and check its dynamic dependencies:

```bash
./dockcross-armv7 bash -c 'file /work/pianobar'
# should say: ELF 32-bit LSB executable, ARM, EABI5, dynamically linked

./dockcross-armv7 bash -c 'ldd /work/pianobar'
# expected dynamic deps (only):
#   libpthread.so.0
#   libm.so.6
#   libdl.so.2
#   libasound.so.2
#   libc.so.6
```

If any of ffmpeg, libcurl, libgcrypt, or json-c appear in `ldd` output, the static linking flags above need adjustment — check that the `.a` archives are present in the armhf sysroot:

```bash
./dockcross-armv7 bash -c 'ls /usr/lib/arm-linux-gnueabihf/libavcodec.a'
```

## Step 6 — Deploy to the Nerves device

Copy the binary to the device (adjust IP as needed):

```bash
scp pianobar nerves.local:/usr/local/bin/pianobar
ssh nerves.local chmod +x /usr/local/bin/pianobar
```

Or include it in your Nerves firmware by placing it in the `rootfs_overlay/usr/local/bin/` directory of your Nerves project.

## Step 7 — Smoke test on the device

```bash
ssh nerves.local

# check it loads
pianobar --version

# check DNS resolution works (this is the main risk — see report)
# if this hangs or gives "network error", glibc version mismatch is the cause
pianobar
```

## Fallback: if DNS fails

If login fails with a network error but the binary otherwise runs, the glibc NSS version mismatch (documented in the report) is the cause. Options at that point:

1. **Use the Nerves staging sysroot** as the cross-compilation target (Option A2 from the report) to ensure glibc version alignment
2. **Proceed to Option B** (buildroot external package), which avoids this class of problem entirely

## Expected outcome

High confidence (~80%) the binary runs correctly. The main risk is glibc version mismatch affecting DNS. Audio output via ALSA should work since `libasound.so.2` is present on the Nerves rpi3 system.
