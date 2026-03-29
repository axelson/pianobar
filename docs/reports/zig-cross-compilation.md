# Report: Zig-based cross-compilation for Nerves rpi3

## Summary

Zig offers two distinct things relevant to this problem:

1. **`zig cc`** — a drop-in C compiler with built-in cross-compilation and bundled musl libc. No rewrite required.
2. **A full Zig rewrite** — replacing pianobar's C code with Zig. Theoretical but not practical given the ffmpeg dependency.

The useful option is `zig cc`. A full rewrite is not warranted.

---

## What `zig cc` provides

Zig ships a complete, self-contained LLVM-based C/C++ toolchain. Cross-compilation requires no Docker, no Debian multiarch, no separate sysroot — just specifying a target triple:

```bash
zig cc -target arm-linux-musleabihf -o pianobar src/*.c ...
```

Key properties:
- **musl is bundled**: Zig includes musl libc for all targets. `-target arm-linux-musleabihf` produces a musl-linked binary. The glibc NSS `dlopen` problem (documented in the cross-compilation report) does not apply.
- **Static by default**: musl binaries can be fully statically linked with no runtime surprises.
- **No external toolchain**: Install Zig, get cross-compilation. Contrast with dockcross which requires Docker and Debian package management.
- **Drop-in for Makefile**: The pianobar Makefile accepts `CC=` as an override. `zig cc` is a standards-compliant C99 compiler and handles the existing pianobar source without modification.

---

## Applying `zig cc` to pianobar

### The compiler itself: trivial

```bash
make CC="zig cc -target arm-linux-musleabihf" \
     CFLAGS="-O2 -DNDEBUG -std=c99 -DMA_NO_RUNTIME_LINKING" \
     LDFLAGS="-static"
```

`MA_NO_RUNTIME_LINKING` is required to prevent miniaudio from using `dlopen` for its ALSA backend — without it, miniaudio loads `libasound.so.2` at runtime regardless of static link flags, and the static binary silently has no audio. With the flag set, miniaudio links ALSA at compile time and `-static` captures it correctly.

### The dependencies: still require source builds

`zig cc` does not provide ffmpeg, libcurl, libgcrypt, or json-c. These must be built from source with `zig cc` as the compiler. The dockcross approach could use apt packages for these; `zig cc` cannot. This is the main tradeoff.

Each dependency supports `CC=` overrides in its build system:

**ffmpeg:**
```bash
./configure \
  --cc="zig cc -target arm-linux-musleabihf" \
  --enable-cross-compile \
  --arch=arm --target-os=linux \
  --enable-static --disable-shared \
  --disable-programs --disable-doc \
  --enable-decoder=aac --enable-demuxer=mov \
  --enable-protocol=http,https,tcp \
  --enable-filter=volume,aformat,aresample \
  --disable-everything-else   # (use actual flags)
make
```

Building a minimal ffmpeg with only the features pianobar uses produces a significantly smaller static archive than a full ffmpeg build. The required surface area is narrow: AAC decoder, MOV/MP4 demuxer, HTTP/HTTPS/TCP protocols, volume/aformat/aresample filters.

**libcurl:**
```bash
./configure \
  --host=arm-linux-musleabihf \
  CC="zig cc -target arm-linux-musleabihf" \
  --enable-static --disable-shared \
  --with-mbedtls   # or --with-openssl, built the same way
```

**libgpg-error + libgcrypt:**
```bash
# libgpg-error first (libgcrypt dependency)
./configure --host=arm-linux-musleabihf \
  CC="zig cc -target arm-linux-musleabihf" \
  --enable-static --disable-shared

# then libgcrypt
./configure --host=arm-linux-musleabihf \
  CC="zig cc -target arm-linux-musleabihf" \
  --with-libgpg-error-prefix=... \
  --enable-static --disable-shared
```

**json-c** (CMake):
```bash
cmake -DCMAKE_C_COMPILER="zig cc -target arm-linux-musleabihf" \
      -DBUILD_SHARED_LIBS=OFF ...
```

**ALSA** (if using live audio rather than `audio_pipe`):
```bash
./configure --host=arm-linux-musleabihf \
  CC="zig cc -target arm-linux-musleabihf" \
  --enable-static --disable-shared
```

### `audio_pipe` as an alternative to ALSA

pianobar's `audio_pipe` setting writes raw PCM to a named FIFO instead of opening an audio device. If the Nerves system routes audio through an external process reading that FIFO (e.g. a small Elixir GenServer feeding a hardware driver), ALSA is not needed at all. This eliminates one source build and reduces the static binary's complexity.

---

## Comparison: `zig cc` vs. dockcross

| | dockcross (Option A) | zig cc |
|---|---|---|
| Toolchain setup | Docker + `dpkg --add-architecture armhf` | `brew install zig` |
| ffmpeg | apt package (if version ≤ 5.1) | Build from source |
| libcurl / libgcrypt / json-c | apt package | Build from source |
| Static linking | Partial (glibc limitation) | Full (musl, no NSS issue) |
| glibc DNS risk | Yes | No |
| ALSA `dlopen` issue | Yes (needs `MA_NO_RUNTIME_LINKING`) | Yes (same fix applies) |
| Binary portability | Depends on target glibc version | Self-contained |
| Total build time | Fast (apt packages) | Slower (source builds) |

If the dockcross apt packages are the right ffmpeg version, dockcross is faster to execute. If ffmpeg needs to be built from source anyway (version mismatch, or wanting a minimal build), `zig cc` is the cleaner path: simpler toolchain setup and a genuinely portable static binary.

---

## Full Zig rewrite: not practical

A Zig rewrite would allow using Zig's native package manager and avoiding C interop for the application logic. However:

- **No mature ffmpeg bindings exist for Zig.** ffmpeg's API surface is large and its C headers use patterns (function pointers in structs, complex macros, codec-specific data structures) that require careful wrapping. This is months of work.
- **No pure-Zig AAC decoder exists.** Replacing ffmpeg's decode pipeline would require either: binding to fdk-aac or faad2 (still C interop), or implementing AAC decoding in Zig (not a reasonable scope).
- **miniaudio works fine via C interop.** It is a single-header C library. `@cImport` handles it trivially in Zig.

The conclusion is that `zig cc` provides all of Zig's cross-compilation benefits applied to the existing C codebase, with no rewrite needed and no loss of functionality.

---

## Verdict

`zig cc` is a viable and arguably superior alternative to dockcross for building a static pianobar binary, provided the additional time to build ffmpeg (and other deps) from source is acceptable. It eliminates the glibc DNS risk entirely and produces a truly portable binary with no dependency on the Nerves system's shared libraries. The toolchain setup is significantly simpler.

The decision point is ffmpeg: if dockcross's apt ffmpeg is version-compatible (≤ 5.1), dockcross is faster. If a source build of ffmpeg is needed regardless, `zig cc` is the better choice.
