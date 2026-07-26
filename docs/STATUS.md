# Project Status

## Pianobar on Nerves RPi — WORKING

Pianobar runs on a Raspberry Pi 3B+ with Nerves. Pandora login, audio playback, and FIFO control all work.

| Component | Status |
|-----------|--------|
| Cross-compiled ARMv7 binary | Done |
| Minimal lib bundle (9 .so files, 4.1MB) | Done |
| Deploy to Pi via sftp | Done |
| Pandora login | Working |
| Audio playback (3.5mm jack) | Working |
| FIFO control (`ctl`) | Working |
| `--version` flag, line-buffered stdout | Done |

**Device:** RPi 3B+ at `192.168.1.6`, Nerves (Elixir 1.16.3, OTP 26)
**Binary:** `/root/pianobar/pianobar` with libs in `/root/pianobar/lib/`
**Run:** `LD_LIBRARY_PATH=/root/pianobar/lib /root/pianobar/pianobar`

## piano_ctl Integration — DONE

Piano_ctl Elixir app controls pianobar on the Pi via local FIFOs, with distributed Erlang for remote UIs.

```
[Remote UI] <--distributed Erlang--> [piano_ctl on Pi] <--FIFOs--> [pianobar on Pi]
```

## Cross-Compilation History

Detailed logs of the armv6/armv7 cross-compilation journey are in the git history of this file and in:
- `docs/plans/option-a-dockcross.md`
- `docs/reports/nerves-cross-compilation.md`
