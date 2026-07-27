# RACETEST - SEND-race defer stress test (developer tool)

`RACETEST.EXE` + `tools/race_server.py` verify, on real Sprinter-WiFi hardware,
that the UNETESP receive-defer buffer captures peer data that arrives in the
`CIPSEND` `>` / `SEND OK` window instead of dropping it (see the "Data arriving
during a SEND" section of [UNETAPI.md](UNETAPI.md) and `ESP_TCP_RX_DEFER` in
`src/lib/esp_tcp.asm`).

This pair is **not part of the distribution**. It is absent from
`tools/artifacts.sh`, so `make build`, `make package`, and `make image` never
touch it. The deterministic Z80-level unit test of the same logic is
`tools/test-send-defer.sh` (run by `make test`); RACETEST is the end-to-end
hardware check on top of it.

## How it works

The server streams a single continuous, incrementing byte sequence
(`0,1,2,...,255,0,...`) at a paced rate. Whenever the Sprinter client is
mid-`CIPSEND`, peer bytes are queued in the ESP - the exact window the defer
buffer must capture. The client loop is **drain-dominant**: it reads (and
continuity-checks) several RECV blocks, then injects one SEND (the race window),
and repeats. Draining must dominate so the inbound stream never backs up in the
ESP; otherwise each SEND's prompt/`SEND OK` wait has to wade through a growing
backlog byte-by-byte and the run wedges. The client checks that **every** byte
it receives continues the sequence (`byte == previous+1 mod 256`); a dropped or
reordered byte breaks continuity and fails the test, pinpointing the offset.

This is why the server must be paced **below the UART line rate** (default
4 KB/s): the client drains a backlog at line rate (~10 KB/s) but only consumes
new data at the arrival rate, so a stream at or above line rate plus the
per-SEND overhead grows an unrecoverable backlog. At 4 KB/s the client stays
comfortably ahead.

With the fix, the stream stays continuous (`PASS`). Against a build without
`ESP_TCP_RX_DEFER` (old discard behaviour), bytes captured during each SEND are
lost, so continuity breaks within the first few SENDs (`FAIL`).

TCP is the strict oracle (reliable ordered stream => any gap is a real defer bug
or a flagged overflow). UDP flood mode exists for stress but the network may
drop/reorder datagrams on its own, so it is not a continuity oracle.

## Build

```sh
make racetest          # -> build/RACETEST.EXE (dev tool, not packaged)
```

## Run

1. On a host reachable from the Sprinter, start the server:

   ```sh
   tools/race_server.py --port 9099            # TCP, paced 4 KB/s (default)
   tools/race_server.py --port 9099 --rate 6000    # a bit faster (still < line rate)
   tools/race_server.py --port 9099 --full     # unpaced stress (see caveat)
   tools/race_server.py --udp --port 9100      # UDP flood (stress only)
   ```

   The default is **paced** (4 KB/s) on purpose: it stays below the UART line
   rate so the drain-dominant client keeps up, and keeps less than the 2 KB
   defer buffer arriving per SEND window so the buffer captures one frame per
   race without overflowing. The run then finishes in ~8 seconds.
   `--full` streams at line speed - it overwhelms the ESP: the `CIPSEND`
   handshake stalls and the run wedges (and the defer buffer overflows every
   send). Use `--full` only to exercise the overflow path, never for a clean
   continuity PASS. If you raise `--rate`, keep it well under ~10 KB/s.

2. On the Sprinter (after `NETUP` has brought the link up):

   ```
   RACETEST 192.168.1.50 9099
   RACETEST -d C:\WIFI\UNETESP.DLL 192.168.1.50 9099
   ```

The client prints one `.` per SEND round while running (so you can see it is
alive), then a stats line and a verdict, e.g.:

```
........
race: 32768 bytes in 8 sends, lost=0
PASS: stream continuous (defer preserved order)
```

Dots appear steadily (one per SEND, i.e. per `SEND_EVERY` drained blocks). If it
prints `connect ...`, a few dots, then hangs, the stream is outpacing the client
(a `--full` server, or `--rate` too high): the backlog grew until a `CIPSEND`
handshake stalled. Restart with the default paced server (4 KB/s). Note the
abort keys (Esc/Ctrl+Z) do not interrupt a stalled `CIPSEND` prompt wait, so a
wedged run may need a reset - correct pacing avoids the situation entirely.

`lost=N` counts RECV calls that reported the "data lost" flag (`IX` bit2) - a
frame too large for the defer buffer. It should be 0 with one MTU-sized frame
per window; a non-zero value explains a continuity gap as an overflow rather than
an ordering bug.

## Exit codes

- `0` PASS (stream continuous).
- `1` usage error.
- `2` hardware not found / DLL load failure.
- `3` communication/protocol error, connect failure, or continuity FAIL.
- `4` network not configured (run `NETUP` first).

## Emulator note

Under MAME/`jesperl` the timing is not realistic (see the pacing knobs
`JESPERL_IPD_CHUNK` / `JESPERL_Z_PACE_US` in the CLAUDE.md debugging notes), so a
green RACETEST there only confirms no regression on the normal path. Positive
proof of the race requires real ESP-AT hardware with sustained `+IPD` traffic.
