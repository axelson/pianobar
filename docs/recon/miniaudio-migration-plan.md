# Plan: Replace libao with miniaudio

## Current libao surface area

All libao usage is confined to three files:

| Location | What it does |
|---|---|
| `player.h:34` | `#include <ao/ao.h>` |
| `player.h:78` | `ao_device *aoDev` field in `player_t` |
| `player.c:79` | `ao_initialize()` in `BarPlayerInit` |
| `player.c:108` | `ao_shutdown()` in `BarPlayerDestroy` |
| `player.c:127` | `p->aoDev = NULL` in `BarPlayerReset` |
| `player.c:338–376` | `openDevice()` — builds `ao_sample_format`, opens device or pipe |
| `player.c:510–511` | `ao_close()` in `finish()` |
| `player.c:596–597` | `ao_play()` in `BarAoPlayThread` — the only hot-path call |
| `Makefile:61–62,67–72` | `LIBAO_CFLAGS` / `LIBAO_LDFLAGS` via pkg-config |

---

## Step 1 — Vendor miniaudio

1. Download `miniaudio.h` from the miniaudio GitHub releases (v0.11.x or later).
2. Place it at `src/miniaudio.h`.
3. Create `src/miniaudio_impl.c` containing only:

```c
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
```

This compiles the implementation exactly once. `player.c` includes `miniaudio.h` without the define.

---

## Step 2 — Makefile changes

Remove the libao pkg-config variables and their uses:
```make
# DELETE these two lines:
LIBAO_CFLAGS:=$(shell $(PKG_CONFIG) --cflags ao)
LIBAO_LDFLAGS:=$(shell $(PKG_CONFIG) --libs ao)
```

Remove `${LIBAO_CFLAGS}` from `ALL_CFLAGS` and `${LIBAO_LDFLAGS}` from `ALL_LDFLAGS`.

Add `miniaudio_impl.c` to the `PIANOBAR_SRC` list.

Add `-ldl` on Linux (miniaudio needs it for dynamic backend loading; macOS needs nothing extra):
```make
OS := $(shell uname)
ifeq (${OS},Linux)
    MINIAUDIO_LDFLAGS := -ldl
else
    MINIAUDIO_LDFLAGS :=
endif
```
Add `${MINIAUDIO_LDFLAGS}` to `ALL_LDFLAGS`.

---

## Step 3 — `src/player.h` changes

Replace the include:
```c
// remove:
#include <ao/ao.h>
// add:
#include "miniaudio.h"
```

Replace the `aoDev` field (line 78):
```c
// remove:
ao_device *aoDev;
// add:
ma_device  maDevice;     /* value type; valid only when maDeviceOpen */
bool       maDeviceOpen;
int        pipeFd;       /* fd for audio_pipe mode; -1 if unused */
```

`ma_device` is a value type (struct, not pointer). No heap allocation needed.

---

## Step 4 — `src/player.c` changes

### 4a. `BarPlayerInit` (line 79)

Remove `ao_initialize()`. miniaudio has no global init.

### 4b. `BarPlayerDestroy` (line 108)

Remove `ao_shutdown()`. miniaudio has no global shutdown.

### 4c. `BarPlayerReset` (line 127)

```c
// remove:
p->aoDev = NULL;
// add:
p->maDeviceOpen = false;
p->pipeFd = -1;
```

### 4d. `openDevice` (lines 338–376) — largest change

**Live audio path** — replace `ao_default_driver_id()` + `ao_open_live()` with miniaudio push mode (callback-less mode, enabled by setting `dataCallback = NULL`):

```c
ma_device_config config = ma_device_config_init(ma_device_type_playback);
config.playback.format   = ma_format_s16;
config.playback.channels = cp->ch_layout.nb_channels;
config.sampleRate        = getSampleRate(player);
config.dataCallback      = NULL;  /* push mode: caller calls ma_device_write() */

if (ma_device_init(NULL, &config, &player->maDevice) != MA_SUCCESS) {
    BarUiMsg(player->settings, MSG_ERR, "Cannot open audio device.\n");
    return false;
}
if (ma_device_start(&player->maDevice) != MA_SUCCESS) {
    ma_device_uninit(&player->maDevice);
    BarUiMsg(player->settings, MSG_ERR, "Cannot start audio device.\n");
    return false;
}
player->maDeviceOpen = true;
```

**Audio pipe path** — miniaudio has no raw-file driver, so replace with direct POSIX I/O. Preserve the existing FIFO validation (`stat` / `S_ISFIFO`), then:

```c
player->pipeFd = open(player->settings->audioPipe, O_WRONLY);
if (player->pipeFd < 0) {
    BarUiMsg(player->settings, MSG_ERR, "Cannot open audio pipe file.\n");
    return false;
}
```

Note: `open(O_WRONLY)` on a named pipe blocks until a reader connects — same behavior as libao's raw driver.

### 4e. `finish` (lines 510–511)

```c
// remove:
ao_close(player->aoDev);
player->aoDev = NULL;

// add:
if (player->maDeviceOpen) {
    ma_device_uninit(&player->maDevice);
    player->maDeviceOpen = false;
}
if (player->pipeFd >= 0) {
    close(player->pipeFd);
    player->pipeFd = -1;
}
```

### 4f. `BarAoPlayThread` hot path (lines 596–597)

```c
// remove:
ao_play(player->aoDev, (char *) filteredFrame->data[0],
        filteredFrame->nb_samples * numChannels * bps);

// add:
const size_t byteCount = (size_t)filteredFrame->nb_samples * numChannels * bps;
if (player->pipeFd >= 0) {
    /* audio_pipe mode: raw write to FIFO */
    const char *buf = (const char *)filteredFrame->data[0];
    size_t remaining = byteCount;
    while (remaining > 0) {
        ssize_t n = write(player->pipeFd, buf, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            /* broken pipe — reader closed; signal quit */
            pthread_mutex_lock(&player->lock);
            player->doQuit = true;
            pthread_mutex_unlock(&player->lock);
            break;
        }
        buf += n;
        remaining -= n;
    }
} else {
    /* miniaudio push mode — blocks until ring buffer accepts data */
    ma_uint32 framesWritten;
    ma_device_write(&player->maDevice,
            filteredFrame->data[0],
            (ma_uint32)filteredFrame->nb_samples,
            &framesWritten);
}
```

`ma_device_write` takes a frame count (not byte count); miniaudio derives the byte size from the device config. It blocks when the internal ring buffer is full, preserving `ao_play`'s back-pressure behavior.

---

## Step 5 — Threading model

No changes needed. The existing two-thread design is fully compatible:

- `BarPlayerThread` calls `openDevice()` then spawns `BarAoPlayThread`.
- `BarAoPlayThread` calls `ma_device_write()` (or `write()`) directly, just as it called `ao_play()`.
- The `aoplayLock` / `aoplayCond` handshake between the threads guards the ffmpeg buffer — unrelated to the audio output API.

miniaudio runs its own background thread internally to drain the ring buffer to hardware, but that is entirely hidden behind `ma_device_write`. pianobar code does not interact with it.

---

## Step 6 — Implementation order

1. Add `src/miniaudio.h` and `src/miniaudio_impl.c`
2. Edit `Makefile`
3. Edit `src/player.h`
4. Edit `src/player.c`:
   - `BarPlayerInit` — remove `ao_initialize`
   - `BarPlayerDestroy` — remove `ao_shutdown`
   - `BarPlayerReset` — replace null sentinel
   - `openDevice` — full replacement
   - `finish` — replace `ao_close`
   - `BarAoPlayThread` — replace `ao_play`
5. `make` and verify

---

## Potential issues

**Push mode version requirement:** `dataCallback = NULL` push mode requires miniaudio 0.10.x+. Document the minimum version in `src/miniaudio.h` or a comment.

**`ma_device_start` before write on macOS:** CoreAudio requires the device to be started before `ma_device_write` is called. The plan already does this inside `openDevice`.

**Sample rate rejection:** If `getSampleRate()` returns a rate unsupported by the hardware, `ma_device_init` returns `MA_FORMAT_NOT_SUPPORTED`. The existing fallback (rate 0 → stream native rate) already avoids most cases; the error message covers the rest.

**`errno.h`:** The pipe write path uses `errno`. Add `#include <errno.h>` to `player.c` if not already transitively included.

**Audio pipe output format:** The pipe output will be raw interleaved S16 in native byte order — identical to what libao's raw driver produced with `AO_FMT_NATIVE`. No change in behavior for pipe consumers.
