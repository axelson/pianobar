# Nerves Port Status

Goal: run pianobar on an Elixir Nerves (Buildroot-based) rpi3 device.

Strategy: **Option A** (dockcross cross-compile + copy libs into rootfs overlay) first,
because it is less maintenance over time. If it doesn't pan out, fall back to
**Approach B** (custom Nerves system with a Buildroot external package).

> **Maintenance policy:** This file is the single source of truth for project status.
> Update "Current status" and add a dated Log entry at the end of each working session.
> Keep detailed experimental notes in per-approach docs (see References) — STATUS.md
> only summarizes and links. When the Log section exceeds ~100 lines, move the oldest
> entries to `docs/STATUS-archive.md` (create it if missing) and leave a pointer here.

## Current status

**Option A — in progress (arch mismatch discovered)**
- [x] dockcross container + custom armhf image (`Dockerfile.armv7`, `./dockcross-armv7-cross`)
- [x] Cross-compiled ARM32 binary builds (`./cross-build-armv7.sh`)
- [x] Binary verified: valid ARM32 ELF, dynamically linked (static linking ruled out)
- [x] Device probed: Pi Zero W (ARMv6), glibc 2.38, writable `/root/` partition (13.5G)
- ~~**BLOCKER:** device is ARMv6, build targets ARMv7 — must retarget~~
- [x] Retarget cross-compilation for armv6hf (`Dockerfile.armv6`, `cross-build-armv6.sh`)
- [x] Minimal ffmpeg from source (AAC/MP3 only) + minimal libcurl (HTTP/S only) — 3.2MB bundle
- [x] Collect required `.so` files (+ transitive deps) — all deps satisfied
- [x] Build libgcrypt, libgpg-error, libjson-c from source (Debian armhf packages were armv7/v8)
- [x] Deploy binary + libs to device via sftp to `/root/pianobar/`
- [x] Smoke test on device: binary loads and prints welcome banner
- [ ] Test Pandora login (requires credentials in config)
- [ ] Test audio playback (requires USB DAC or I2S HAT — no sound card on device currently)

**Approach B — not started** (fallback)
- [ ] Fork/customize `nerves_system_rpi3`, add `BR2_EXTERNAL` pianobar package
- [ ] Verify ffmpeg version in target `nerves_system_br` release (pianobar needs ≤ 5.1)
- Experimental notes will live in `docs/plans/approach-b-buildroot.md` (create when started)

### Option A — next steps detail

**Architecture:** ~~device is ARMv6 (ARM1176JZF-S, Pi Zero W), NOT ARMv7 as initially assumed.~~
Resolved: using `dockcross/linux-armv6` with `armv6-unknown-linux-gnueabihf-gcc` (GCC 11.3.0).
Binary verified as `Tag_CPU_arch: v6KZ`, `Tag_FP_arch: VFPv2`.

**Bundle (4.1MB total):** All 9 libraries built from source for armv6. Libraries:
libgcrypt (1.5M), libavutil (604K), libavcodec (552K), libcurl (534K),
libavformat (375K), libgpg-error (205K), libjson-c (202K), libavfilter (102K),
libswresample (82K). All transitive deps resolved (none missing).

**Deploy layout** (sftp to writable partition):
- binary → `/root/pianobar/pianobar`
- libs → `/root/pianobar/lib/`
- Run with: `LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar`

**File transfer:** sftp works (SFTP subsystem enabled). Standard `scp` does NOT work
because Nerves SSH exec channel evaluates Elixir, not shell commands.

**Remote shell:** SSH exec runs Elixir REPL. Use `:os.cmd(~c"...")` for system commands.
No standard utils (`uname`, `chmod`, etc.) — use Elixir `File.*` for filesystem ops.

If login fails with a network error on device, that's the glibc NSS mismatch —
documented fallbacks are the Nerves staging sysroot (Option A2) or Approach B.

## References

- `docs/plans/option-a-dockcross.md` — Option A plan + implementation notes (steps 1–5 done)
- `docs/reports/nerves-cross-compilation.md` — rationale, Approach A vs B comparison
- `docs/reports/zig-cross-compilation.md` — earlier zig-based exploration

## Log

### 2026-03-29
- Executed Option A steps 1–5. Binary builds and is a valid ARM32 ELF.
- Static linking abandoned: Debian's ffmpeg expands to 80+ `-l` flags under
  `pkg-config --static`; Makefile flag ordering also defeats `-Bstatic`.
  Details in `docs/plans/option-a-dockcross.md` → Implementation notes.

### 2026-07-11 (session 1)
- Decided: pursue Option A first (less maintenance over time); Approach B is the fallback.
- Created this STATUS.md with maintenance/archiving policy.
- Probed Nerves device at 172.31.219.153:
  - **Hardware:** Raspberry Pi Zero W Rev 1.1 (BCM2835, ARM1176JZF-S = ARMv6)
  - **Kernel:** Linux 6.1.73, compiled with `armv6-nerves-linux-gnueabihf-gcc` 13.2.0
  - **glibc:** 2.38 (crosstool-NG)
  - **Nerves:** Buildroot 2024.02.1, System BR 1.27.2
  - **Writable storage:** `/root/` (ext4, 13.5G free, exec OK)
  - **File transfer:** sftp works; scp/exec are Elixir-only
  - **BLOCKER:** armv7 binary won't run — device is armv6. Must retarget build.

### 2026-07-11 (session 2)
- Resolved armv6 cross-compilation: `Dockerfile.armv6` + `cross-build-armv6.sh`
- Used `dockcross/linux-armv6` base (GCC 11.3.0, glibc 2.34 sysroot, Bookworm)
- Key challenge: Debian armhf multiarch packages install glibc 2.36 which conflicts
  with the cross-toolchain's sysroot libc 2.34. Solved by copying armhf dev headers
  and libraries INTO the cross-toolchain sysroot instead of using `-L` flags.
- Built minimal ffmpeg 5.1.6 from source: only AAC/MP3 decoders, HTTP/HTTPS protocol,
  volume/aformat/aresample filters. Reduces ffmpeg deps from 161 libs (142MB) to 5 libs.
- Built minimal libcurl 8.7.1 from source: HTTP/HTTPS via OpenSSL only (no LDAP,
  Kerberos, RTMP, SSH2, brotli, zstd, libpsl, libidn2). No transitive deps beyond
  libssl/libcrypto/libz (all on device).
- Binary verified: `Tag_CPU_arch: v6KZ`, `Tag_FP_arch: VFPv2`
- Total bundle: 3.2MB (binary + 9 shared libs). All dependencies satisfied.
- **Next:** deploy via sftp + smoke test on device.

### 2026-07-11 (session 3)
- Deployed to device — initial smoke test: `Illegal instruction` (SIGILL).
- Root cause: Debian armhf packages for libgcrypt (ARMv8!), libgpg-error (ARMv7),
  and libjson-c (ARMv7) contain instructions incompatible with ARMv6.
- Fix: compiled all three from source in Docker image (`Dockerfile.armv6`):
  - libgpg-error 1.47 with `-march=armv6 -mfpu=vfp -mfloat-abi=hard`
  - libgcrypt 1.10.3 with `--disable-asm` (key fix — avoids ARMv8 crypto assembly)
  - json-c 0.17 via cmake cross-compilation
- Redeployed — **binary runs successfully on device**, prints welcome banner.
- All 9 bundled libraries now verified armv6 (`Tag_CPU_arch: v6KZ`).
- Bundle size increased from 3.2MB to 4.1MB (libgcrypt larger without ASM optimizations).
- No sound card on device (`/proc/asound/cards` empty) — need USB DAC or I2S HAT for audio.
- **Next:** test Pandora login, set up audio output.
