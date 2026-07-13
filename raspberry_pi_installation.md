# Pianobar on Raspberry Pi (Nerves)

Running pianobar on a Raspberry Pi with Elixir Nerves.

## Prerequisites

- Raspberry Pi 3 Model B+ (ARMv7) or Pi Zero W (ARMv6)
- Nerves firmware with SSH enabled
- Audio output (3.5mm jack, USB DAC, or I2S HAT)
- Docker on the build machine (macOS or Linux)

## Building

### ARMv7 (Pi 3B+, Pi 4, etc.)

```bash
./cross-build-armv7.sh
```

This produces a `pianobar` binary and uses pre-built libraries from `armv6-libs/` (ARMv6 binaries are forward-compatible with ARMv7).

### ARMv6 (Pi Zero W)

```bash
./cross-build-armv6.sh
```

This builds a minimal ffmpeg, libcurl, libgcrypt, libgpg-error, and libjson-c from source (to avoid ARMv7/v8 instructions in Debian packages). Output goes to `pianobar` + `armv6-libs/`.

## Deploying

Nerves SSH exec evaluates Elixir, not shell commands. Use `sftp` for file transfer and SSH with Elixir expressions for commands.

### Upload binary and libraries

```bash
sftp PI_IP <<'EOF'
mkdir /root/pianobar
mkdir /root/pianobar/lib
put pianobar /root/pianobar/pianobar
put armv6-libs/libavcodec.so.59.37.100 /root/pianobar/lib/
put armv6-libs/libavformat.so.59.27.100 /root/pianobar/lib/
put armv6-libs/libavutil.so.57.28.100 /root/pianobar/lib/
put armv6-libs/libavfilter.so.8.44.100 /root/pianobar/lib/
put armv6-libs/libswresample.so.4.7.100 /root/pianobar/lib/
put armv6-libs/libcurl.so.4.8.0 /root/pianobar/lib/
put armv6-libs/libgcrypt.so.20.4.3 /root/pianobar/lib/
put armv6-libs/libgpg-error.so.0.34.0 /root/pianobar/lib/
put armv6-libs/libjson-c.so.5.3.0 /root/pianobar/lib/
EOF
```

### Create symlinks and set permissions

```bash
ssh PI_IP '
File.chmod!("/root/pianobar/pianobar", 0o755)
File.ln_s!("libavcodec.so.59.37.100", "/root/pianobar/lib/libavcodec.so.59")
File.ln_s!("libavformat.so.59.27.100", "/root/pianobar/lib/libavformat.so.59")
File.ln_s!("libavutil.so.57.28.100", "/root/pianobar/lib/libavutil.so.57")
File.ln_s!("libavfilter.so.8.44.100", "/root/pianobar/lib/libavfilter.so.8")
File.ln_s!("libswresample.so.4.7.100", "/root/pianobar/lib/libswresample.so.4")
File.ln_s!("libcurl.so.4.8.0", "/root/pianobar/lib/libcurl.so.4")
File.ln_s!("libgcrypt.so.20.4.3", "/root/pianobar/lib/libgcrypt.so.20")
File.ln_s!("libgpg-error.so.0.34.0", "/root/pianobar/lib/libgpg-error.so.0")
File.ln_s!("libjson-c.so.5.3.0", "/root/pianobar/lib/libjson-c.so.5")
'
```

## Configuration

### Create config directory and FIFO

```bash
ssh PI_IP '
File.mkdir_p!("/root/.config/pianobar")
'
ssh PI_IP 'System.cmd("mknod", ["/root/.config/pianobar/ctl", "p"])'
```

Note: `mkfifo` is not available on Nerves, but `mknod` works.

### Write config file

```bash
ssh PI_IP 'File.write!("/root/.config/pianobar/config", """
user = YOUR_PANDORA_EMAIL
password = YOUR_PANDORA_PASSWORD
fifo = /root/.config/pianobar/ctl
""")'
```

See `contrib/config-example` for all available options (volume, audio quality, keybindings, etc.).

## Running

### Start pianobar

```bash
ssh PI_IP ':os.cmd(~c"LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar > /root/pianobar/log.txt 2>&1 &")'
```

### Select a station

On first run (or if no `autostart_station` is set), pianobar waits for station selection:

```bash
ssh PI_IP 'File.write!("/root/.config/pianobar/ctl", "70\n")'
```

To auto-start a station, add its ID to the config:

```
autostart_station = 158178143675749107
```

You can find station IDs in the log output after the station name.

### Control playback

Send single-character commands to the FIFO:

```bash
# Pause / resume
ssh PI_IP 'File.write!("/root/.config/pianobar/ctl", "p")'

# Next song
ssh PI_IP 'File.write!("/root/.config/pianobar/ctl", "n")'

# Love song
ssh PI_IP 'File.write!("/root/.config/pianobar/ctl", "+")'

# Ban song (skip and don't play again)
ssh PI_IP 'File.write!("/root/.config/pianobar/ctl", "-")'

# Quit
ssh PI_IP 'File.write!("/root/.config/pianobar/ctl", "q")'
```

Full command list (press `?` in interactive mode or see `src/ui_dispatch.c`):

| Key | Action |
|-----|--------|
| `p` | Pause/resume |
| `n` | Next song |
| `+` | Love song |
| `-` | Ban song |
| `s` | Change station |
| `q` | Quit |
| `(` | Volume down |
| `)` | Volume up |
| `e` | Explain why song is playing |
| `i` | Song info |
| `t` | Tired of this song (don't play for a month) |

## Checking status

### View log

```bash
sftp PI_IP <<'EOF'
get /root/pianobar/log.txt /tmp/pianobar-log.txt
EOF
cat /tmp/pianobar-log.txt
```

Note: `IO.puts` over SSH may not display pianobar's output due to ANSI escape codes. Use sftp to download the log.

### Check if running

```bash
ssh PI_IP ':os.cmd(~c"ps w | grep pianobar") |> IO.puts()'
```

### Kill pianobar

```bash
ssh PI_IP ':os.cmd(~c"killall pianobar")'
```

## Updating

To deploy a new build:

```bash
# Kill running instance
ssh PI_IP ':os.cmd(~c"killall pianobar")'

# Remove old binary (sftp can't overwrite a running executable)
ssh PI_IP 'File.rm("/root/pianobar/pianobar")'

# Upload new binary
sftp PI_IP <<'EOF'
put pianobar /root/pianobar/pianobar
EOF

# Set permissions and restart
ssh PI_IP 'File.chmod!("/root/pianobar/pianobar", 0o755)'
ssh PI_IP ':os.cmd(~c"LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar > /root/pianobar/log.txt 2>&1 &")'
```

## Troubleshooting

### "Illegal instruction" on Pi Zero W

The bundled libraries contain ARMv7/v8 instructions. Rebuild using `./cross-build-armv6.sh` which compiles all dependencies from source with `-march=armv6`.

### No audio output

Check that a sound card is present:

```bash
ssh PI_IP ':os.cmd(~c"cat /proc/asound/cards") |> IO.puts()'
```

If empty, you need a USB DAC or I2S HAT. The Pi Zero W has no onboard audio; the Pi 3B+ has a 3.5mm jack (`bcm2835 Headphones`).

### "Autostart station not found"

The `autostart_station` config value must be the station ID (the long number shown after the station name in the log), not the list index.

### Empty log file

Older builds buffer stdout. The current build includes `setvbuf(stdout, NULL, _IOLBF, 0)` for line-buffered output. If you see an empty log, rebuild and redeploy.

### sftp "dest open: Failure"

The binary is currently running. Kill it first, then remove and re-upload:

```bash
ssh PI_IP ':os.cmd(~c"killall pianobar")'
ssh PI_IP 'File.rm("/root/pianobar/pianobar")'
```
