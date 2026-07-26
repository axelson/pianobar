# Handoff: Cross-compile pianobar for ARMv6 hard-float

## Goal

Cross-compile pianobar for a Raspberry Pi Zero W (ARMv6hf) running Nerves, then deploy and smoke-test on the device.

## Context

This is "Option A" from `docs/STATUS.md` — cross-compile + copy libs to the device's writable partition.

## What's done

- Device probed at `172.31.219.153` (see `docs/STATUS.md` log entry 2026-07-11)
- Existing armv7 cross-build infrastructure works: `Dockerfile.armv7`, `cross-build-armv7.sh`, `dockcross-armv7-cross`
- Confirmed: sftp upload works, `/root/` is writable+executable (13.5G free)
- SSH permissions added to `.claude/settings.local.json` for `172.31.219.153`

## Critical finding: Architecture mismatch

The device is ARMv6 (ARM1176JZF-S, Pi Zero W), NOT ARMv7. The existing build targets armv7 and will SIGILL. Must retarget.

## Device specs (verified)

| Property | Value |
|----------|-------|
| CPU | ARM1176JZF-S (ARMv6, VFPv2, hard-float) |
| Toolchain used to build kernel | `armv6-nerves-linux-gnueabihf-gcc` 13.2.0 |
| glibc | 2.38 |
| Kernel | Linux 6.1.73 |
| BEAM arch | `arm-buildroot-linux-gnueabihf` |
| Writable path | `/root/` (ext4, 13.5G free) |
| Dynamic linker | `/lib/ld-linux-armhf.so.3` |

## What the next session should do

### 1. Create armv6hf cross-compilation setup

Options (pick one):
- **`dockcross/linux-armv6`** — check if this image exists on Docker Hub. If so, model after `Dockerfile.armv7` but with this base.
- **Modify existing Dockerfile** — change compiler flags to `-march=armv6 -mfpu=vfp -mfloat-abi=hard` while keeping the Debian armhf package repos for deps (they're compatible with armv6hf).
- **Raspberry Pi cross-toolchain** — `arm-linux-gnueabihf-gcc` from Raspberry Pi tools repo with explicit `-march=armv6`.

The Debian `armhf` multiarch packages (used in `Dockerfile.armv7` for `-dev` headers) target armv7 by default. If using those packages' prebuilt `.so` files on the device, they may also SIGILL. Safest approach: compile everything from source for armv6, OR verify that the specific libs (ffmpeg, curl, gcrypt, json-c) don't use armv7-only instructions in practice.

### 2. Build

Create `Dockerfile.armv6` and `cross-build-armv6.sh` (or modify existing files). Verify with `readelf -A` that the output binary has `Tag_CPU_arch: v6` (not v7).

### 3. Collect shared libraries

From inside the build container, enumerate transitive deps of the pianobar binary:
```bash
ldd pianobar   # or: readelf -d pianobar | grep NEEDED, then recurse
```

Libs already on device (do NOT bundle): `libc`, `libm`, `libdl`, `libpthread`, `libresolv`, `ld-linux-armhf`, `libasound.so.2`, `libssl.so.3`, `libcrypto.so.3`, `libz.so.1`, `libgcc_s`, `libstdc++`

Must bundle: `libavcodec`, `libavformat`, `libavutil`, `libavfilter`, `libcurl`, `libgcrypt`, `libgpg-error`, `libjson-c` + any transitive deps not in the "already on device" list.

### 4. Deploy via sftp

```bash
sftp 172.31.219.153 <<'EOF'
mkdir /root/pianobar
mkdir /root/pianobar/lib
put pianobar /root/pianobar/pianobar
put lib/* /root/pianobar/lib/
EOF
```

Then chmod via Elixir:
```bash
ssh 172.31.219.153 'File.chmod!("/root/pianobar/pianobar", 0o755)'
```

### 5. Smoke test

```bash
ssh 172.31.219.153 ':os.cmd(~c"LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar --help") |> IO.puts()'
```

If it prints help text, the binary runs. If `Illegal instruction`, the armv6 targeting failed.

## Remote shell notes

- SSH exec channel runs **Elixir code**, not shell. Use `:os.cmd(~c"shell command")` for system calls.
- No standard shell utils (`uname`, `chmod`, `file`, `ls` etc.) — they're not in PATH. Use full paths or Elixir equivalents.
- `sftp` subsystem works for file transfer. Standard `scp` does NOT work.
- `File.chmod!/2`, `File.write!/2`, `File.rm/1` etc. work for filesystem ops.

## Key files

- `docs/STATUS.md` — single source of truth for project status
- `docs/plans/option-a-dockcross.md` — Option A plan + implementation notes
- `Dockerfile.armv7` — existing cross-build Docker image (needs armv6 variant)
- `cross-build-armv7.sh` — existing build script (model for armv6 version)
- `.claude/settings.local.json` — has ssh/scp/sftp permissions for `172.31.219.153`

## Risks

1. Debian armhf `.so` files may be compiled for armv7 (Debian armhf baseline is armv7). If bundled libs SIGILL, must either compile deps from source for armv6 or switch to Approach B (Buildroot).
2. glibc version mismatch: container glibc must be <= 2.38 (device version). Debian Bookworm has glibc 2.36 which is fine.
3. NSS/DNS resolution may fail if bundled glibc NSS modules don't match device's glibc. Don't bundle libc/nss — use device's.
4. OpenSSL version: device has OpenSSL 3. If libcurl is linked against a different OpenSSL, must bundle that too or link against device's.
