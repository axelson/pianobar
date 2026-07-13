# Plan: Cross-compile pianobar for Nerves using dockcross (no musl)

Target: `armv7-nerves-linux-gnueabihf` (Nerves rpi3, Cortex-A53, hard-float)
Retargeted: `armv6-unknown-linux-gnueabihf` (Pi Zero W, ARM1176JZF-S, hard-float)
Strategy: Statically link ffmpeg/libcurl/libgcrypt/json-c; keep glibc dynamic
See: `docs/reports/nerves-cross-compilation.md` for rationale

> **Status (2026-07-11):** Binary runs on device. Pandora login + audio not yet tested.
> Repeatable build: run `./cross-build-armv6.sh` from the repo root.
> Previous armv7 build: `./cross-build-armv7.sh` (targets wrong arch for Pi Zero W).

> **Maintenance policy:** Document experimental results directly in this file.
> Each step should have an "Implemented" annotation or subsection recording what
> actually happened — commands run, errors encountered, workarounds found, and
> `readelf`/`file`/`ldd` output confirming the result. This file is the single
> source of truth for Option A implementation details. STATUS.md summarizes and
> links here; it should not duplicate experimental detail.

---

## Step 1 — Get the dockcross wrapper script

```bash
docker run --rm dockcross/linux-armv7 > ./dockcross-armv7
chmod +x ./dockcross-armv7
```

> **Implemented:** done. Also generated `./dockcross-armv7-cross` (points at the custom
> `pianobar-armv7-cross` image built in Step 3).
>
> **Platform note:** on Apple Silicon (linux/arm64), Docker pulls `dockcross/linux-armv7`
> as `linux/amd64` under emulation. A warning is printed but the container runs correctly.

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

> **Implemented:** base is **Debian GNU/Linux 12 (Bookworm)**; ffmpeg version is
> `7:5.1.8-0+deb12u1` — within the ≤ 5.1 limit. ✓

## Step 3 — Install armhf dependencies in the container

The original plan ran `apt-get` inside the dockcross wrapper. This **does not work** — the
dockcross entrypoint script re-maps the user inside the container and the system directories
are effectively read-only. `dpkg --add-architecture armhf` fails with "Permission denied"
even with `--args "-u root"`.

**Actual approach:** build a custom Docker image on top of `dockcross/linux-armv7` that
pre-installs the armhf packages:

```dockerfile
# Dockerfile.armv7 (committed to repo root)
FROM dockcross/linux-armv7
USER root
RUN dpkg --add-architecture armhf && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      libavcodec-dev:armhf \
      libavformat-dev:armhf \
      libavutil-dev:armhf \
      libavfilter-dev:armhf \
      libcurl4-openssl-dev:armhf \
      libgcrypt20-dev:armhf \
      libjson-c-dev:armhf \
      libasound2-dev:armhf && \
    rm -rf /var/lib/apt/lists/*
```

Build once:

```bash
docker build --platform linux/amd64 -t pianobar-armv7-cross -f Dockerfile.armv7 .
docker run --rm --platform linux/amd64 pianobar-armv7-cross > ./dockcross-armv7-cross
chmod +x ./dockcross-armv7-cross
# patch wrapper to use our image instead of the upstream base
sed -i 's|DEFAULT_DOCKCROSS_IMAGE=.*|DEFAULT_DOCKCROSS_IMAGE=pianobar-armv7-cross|' \
    ./dockcross-armv7-cross
```

Note: `libasound2-dev` is needed because miniaudio links against ALSA. The target Nerves
system has `libasound.so.2` at runtime so this stays dynamic.

> **Implemented:** `Dockerfile.armv7` and `pianobar-armv7-cross` wrapper are committed.
> Static `.a` archives are present: `libavcodec.a`, `libavformat.a`, `libavutil.a`,
> `libavfilter.a`, `libcurl.a`, `libgcrypt.a`, `libjson-c.a` all in
> `/usr/lib/arm-linux-gnueabihf/`.

## Step 4 — Build pianobar

The original build command has two issues discovered during implementation:

1. **`gmake` is not in the container** — use `make`.
2. **The cross-compiler path** — dockcross/linux-armv7 provides
   `armv7-unknown-linux-gnueabi-gcc` (under `/usr/xcc/`), not `arm-linux-gnueabihf-gcc`.
   The `$CC` environment variable is set correctly inside the container; pass it explicitly.
3. **Headers not in cross-compiler sysroot** — armhf dev packages install headers under
   `/usr/include/` and `/usr/include/arm-linux-gnueabihf/`, but the cross-compiler's
   sysroot is at `/usr/xcc/armv7-unknown-linux-gnueabi/armv7-unknown-linux-gnueabi/sysroot/`.
   Add `-I/usr/include -I/usr/include/arm-linux-gnueabihf` to CFLAGS.
4. **Static linking not feasible** — see [Implementation notes](#implementation-notes).

**Working build command (dynamic linking):**

```bash
./dockcross-armv7-cross bash -c '
  cd /work
  make clean
  PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig \
  make \
    CC="armv7-unknown-linux-gnueabi-gcc -std=c99" \
    CFLAGS="-O2 -DNDEBUG -I/usr/include -I/usr/include/arm-linux-gnueabihf" \
    LDFLAGS="-L/usr/lib/arm-linux-gnueabihf -Wl,--allow-shlib-undefined" \
    MINIAUDIO_LDFLAGS="-ldl"
'
```

The `--allow-shlib-undefined` flag is needed because the Debian armhf `.so` stubs have
unresolved references to their own transitive deps (OpenSSL, libva, libssh, etc.) which
aren't installed in the cross environment. They resolve at runtime on the target system.

**Original intended command (static linking — does not work, see notes):**

```bash
./dockcross-armv7-cross bash -c '
  cd /work
  make clean
  make \
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

## Step 5 — Verify the binary

```bash
./dockcross-armv7-cross bash -c 'file /work/pianobar'
# should say: ELF 32-bit LSB executable, ARM, EABI5, dynamically linked

./dockcross-armv7-cross bash -c 'readelf -d /work/pianobar | grep NEEDED'
```

> **Implemented:** binary confirmed as `ELF 32-bit LSB executable, ARM, EABI5 version 1
> (SYSV), dynamically linked, interpreter /lib/ld-linux-armhf.so.3, for GNU/Linux 5.4.0`.
>
> Actual NEEDED entries (dynamic linking, not the originally intended static result):
> ```
> libm.so.6
> libavcodec.so.59
> libavformat.so.59
> libavutil.so.57
> libavfilter.so.8
> libcurl.so.4
> libgcrypt.so.20
> libjson-c.so.5
> libc.so.6
> ```
> Note: `libasound` does not appear — miniaudio `dlopen`s it at runtime. ✓
> Note: `libpthread` and `libdl` are folded into glibc on modern Linux and need no
> separate NEEDED entry. ✓

## Step 6 — Deploy to the Nerves device

Copy the binary **and its shared library dependencies** to the device. Because the binary
is dynamically linked, the `.so` files must be present on the Nerves rootfs.

```bash
# Copy binary
scp pianobar nerves.local:/usr/local/bin/pianobar
ssh nerves.local chmod +x /usr/local/bin/pianobar

# Also copy .so files into rootfs overlay (adjust versions as needed)
# libavcodec.so.59, libavformat.so.59, libavutil.so.57, libavfilter.so.8
# libcurl.so.4, libgcrypt.so.20, libjson-c.so.5
# plus their transitive deps (libssl, libz, etc.)
```

Or, for a Nerves firmware build, place the binary in `rootfs_overlay/usr/local/bin/` and
the `.so` files in `rootfs_overlay/usr/lib/` of your Nerves project.

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

If login fails with a network error but the binary otherwise runs, the glibc NSS version
mismatch (documented in the report) is the cause. Options at that point:

1. **Use the Nerves staging sysroot** as the cross-compilation target (Option A2 from the
   report) to ensure glibc version alignment
2. **Proceed to Option B** (buildroot external package), which avoids this class of
   problem entirely

---

## Implementation notes

### Why static linking is not feasible with Debian-packaged ffmpeg

The plan called for `-Wl,-Bstatic` linking of ffmpeg/libcurl/libgcrypt/json-c. The static
`.a` archives are present in the container, but Debian Bookworm's ffmpeg is built with
every optional codec enabled (x264, AV1, JXL, Theora, OpenCL, VAAPI, libssh, RIST, …).

`pkg-config --static --libs libavcodec libavformat libavutil libavfilter` expands to over
80 `-l` flags, including libraries not installed in the cross environment (`libva`, `libX11`,
`libOpenCL`, `libssh`, `librist`, `libzvbi`, `libSvtAv1Enc`, `librav1e`, …). Statically
linking all of these would require installing ~100 additional `:armhf` dev packages and
resolving their transitive deps recursively.

Additionally, the Makefile appends `${LIBAV_LDFLAGS}` (from `pkg-config --libs`) *after*
`${LDFLAGS}` in `ALL_LDFLAGS`. Placing `-Wl,-Bstatic` in LDFLAGS and `-Wl,-Bdynamic`
before the hardcoded `-lpthread -lm` results in the pkg-config flags being processed after
`-Wl,-Bdynamic`, causing the linker to use the `.so` stubs instead of the `.a` archives.

**Path to proper static linking:** build a minimal ffmpeg from source with only the codecs
pianobar uses (AAC and MP3 decoding via `libavcodec`, HTTP demuxing via `libavformat`).
This is Option B territory (buildroot/mix_tasks_nerves_package), which handles dependency
trees correctly.

### Makefile behaviour under cross-compilation

- The `ifeq (${CC},cc)` block in the Makefile auto-sets `CC` only when the default `cc`
  is used. Passing `CC=` on the command line bypasses this, so `-std=c99` must be included
  in the `CC=` value explicitly.
- `PKG_CONFIG_PATH` passed as a make variable *does* affect `$(shell ...)` calls because
  GNU make propagates command-line variables into the shell environment.
- `MINIAUDIO_LDFLAGS` must be overridden to remove `-ldl` from under `-Wl,-Bstatic` (or
  left as `-ldl` under dynamic mode, which is what the working build does).

## ARMv6 retarget (2026-07-11)

The original armv7 build targets Cortex-A53 / rpi3, but the actual device is a
**Pi Zero W (ARM1176JZF-S = ARMv6)**. An armv7 binary SIGILLs on armv6.

### Solution: `Dockerfile.armv6` + `cross-build-armv6.sh`

Uses `dockcross/linux-armv6` (GCC 11.3.0, Bookworm, glibc 2.34 sysroot).

#### Key problem: glibc mismatch between sysroot and multiarch packages

The cross-toolchain sysroot has glibc 2.34 (from crosstool-NG). Installing Debian
armhf multiarch packages (`libssl-dev:armhf`, etc.) puts glibc 2.36 at
`/lib/arm-linux-gnueabihf/libc.so.6`. If the linker finds the Debian libc instead
of the sysroot libc, linking fails with:

```
libc.so.6: undefined reference to `_dl_audit_symbind_alt@GLIBC_PRIVATE'
libc.so.6: undefined reference to `__rseq_size@GLIBC_2.35'
```

**What doesn't work:**
- `--sysroot=... --extra-ldflags="-L/usr/lib/arm-linux-gnueabihf"` — linker finds
  Debian's libc via the `-L` path, ignoring the sysroot's libc
- Omitting `--sysroot` — same problem, linker defaults to Debian multiarch paths

**What works:** Copy armhf dev headers and libraries INTO the cross-toolchain sysroot,
then compile with `--sysroot` only (no extra `-L` flags). The sysroot's libc 2.34 is
used for linking, and the armhf libs (OpenSSL, zlib, etc.) are found in the sysroot
too. At runtime on the device (glibc 2.38), everything is forward-compatible.

#### Minimal ffmpeg + libcurl from source

Debian's ffmpeg is built with every codec, pulling in 161 transitive .so deps (142MB).
Pianobar only needs AAC/MP3 decoders and HTTP/S streaming. Similarly, Debian's libcurl
links against librtmp (→ gnutls chain), libldap, libkrb5, etc.

**ffmpeg 5.1.6 configure flags (minimal):**
```
--disable-everything
--enable-openssl
--enable-decoder=aac,aac_latm,mp3,mp3float
--enable-demuxer=aac,mp3,mov
--enable-parser=aac,mpegaudio
--enable-protocol=http,https,tcp,tls,file
--enable-filter=volume,aformat,aresample
--enable-swresample --enable-avfilter
--disable-avdevice --disable-postproc --disable-swscale
```

Note: `--enable-filter=abuffer,abuffersink` doesn't match anything (they're built-in,
not optional filters). The warning is harmless.

**libcurl 8.7.1 configure flags (minimal):**
```
--with-openssl --without-librtmp --without-libssh2 --without-libidn2
--without-nghttp2 --without-brotli --without-zstd --without-libpsl
--disable-ldap --disable-ldaps --disable-rtsp --disable-dict
--disable-telnet --disable-tftp --disable-pop3 --disable-imap
--disable-smb --disable-smtp --disable-gopher --disable-mqtt
```

**Result:** 9 shared libraries totaling 3.2MB (vs 161 libs / 142MB with Debian packages).

#### Bundle contents

| Library | Size | Source |
|---------|------|--------|
| libavcodec.so.59 | 552K | ffmpeg from source |
| libavformat.so.59 | 375K | ffmpeg from source |
| libavutil.so.57 | 604K | ffmpeg from source |
| libavfilter.so.8 | 102K | ffmpeg from source |
| libswresample.so.4 | 82K | ffmpeg from source |
| libcurl.so.4 | 534K | curl from source |
| libgcrypt.so.20 | 745K | Debian armhf package |
| libgpg-error.so.0 | 130K | Debian armhf package |
| libjson-c.so.5 | 66K | Debian armhf package |

Transitive deps of all bundled libs resolve to libraries already on device
(libc, libm, libssl, libcrypto, libz, libdl, libpthread, librt).

#### Risk: Debian armhf packages compiled for armv7

`libgcrypt.so.20`, `libgpg-error.so.0`, and `libjson-c.so.5` come from Debian armhf
packages. Debian's armhf baseline is armv7-a (since Debian Wheezy). These libraries
*may* contain armv7-only instructions that SIGILL on armv6.

In practice, libraries with simple logic (json-c, gpg-error) rarely emit armv7
instructions. libgcrypt is higher risk due to optimized crypto routines. If any of
these SIGILL on device, they must be compiled from source for armv6, or we fall back
to Approach B.

### Binary verification

```
readelf -A pianobar:
  Tag_CPU_name: "6KZ"
  Tag_CPU_arch: v6KZ
  Tag_FP_arch: VFPv2
  Tag_CPU_unaligned_access: v6
```

### Build command (pianobar itself)

```bash
PKG_CONFIG_PATH=$SYSROOT/usr/lib/pkgconfig \
make \
    CC="armv6-unknown-linux-gnueabihf-gcc -std=c99 --sysroot=$SYSROOT" \
    CFLAGS="-O2 -DNDEBUG" \
    LDFLAGS="-Wl,--allow-shlib-undefined -Wl,-rpath,/root/pianobar/lib" \
    MINIAUDIO_LDFLAGS="-ldl"
```

No explicit `-I` or `-L` flags needed — `--sysroot` provides both.

## Deployment and smoke test (2026-07-11)

### Initial failure: Illegal instruction (SIGILL)

Deployed binary + 9 `.so` files to `/root/pianobar/` on the Pi Zero W via sftp.
First run crashed immediately with `Illegal instruction`.

### Root cause: Debian armhf packages are NOT armv6-safe

`readelf -A` on the three Debian-sourced libraries revealed:

| Library | Tag_CPU_arch | Source |
|---------|-------------|--------|
| libgcrypt.so.20.4.1 | **v8** | Debian armhf package |
| libgpg-error.so.0.33.1 | **v7** | Debian armhf package |
| libjson-c.so.5.2.0 | **v7** | Debian armhf package |
| libavcodec.so.59 | v6KZ | built from source |
| libcurl.so.4 | v6KZ | built from source |
| pianobar | v6KZ | built from source |

**Key insight:** Debian's "armhf" architecture has a minimum baseline of ARMv7-A
(not ARMv6). Packages may contain ARMv7 or even ARMv8 instructions, especially
libraries with hand-optimized assembly (like libgcrypt's cryptographic routines).
You cannot assume any Debian armhf `.so` is safe to run on ARMv6 hardware.

### Fix: compile all bundled libraries from source

Updated `Dockerfile.armv6` to build libgpg-error, libgcrypt, and json-c from source
with explicit armv6 flags:

**libgpg-error 1.47:**
```
./configure --host=armv6-unknown-linux-gnueabihf \
  CFLAGS="--sysroot=$SYSROOT -march=armv6 -mfpu=vfp -mfloat-abi=hard"
```

**libgcrypt 1.10.3 (critical: `--disable-asm`):**
```
./configure --host=armv6-unknown-linux-gnueabihf \
  --disable-asm \
  CFLAGS="--sysroot=$SYSROOT -march=armv6 -mfpu=vfp -mfloat-abi=hard"
```

The `--disable-asm` flag is essential — without it, libgcrypt uses hand-written
ARMv8 NEON/crypto-extension assembly for AES, SHA, etc. These instructions cause
SIGILL on ARMv6. The C fallback implementations work correctly on all ARM variants.

**json-c 0.17 (cmake):**
```
cmake -DCMAKE_C_COMPILER=armv6-unknown-linux-gnueabihf-gcc \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
  -DCMAKE_C_FLAGS="-march=armv6 -mfpu=vfp -mfloat-abi=hard"
```

### Verification after fix

All libraries now show `Tag_CPU_arch: v6KZ`:
```
readelf -A libgcrypt.so.20.4.3   → Tag_CPU_arch: v6KZ, Tag_FP_arch: VFPv2
readelf -A libgpg-error.so.0.34.0 → Tag_CPU_arch: v6KZ, Tag_FP_arch: VFPv2
readelf -A libjson-c.so.5.3.0    → Tag_CPU_arch: v6KZ, Tag_FP_arch: VFPv2
```

Binary runs on device: prints `Welcome to pianobar (2024.12.21-dev)!`

### Device state after deployment

- No ALSA sound card present (`/proc/asound/cards` → empty)
- Audio playback requires USB DAC, I2S HAT, or `audio_pipe` config
- Pandora login not yet tested (requires credentials)

---

## Lessons learned

1. **Always verify `readelf -A` on EVERY bundled `.so`** — not just the main binary.
   A single armv7+ library in the bundle will SIGILL on armv6.

2. **Debian armhf ≠ ARMv6.** The Debian armhf port targets ARMv7-A minimum. Libraries
   from Debian armhf packages may freely use ARMv7 or even ARMv8 instructions,
   especially in optimized assembly paths (crypto, SIMD, etc.).

3. **libgcrypt's `--disable-asm` is the critical flag.** Without it, libgcrypt's
   configure detects "ARM" and enables ARMv8 crypto-extension assembly. The resulting
   library has `Tag_CPU_arch: v8` — completely incompatible with ARMv6. The C fallback
   is ~30-40% slower but functionally correct on all ARM variants.

4. **Build everything from source for armv6 targets.** The only safe libraries to
   take from Debian armhf are those that will NOT be bundled (i.e., those already on
   the target device, like libssl/libcrypto which were compiled by the Nerves/Buildroot
   toolchain for the correct architecture).

5. **`-march=armv6 -mfpu=vfp -mfloat-abi=hard`** — these three flags together ensure
   the compiler generates only ARMv6 instructions with VFPv2 floating point. Omitting
   `-march` lets the compiler default to whatever the toolchain was built for.
