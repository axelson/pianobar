## Build

```bash
gmake clean && gmake       # build pianobar binary
gmake install              # install to /usr/local
./pianobar                 # run directly from source dir
```

**Dependencies** (via pkg-config): `libavcodec`, `libavformat`, `libavutil`, `libavfilter` (ffmpeg ≤ 5.1), `libcurl` ≥ 7.32.0, `libgcrypt` (with blowfish), `json-c`, `miniaudio` (header-only, vendored in `include/`), pthreads.

On macOS: use `gmake` (GNU make). The Makefile auto-selects `gcc` on Darwin.

Optional shared library build: `gmake DYNLINK=1`

## No Tests or Linting

There is no automated test suite and no linting configuration. Testing is done manually by running the binary.

## Architecture

Pianobar is a ~6000-line C99 codebase organized around four major components:

### 1. Pandora API Client (`src/libpiano/`)
Self-contained library wrapping the Pandora JSON API. Key files:
- `piano.c/h` — `PianoHandle_t` session state, `PianoStation_t`/`PianoSong_t` data structures
- `request.c` / `response.c` — builds and parses API JSON calls
- `crypt.c` — Blowfish (ECB) encryption/decryption via libgcrypt for API auth

All API calls go through `BarUiPianoCall()` in `src/ui.c`, which wraps `PianoRequest()`/`PianoResponse()` and dispatches errors to UI.

### 2. Audio Playback (`src/player.c`, `src/miniaudio_impl.c`)

Three-thread pipeline:
```
BarPlayerThread (decoder)
  → ffmpeg: demux → AAC/MP3 decode → filter graph (volume, aformat, resample → S16)
  → BarAoPlayThread (playback)
      → ma_pcm_rb (lock-free ring buffer)
      → maDataCallback (miniaudio audio thread)
          → hardware (CoreAudio/ALSA/etc.)
```

Player state machine: `PLAYER_DEAD → PLAYER_WAITING → PLAYER_PLAYING → PLAYER_FINISHED`

The `audio_pipe` config setting bypasses miniaudio and writes raw PCM to a named pipe instead.

### 3. Main Loop (`src/main.c`)

`BarMainLoop()` is the central event loop:
1. Checks player state; on `PLAYER_FINISHED`, cleans up and fires `songfinish` event
2. Fetches playlist (`PIANO_REQUEST_GET_PLAYLIST`) when player is dead and a station is queued
3. Starts `BarPlayerThread` for the next song, fires `songstart` event
4. Reads non-blocking keyboard input → `BarUiDispatch()` → 30 action handlers in `src/ui_act.c`
5. Prints playback progress

Central state is `BarApp_t` (defined in `src/main.h`), which owns the `PianoHandle_t`, `player_t`, `BarSettings_t`, and song/station linked lists.

### 4. Terminal UI (`src/ui*.c`)

- `ui_readline.c` — non-blocking readline with configurable keybindings; uses `select()` so input and playback run concurrently
- `ui_dispatch.c` / `ui_act.c` — maps key presses to 30 action handlers (`BarUiActLoveSong`, `BarUiActSkipSong`, etc.)
- `ui.c` — `BarUiSelectStation()`, `BarUiPianoCall()`, format-string rendering for song display
- `terminal.c` — saves/restores terminal raw mode; handles `SIGINT`

### Event Command Interface

When `eventCmd` is set in config, pianobar forks a script on events (`songstart`, `songfinish`, `userlogin`, `stationfetchplaylist`, `songshortcut`, etc.), passing song/station metadata via environment variables. This is the integration point for Last.fm scrobbling, desktop notifications, remote control, etc. See `contrib/headless_pianobar` for an example.

### Configuration

Loaded from `~/.config/pianobar/config` by `BarSettingsLoad()` in `src/settings.c`. The `contrib/config-example` file documents all options. Notable settings: `audio_pipe` (raw PCM output path), `sample_rate`, `volume`, `gainMul`, `audioQuality`, `controlProxy` (for non-US listeners), `eventCmd`, all 30 keybindings.
