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

RACETEST uses channel 0 only, but since UNETESP 0.3 that channel runs over the
ESP multi-connection dialect (`AT+CIPMUX=1`, `+IPD,<link>,<len>:`), so this test
is also the regression check that the dialect change did not disturb the proven
single-channel receive path. `tools/race_server.py --dual` plus `UNETTEST -2`
covers the two-channel case; see [UNETTEST.TXT](UNETTEST.TXT).

## How it works

The server streams a single continuous, incrementing byte sequence
(`0,1,2,...,255,0,...`) at a paced rate. Whenever the Sprinter client is
mid-`CIPSEND`, peer bytes are queued in the ESP - the exact window the defer
buffer must capture. The client loop is **drain-dominant**: it reads (and
continuity-checks) several RECV blocks, then injects one SEND (the race window),
and repeats. Draining must dominate so the inbound stream never backs up in the
ESP; otherwise each SEND's prompt/`SEND OK` wait has to wade through a growing
backlog byte-by-byte and the run wedges. The client requires the first byte to
be `0` and checks that **every** following byte continues the sequence
(`byte == previous+1 mod 256`); a dropped or reordered byte, including a prefix
lost during `CIPSTART`, breaks continuity and fails the test at that offset.

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
   RACETEST -a 192.168.1.50 9099
   ```

   `-a` runs the same continuity test through the suspendable-send mode
   (`UNET_OPT_SENDSLICE` 200 ms, `NERR_AGAIN` loops): every suspension prints
   a `~`, buffered data is drained between repeats, and the byte counter is
   still checked across the whole stream. On a DLL without `CAP_ASYNCSEND`
   the flag prints a note and the run stays blocking.

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

`lost=N` counts RECV calls that reported the "data lost" flag (`IX` bit2):
either the UART LSR overrun bit was observed, or a frame did not fit in the
defer buffer. It should be 0 with one MTU-sized frame per window. A non-zero
value confirms a real byte loss rather than only an ordering-check defect; the
position and first surviving byte help distinguish UART overrun from defer
overflow.

The specific startup failure `lost=1`, `expected 0x00 got 0x20 at byte 0`
means that the 16550 reported an overrun before the first RECV and the first
32 stream bytes were lost. It is not evidence that the ESP stopped responding.
UNETESP keeps the ISA/UART window open while it reads the `CIPSTART` response,
drops RTS directly when the requested link's `CONNECT` notification arrives,
then raises RTS only after the first RECV has opened the window and can drain
the FIFO immediately. This protects an eager server that sends its first
`+IPD` frame immediately after accepting the connection; no passive-receive
ESP-AT mode is involved.

A run that stops on a SEND or RECV error prints the numeric status, the DLL's
`LASTERR` text, and the verdict `ABORT: stopped early - continuity not proven`
(exit 3). It is deliberately not a PASS: the bytes read before the abort say
nothing about the bytes that never arrived. For a send failure `LASTERR` names
the compact transport reason and last complete ESP/probe line - see
"Function 16 - LASTERR" in [UNETAPI.md](UNETAPI.md).
After the complete payload has left the host, the probe can accept a late
`SEND OK` or detect a module reboot without duplicating bytes. Before the `>`
prompt the DLL deliberately does not probe or reissue: a late prompt could make
the probe/repeated command become CIPSEND payload and corrupt the stream.

To tell a regression from a long-standing limit, run the same test against an
older DLL with `-d`: `RACETEST -d C:\WIFI\UNETOLD.DLL <host> 9099`. Build the
comparison DLL from the earlier commit into a separate file name rather than
overwriting `UNETESP.DLL`.

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
