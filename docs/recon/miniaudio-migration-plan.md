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

> **Surprise:** `ma_device_write` does not exist as a public API in miniaudio v0.11.
> The internal per-backend functions (e.g. `ma_device_write__alsa`) exist but are
> not exposed. Setting `dataCallback = NULL` is also not a supported "push mode" —
> miniaudio v0.11 requires a data callback. The plan below reflects what was actually
> implemented: a `ma_pcm_rb` ring buffer bridging `BarAoPlayThread` and the callback.

**Live audio path** — `player_t` gets an additional field `ma_pcm_rb maRingBuf`. A static callback `maDataCallback` is added above `openDevice`; it reads from the ring buffer and writes to the hardware output, zeroing any frames it cannot fill (underrun silence). `openDevice` initialises both the ring buffer and the device:

```c
/* ring buffer: 8192 frames (~185ms at 44100Hz) */
ma_pcm_rb_init(ma_format_s16, channels, 8192, NULL, NULL, &player->maRingBuf);

ma_device_config config  = ma_device_config_init(ma_device_type_playback);
config.playback.format   = ma_format_s16;
config.playback.channels = channels;
config.sampleRate        = sampleRate;
config.dataCallback      = maDataCallback;
config.pUserData         = player;

ma_device_init(NULL, &config, &player->maDevice);
ma_device_start(&player->maDevice);
player->maDeviceOpen = true;
```

**Audio pipe path** — unchanged from the original plan: FIFO validation then `open(O_WRONLY)`.

### 4e. `finish`

```c
if (player->maDeviceOpen) {
    ma_device_uninit(&player->maDevice);
    ma_pcm_rb_uninit(&player->maRingBuf);  /* added vs. original plan */
    player->maDeviceOpen = false;
}
if (player->pipeFd >= 0) {
    close(player->pipeFd);
    player->pipeFd = -1;
}
```

### 4f. `BarAoPlayThread` hot path (lines 596–597)

The pipe path is unchanged from the original plan. The live audio path writes into the ring buffer instead of calling `ma_device_write`:

```c
const char *buf = (const char *)filteredFrame->data[0];
ma_uint32 remaining = (ma_uint32)filteredFrame->nb_samples;
while (remaining > 0 && !shouldQuit(player)) {
    ma_uint32 n = remaining;
    void *ptr;
    if (ma_pcm_rb_acquire_write(&player->maRingBuf, &n, &ptr) != MA_SUCCESS) break;
    if (n == 0) {
        sched_yield();  /* ring buffer full; yield to audio callback thread */
        continue;
    }
    memcpy(ptr, buf, (size_t)n * numChannels * bps);
    ma_pcm_rb_commit_write(&player->maRingBuf, n);
    buf += (size_t)n * numChannels * bps;
    remaining -= n;
}
```

`ma_pcm_rb` is lock-free and safe for single-producer / single-consumer use across threads. `BarAoPlayThread` is the sole writer; `maDataCallback` (on miniaudio's audio thread) is the sole reader.

---

## Step 5 — Threading model

The existing two-thread design is preserved, but a **third thread** is now involved: miniaudio's internal audio callback thread.

| Thread | Role |
|---|---|
| `BarPlayerThread` | Decodes packets, feeds ffmpeg filter graph |
| `BarAoPlayThread` | Pulls filtered frames, writes to `ma_pcm_rb` (or pipe fd) |
| miniaudio audio thread | `maDataCallback` drains `ma_pcm_rb` to hardware |

The `aoplayLock` / `aoplayCond` handshake between the decoder and `BarAoPlayThread` is unchanged. The ring buffer is the only shared state between `BarAoPlayThread` and the miniaudio thread; `ma_pcm_rb` is lock-free so no additional synchronization is needed.

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

## Surprises encountered during implementation

**`ma_device_write` is not a public API.** The plan assumed a push mode accessible via `ma_device_write()` with `dataCallback = NULL`. In miniaudio v0.11 neither exists publicly — internal per-backend write functions (`ma_device_write__alsa` etc.) are not exposed, and omitting `dataCallback` is not a supported configuration. The fix was to use `ma_pcm_rb` as an explicit intermediary and drive output from a real `dataCallback`. This added one struct field (`maRingBuf`) and one static function (`maDataCallback`) but kept all other changes as planned.

**`ma_yield` is `static inline` in the impl unit only.** The plan called `ma_yield()` for the ring-buffer-full spin case, but this symbol is not visible to translation units that include `miniaudio.h` without `MINIAUDIO_IMPLEMENTATION`. Replaced with POSIX `sched_yield()` (added `#include <sched.h>`).

## Remaining potential issues

**Sample rate rejection:** If `getSampleRate()` returns a rate unsupported by the hardware, `ma_device_init` returns `MA_FORMAT_NOT_SUPPORTED`. The existing fallback (rate 0 → stream native rate) already avoids most cases; the error message covers the rest.

**Ring buffer underruns:** If `BarAoPlayThread` stalls (e.g. during a network fetch), `maDataCallback` will exhaust the ring buffer and output silence. This is audible as a brief dropout but is not a crash. The existing ffmpeg buffer health logic in the decoder thread mitigates this.

**Audio pipe output format:** The pipe output is raw interleaved S16 in native byte order — identical to what libao's raw driver produced with `AO_FMT_NATIVE`. No change in behavior for pipe consumers.
