# Handoff: Deploy armv6 pianobar to Pi Zero W and smoke test

## Goal

Deploy the cross-compiled armv6 pianobar binary + shared libraries to the Nerves device and verify it runs.

## What's done

- ARMv6 cross-compilation fully working: `./cross-build-armv6.sh` produces a valid binary
- Binary verified: `Tag_CPU_arch: v6KZ`, `Tag_FP_arch: VFPv2` (compatible with ARM1176JZF-S)
- Library bundle: 9 .so files, 3.2MB total, all transitive deps satisfied
- Files ready to deploy: `pianobar` binary + `armv6-libs/` directory in repo root
- Docker image `pianobar-armv6-cross` cached locally (no rebuild needed)
- Full experimental results documented in `docs/plans/option-a-dockcross.md` (ARMv6 retarget section)

## What the next session should do

### 1. Deploy via sftp

```bash
sftp 172.31.219.153 <<'EOF'
mkdir /root/pianobar
mkdir /root/pianobar/lib
put pianobar /root/pianobar/pianobar
put armv6-libs/libavcodec.so.59.37.100 /root/pianobar/lib/
put armv6-libs/libavformat.so.59.27.100 /root/pianobar/lib/
put armv6-libs/libavutil.so.57.28.100 /root/pianobar/lib/
put armv6-libs/libavfilter.so.8.44.100 /root/pianobar/lib/
put armv6-libs/libswresample.so.4.7.100 /root/pianobar/lib/
put armv6-libs/libcurl.so.4.8.0 /root/pianobar/lib/
put armv6-libs/libgcrypt.so.20.4.1 /root/pianobar/lib/
put armv6-libs/libgpg-error.so.0.33.1 /root/pianobar/lib/
put armv6-libs/libjson-c.so.5.2.0 /root/pianobar/lib/
EOF
```

### 2. Create soname symlinks + set permissions (via Elixir SSH)

```bash
ssh 172.31.219.153 '
for {soname, target} <- [
  {"libavcodec.so.59", "libavcodec.so.59.37.100"},
  {"libavformat.so.59", "libavformat.so.59.27.100"},
  {"libavutil.so.57", "libavutil.so.57.28.100"},
  {"libavfilter.so.8", "libavfilter.so.8.44.100"},
  {"libswresample.so.4", "libswresample.so.4.7.100"},
  {"libcurl.so.4", "libcurl.so.4.8.0"},
  {"libgcrypt.so.20", "libgcrypt.so.20.4.1"},
  {"libgpg-error.so.0", "libgpg-error.so.0.33.1"},
  {"libjson-c.so.5", "libjson-c.so.5.2.0"}
] do
  File.ln_s!(target, "/root/pianobar/lib/#{soname}")
end
File.chmod!("/root/pianobar/pianobar", 0o755)
'
```

### 3. Smoke test

```bash
ssh 172.31.219.153 ':os.cmd(~c"LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar --help") |> IO.puts()'
```

**If it prints help text** → binary runs, proceed to test actual Pandora login.

**If `Illegal instruction`** → one of the Debian armhf libraries (libgcrypt, libgpg-error, or libjson-c) contains armv7 instructions. Fix: compile those from source inside the Docker container for armv6. libgcrypt is the most likely culprit (optimized crypto routines).

**If `error while loading shared libraries`** → a soname symlink is missing or a transitive dep not on device. Check the error message for which library, then either bundle it or verify it exists on device.

### 4. Test Pandora login (if smoke test passes)

Create a config file and attempt a real login:
```bash
ssh 172.31.219.153 '
File.write!("/root/pianobar/config", """
user = <pandora email>
password = <pandora password>
audio_quality = low
\n""")
'
```

Then run (will need an interactive terminal or `eventCmd` approach):
```bash
ssh 172.31.219.153 ':os.cmd(~c"LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar --config /root/pianobar/config 2>&1") |> IO.puts()'
```

If login fails with "network error" or DNS resolution hangs, it's likely the glibc NSS mismatch issue (sysroot glibc 2.34 vs device glibc 2.38). The binary is linked against glibc 2.34 symbols, which should be forward-compatible, but NSS module loading can fail. In that case, fall back to Approach B (Buildroot).

## Remote shell notes

- SSH exec channel runs **Elixir code**, not shell. Use `:os.cmd(~c"shell command")` for system calls.
- `sftp` subsystem works for file transfer. Standard `scp` does NOT work.
- `File.chmod!/2`, `File.write!/2`, `File.ln_s!/2`, `File.rm/1` work for filesystem ops.
- No standard shell utils in PATH — use Elixir equivalents or full paths.
- Writable path: `/root/` (ext4, 13.5G free, exec OK)

## Key files

- `docs/STATUS.md` — single source of truth for project status
- `docs/plans/option-a-dockcross.md` — full experimental results (ARMv6 retarget section)
- `Dockerfile.armv6` — Docker image with minimal ffmpeg + curl built from source
- `cross-build-armv6.sh` — build script (compiles + collects libs)
- `armv6-libs/` — shared libraries ready to deploy (3.2MB)
- `.claude/settings.local.json` — has ssh/scp/sftp permissions for `172.31.219.153`

## Risks

1. **Debian armhf libs may SIGILL on armv6** — libgcrypt, libgpg-error, libjson-c come from Debian packages (armv7 baseline). If they SIGILL, compile from source for armv6.
2. **NSS/DNS resolution** — binary linked against glibc 2.34; device has 2.38. Forward-compatible for symbols, but NSS module loading can be version-sensitive.
3. **OpenSSL version** — our libcurl links against the device's libssl.so.3 / libcrypto.so.3. Should work (both OpenSSL 3.0.x), but if symbol versions don't match, must bundle OpenSSL too.
4. **Audio output** — even if the binary runs, audio playback requires ALSA (libasound.so.2 on device). Verify ALSA device exists: `:os.cmd(~c"cat /proc/asound/cards") |> IO.puts()`.
