# pianobar libao Integration

## Overview

pianobar uses libao as its sole audio output backend. libao is an abstraction layer that provides a unified API across multiple platform audio systems (ALSA, PulseAudio, CoreAudio, OSS, etc.). There are no alternative backends and no conditional compilation paths — libao is the only output mechanism.

## Build System

**File: `Makefile`, lines 61–62**

```makefile
LIBAO_CFLAGS:=$(shell $(PKG_CONFIG) --cflags ao)
LIBAO_LDFLAGS:=$(shell $(PKG_CONFIG) --libs ao)
```

Detection and linking are handled entirely via `pkg-config`. The resulting flags are folded into the single-binary compilation at link time.

## Lifecycle

| Phase | Call | Location |
|---|---|---|
| Startup | `ao_initialize()` | `BarPlayerInit()` → called from `main()` |
| Per-song device open | `ao_open_live()` or `ao_open_file()` | `openDevice()` in `player.c` |
| Per-song device close | `ao_close()` | `finish()` in `player.c` |
| Shutdown | `ao_shutdown()` | `BarPlayerDestroy()` → called from `main()` |

`ao_initialize` / `ao_shutdown` are global, called once. Device open/close happens per song.

## Device Configuration

**Function: `openDevice()` in `src/player.c`**

An `ao_sample_format` is constructed from codec parameters before opening:

```c
ao_sample_format aoFmt;
aoFmt.bits        = 16;                         // always AV_SAMPLE_FMT_S16 after resampling
aoFmt.channels    = cp->ch_layout.nb_channels;
aoFmt.rate        = getSampleRate(...);         // stream rate, or user override via `sample_rate` setting
aoFmt.byte_format = AO_FMT_NATIVE;
```

### Two output modes

**1. Live audio (default)**

```c
int driver = ao_default_driver_id();
player->aoDev = ao_open_live(driver, &aoFmt, NULL);
```

Selects the system default driver via libao's own configuration (`~/.libao`, environment). No driver options are passed from pianobar directly.

**2. Audio pipe mode**

Activated when `audio_pipe` is set in `~/.config/pianobar/config`.

```c
int driver = ao_driver_id("raw");
player->aoDev = ao_open_file(driver, audioPipePath, 1, &aoFmt, NULL);
```

Validates that the path exists and is a FIFO before opening. Writes raw interleaved 16-bit PCM into the pipe. Example config:

```
audio_pipe = /tmp/mypipe
```

## Audio Data Flow

Pianobar uses a two-thread pipeline with an ffmpeg filter graph sitting between the decoder and libao:

```
[Decoder thread]                        [Playback thread]
av_read_frame()
  → avcodec_send_packet()
  → avcodec_receive_frame()
  → av_buffersrc_write_frame()  ──────→ av_buffersink_get_frame()
                                              ↓
                                        ao_play(aoDev, data, size)
```

### Filter chain

```
abuffer → volume → aformat → abuffersink
```

- **abuffer**: receives raw decoded frames
- **volume**: applies dB volume adjustment; can be updated live via `BarPlayerSetVolume()`
- **aformat**: resamples to `AV_SAMPLE_FMT_S16` at the configured output sample rate
- **abuffersink**: provides output frames to the playback thread

The `aformat` filter is what ensures libao always receives 16-bit signed integer PCM regardless of the source encoding.

### The `ao_play` call

In the playback thread (`BarAoPlayThread`):

```c
int numChannels = filteredFrame->ch_layout.nb_channels;
int bps = av_get_bytes_per_sample(filteredFrame->format);  // always 2 for S16
ao_play(player->aoDev,
        (char *)filteredFrame->data[0],
        filteredFrame->nb_samples * numChannels * bps);
```

Data is the raw interleaved PCM buffer from the filter graph output frame.

## Thread Synchronization

The decoder and playback threads share access to the filter graph buffer. Coordination uses:

- `player->aoplayLock` — mutex protecting filter buffer and device state
- `player->aoplayCond` — condition variable for signaling between threads

The decoder monitors buffer health and pauses if the buffer is too full, preventing overflow.

## Error Handling

| Error | Message | Return code |
|---|---|---|
| Audio pipe path invalid or not a FIFO | "Cannot open audio pipe file" | `PLAYER_RET_HARDFAIL` |
| `ao_open_live()` returns NULL | "Cannot open audio device" | `PLAYER_RET_HARDFAIL` |

Both failures abort the current song. There is no retry logic or fallback driver.

## User-Configurable Settings

| Setting | Default | Effect |
|---|---|---|
| `sample_rate` | 0 (stream native) | Forces output resampling to this rate before libao |
| `audio_pipe` | (unset) | Routes output to a FIFO using `ao_driver_id("raw")` |

## Key Files

| File | Relevance |
|---|---|
| `src/player.h` | Declares `ao_device *aoDev` in the player struct; includes `<ao/ao.h>` |
| `src/player.c` | All libao API calls: `openDevice`, `BarAoPlayThread`, `finish`, `BarPlayerInit`, `BarPlayerDestroy` |
| `src/main.c` | Calls `BarPlayerInit` / `BarPlayerDestroy` |
| `src/settings.h` | Declares `audioPipe` and `sampleRate` fields |
| `Makefile` | pkg-config detection and linking |
| `contrib/config-example` | Documents `audio_pipe` usage |
