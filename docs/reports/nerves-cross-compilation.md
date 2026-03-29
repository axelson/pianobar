# Report: Cross-Compiling pianobar for Nerves/RPi3

## Target System

**System**: [nerves-project/nerves_system_rpi3](https://github.com/nerves-project/nerves_system_rpi3)
**Buildroot version**: nerves_system_br 1.33.4
**Architecture triple**: `armv7-nerves-linux-gnueabihf`
**CPU**: Cortex-A53 (ARMv8 core, running in 32-bit ARMv7 mode)
**ABI**: EABIHF (hard-float), FPU: NEON with fp-armv8 (`BR2_ARM_FPU_NEON_FP_ARMV8=y`)

### Audio subsystem on target

The base nerves_system_rpi3 includes ALSA (`alsa-lib`, `alsa-utils`). This is relevant because miniaudio's Linux backend uses ALSA. The miniaudio `audio_pipe` mode (raw PCM to a named FIFO) is an alternative that requires no audio subsystem at all and may be preferable for headless operation.

### Packages NOT in the base system

The following pianobar dependencies are absent from the default `nerves_defconfig` and must be added:

| Package | Buildroot config key |
|---|---|
| ffmpeg (≤ 5.1) | `BR2_PACKAGE_FFMPEG` |
| libcurl (≥ 7.32.0) | `BR2_PACKAGE_LIBCURL` |
| libgcrypt | `BR2_PACKAGE_LIBGCRYPT` |
| json-c | `BR2_PACKAGE_JSON_C` |

miniaudio is header-only and vendored in `include/`, so it requires no buildroot package.

### Buildroot pianobar package

There is no pianobar package in buildroot mainline (confirmed against the official buildroot GitLab mirror as of 2026). A custom external package must be written.

---

## Approach A: Static binary via `dockcross`

### How it works

[dockcross](https://github.com/dockcross/dockcross) provides Docker images with pre-configured ARM cross-compilation toolchains. `dockcross/linux-armv7` matches the Nerves target ABI. The pianobar Makefile accepts `CC`, `CFLAGS`, `LDFLAGS`, and `PKG_CONFIG` overrides, so it can be driven from outside without modification.

### Evidence it can work

- The pianobar Makefile's CC-detection block (`ifeq (${CC},cc)`) is skipped when `CC` is explicitly set by the host environment, which dockcross does.
- All dependencies (ffmpeg, libcurl, libgcrypt, json-c) have Debian/Ubuntu packages for the `armhf` architecture, available inside the dockcross container via `apt-get`.
- Passing `LDFLAGS="-static"` to `gmake` is the only change needed to attempt static linking.

### Why full static linking is problematic

A truly static binary requires static archives (`.a`) for every dependency. The obstacles are:

1. **glibc resistsstatic linking**: `libnss` (used by libcurl for DNS) and `libpthread` can be linked statically, but glibc's `getaddrinfo()` dynamically loads `libnss_*.so` at runtime regardless of link flags. The binary will link but fail at runtime when connecting to Pandora's API.

2. **ALSA**: miniaudio's ALSA backend (`ma_backend_alsa`) opens `libasound.so` via `dlopen()` at runtime (dynamic backend loading). Static linking cannot capture this; the miniaudio `audio_pipe` mode avoids ALSA entirely and is fully static-link compatible.

3. **ffmpeg + libcurl static archives**: These are large and not installed by default. Building them from source for ARM adds significant complexity.

### Verdict

Viable for a dynamically-linked cross-compiled binary. Not suitable for a truly static binary unless using musl libc (see below) or the `audio_pipe` mode with direct Pandora audio-URL fetching bypassing miniaudio entirely.

### musl variant

`dockcross/linux-armv7-musl` uses the musl C library, which supports full static linking. musl's `getaddrinfo()` does not use `dlopen()`, and miniaudio can be configured with `MA_NO_RUNTIME_LINKING` to avoid `dlopen()` for its backends. This path requires building ffmpeg, libcurl, libgcrypt, and json-c from source against musl — feasible but time-consuming.

---

## Approach B: Custom Nerves system with buildroot external package (recommended)

### How it works

Nerves supports [BR2_EXTERNAL](https://buildroot.org/downloads/manual/manual.html#outside-br-custom) — buildroot's mechanism for injecting custom packages from outside the buildroot tree. A custom system forks nerves_system_rpi3, enables the missing dependencies in `nerves_defconfig`, and adds a `packages/pianobar/` directory containing a `.mk` build recipe and `Config.in` menu entry.

Buildroot then:
1. Cross-compiles all dependencies for `armv7-nerves-linux-gnueabihf`
2. Installs them into a staging sysroot
3. Builds pianobar against that sysroot using the Nerves toolchain
4. Installs the binary into the target rootfs

### Evidence it is correct

- The pianobar Makefile uses `$(CC)`, `$(PKG_CONFIG)`, `$(CFLAGS)`, and `$(LDFLAGS)` — all of which buildroot sets via `TARGET_CONFIGURE_OPTS` and the staging sysroot's pkg-config. No Makefile modifications are needed.
- The `-std=c99` flag that the Makefile normally appends to `CC` can be supplied via `CFLAGS` in the `.mk` recipe instead, since buildroot sets `CC` to the cross-compiler directly (bypassing the Makefile's OS-detection block).
- ffmpeg, libcurl, libgcrypt, and json-c all have mature buildroot packages with correct cross-compilation support.
- The nerves_system_rpi3 base already includes ALSA, so miniaudio's Linux backend will have its runtime dependency satisfied.

### Static linking in this context

Buildroot supports a fully-static target via `BR2_STATIC_LIBS=y`, but this applies system-wide and is uncommon in Nerves systems. For pianobar specifically, static linking is **not necessary**: the shared libraries (ffmpeg, libcurl, etc.) live in the Nerves rootfs alongside the binary and are flashed as a single image. There is no deployment speed difference — the entire firmware image is transferred atomically. Static linking would duplicate library code across binaries and increase the overall firmware size.

### Key files to create

```
custom_rpi3/
├── nerves_defconfig        # add BR2_PACKAGE_FFMPEG, LIBCURL, LIBGCRYPT, JSON_C, PIANOBAR
├── Config.in               # add: source "$BR2_EXTERNAL_.../packages/pianobar/Config.in"
├── external.mk             # add: include $(wildcard .../packages/*/*.mk)
└── packages/
    └── pianobar/
        ├── Config.in       # bool "pianobar", depends on ffmpeg/libcurl/libgcrypt/json-c
        └── pianobar.mk     # GENERIC_PACKAGE using TARGET_CONFIGURE_OPTS
```

### ffmpeg version constraint

pianobar requires ffmpeg ≤ 5.1 (uses APIs removed in 6.0). The ffmpeg version in buildroot depends on the nerves_system_br release. This must be verified when selecting the buildroot configuration; it may require pinning the ffmpeg package version in the custom system.

### Build workflow

```bash
cd custom_rpi3
mix nerves.system.shell   # enter buildroot shell
make menuconfig           # enable BR2_PACKAGE_PIANOBAR and deps
make savedefconfig        # write back to nerves_defconfig
exit
mix firmware              # full build (~15–30 min first time)
```

### Verdict

Correct approach. Handles all cross-compilation automatically, produces a binary that works with the target's shared library environment, and integrates cleanly with the Nerves firmware build pipeline.

---

## Summary

| | Approach A (dockcross) | Approach B (buildroot package) |
|---|---|---|
| Setup effort | Low | Medium |
| Correctness | Medium (dynamic link works; static has glibc/ALSA issues) | High |
| Maintainability | Manual | Integrated with firmware build |
| Static binary | Only with musl variant + extra work | Not needed; unnecessary in Nerves |
| Audio backend | Must use `audio_pipe` for static, or dynamic ALSA | ALSA (already in base system) |
| Recommended for | Quick one-off test binary | Production use |
