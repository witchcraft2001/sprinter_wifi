# UNET - universal network DLL API

UNET is a backend-agnostic network interface delivered as a libman 1.3 / L1
DLL. One contract, two interchangeable backends:

- **UNETESP.DLL** - Sprinter-WiFi (ESP8266 running ESP-AT firmware). Shipped
  and implemented in this package. **Firmware: ESP-AT 2.2.2 only.** The DLL is
  built for the 2.2.2 command set with its complete trigger-4 receive path;
  it does not contain a 2.2.1 fallback. `NETINIT` returns `NERR_NONET` if the
  active NETUP session is not `NET_ESP_FW=2.2.2`, and its L1 header name reads
  `UNET ESP 2.2.2` (shown by UNETTEST). Run NETUP with 2.2.2 firmware first.
- **UNETRTL.DLL** - RTL8019A Ethernet card. Same function numbers and error
  codes; implemented separately in the sprinter-rtl8019a project (see the RTL
  appendix below).

Backends differ only in what they advertise through `GETCAPS`, never in the
function numbering. The most consequential difference today is `CAP_MULTICHAN`
(two simultaneous connections): UNETESP 0.3 and later has it, UNETRTL does not.

A consumer written in asm, C or Pascal loads a backend with libman
(`l_load` / `l_call` / `l_free`) and drives TCP, UDP, resolve and ping through
the numbered functions. Because the ABI is identical across backends, one
consumer binary can talk to either card - pick the DLL by name at run time
(for example from the `NET` environment variable: `UNET` + backend tag).

The authoritative machine-readable contract is
[src/include/unet.inc](../src/include/unet.inc). This document is the prose
reference and covers usage patterns the header cannot.

---

## Loading and the calling convention

libman is a consumer-side module (`l_load` / `l_call` / `l_free`), not a
resident service. The consumer embeds it (asm: `libman13.asm`; Pascal:
`LIBMAN.INC`) and calls:

```
    ld   hl,filename      ; "UNETESP.DLL",0
    ld   a,window         ; 1 (0x4000) or 2 (0x8000) - NEVER 3
    call l_load           ; -> HL = handle, CF=1 on error
    ...
    ld   hl,(handle)
    ld   b,function       ; UNET_FN_*
    call l_call
    ...
    ld   hl,(handle)
    call l_free
```

**DLL name resolution.** `l_load` opens the file through the DSS file API,
which resolves the name against the **current directory** only - it does not
search `PATH` or the consumer's own program directory. A consumer launched
through `PATH` from an unrelated directory will therefore fail to find a DLL
that sits next to its EXE. Two ways to be robust:

- Resolve the DLL beside your EXE first: call DSS `APPINFO`
  (`B = APPINFO_EXE_HOMEDIR`, `C = DSS_APPINFO`) to get your EXE's directory,
  append the DLL name, and pass that full path to `l_load`; fall back to the
  bare name if `APPINFO` is unavailable. `UNETTEST` does exactly this
  (`RESOLVE_DLL_PATH` in `src/apps/unettest.asm`, mirroring `NETUP`'s NET.CFG
  lookup).
- Or simply run the consumer from the directory that holds the DLL, or pass a
  full path.

**Failure diagnostics (vendored libman extension).** After `l_load` returns
`CF=1`, the Sprinter-ESP-Kit copy of libman publishes two bytes so a consumer
can report *why* the load failed (these are not in stock libman 1.3, and are
valid only when `l_load` returned an error):

- `LIBMAN.l_reason` - the failing stage: `LR_MEMORY`, `LR_OPEN`, `LR_IO`,
  `LR_FORMAT`, `LR_INIT`, `LR_LIMIT`, `LR_CALL`.
- `LIBMAN.l_dsserr` - the raw DSS error code at that stage (e.g. 3 = file not
  found, 4 = path not found, 30 = no free memory), or the DLL's INIT refusal
  code for `LR_INIT`. `LR_CALL` distinguishes a malformed internal table/window
  from a DSS `SETWIN` failure instead of misreporting either as an INIT refusal.

The vendored dispatcher intentionally maps calls through the explicit DSS
`SETWIN1`/`SETWIN2`/`SETWIN3` functions, not generic `SETWIN` (`0x38`).
Current Estex-DSS computes the generic function's slot port with `0x42` where
`0x82` is required, so it can report success without mapping the DLL into the
requested window. The explicit functions use the proper `SLOT1`/`SLOT2`/
`SLOT3` constants and work on both old and current DSS implementations.

Register discipline for every UNET function:

- Arguments are passed **only in A, DE, IX, IY**. HL and BC are consumed by the
  libman dispatcher. The vendored dispatcher saves IX/IY around its internal
  DSS `SETWINn` call; stock libman 1.3 does not, although DSS/BIOS is allowed
  to clobber index registers.
- Results come back in **A, DE, IX, IY**.
- **Every function returns its status in A** (0 = `NERR_OK`, else a `NERR_*`
  code). The dispatcher does **not** propagate a user function's carry flag, so
  test A, never CF.
- The library is not reentrant; make one call at a time.

### Window and buffer rules (important)

- Load the DLL into **window 1 (0x4000) or window 2 (0x8000) only.** Never
  window 3 (0xC000): the ESP backend maps its ISA UART there during every call
  and would swap its own code out. The DLL's load hook detects window 3 and
  refuses to load (`l_load` fails). (The old Solid-C `loaddll` hard-codes
  window 3 and is therefore incompatible.)
- All caller buffers (host/port strings, send/recv payload, GETINFO/LASTERR
  destinations) must live **below 0xC000 and outside the 16 KB window the DLL
  was loaded into** - the whole buffer, not just its first byte: both ends of
  the range (`buf .. buf+len-1`, or the string terminator) are validated.
  Violations return `NERR_PARAM`.
- Pointers in **window 0 (`0x0000..0x3FFF`) are accepted**. The DLL does not
  verify which page is mapped there. If a program replaces the DSS/system page
  with its own page, preserving and restoring that mapping safely is entirely
  the caller's responsibility.
- Host strings are limited to **128 bytes** and port strings to **15 bytes**
  (longer arguments return `NERR_PARAM`); this protects the DLL's fixed-size
  AT command build buffers.
- Keep at least ~256 bytes of free stack across a call. libman's loader and the
  ESP receive path both use the caller's stack.
- Which window to use:
  - A consumer whose own code sits at 0x8100 (window 2 - most SDCC C programs,
    and the light DSS utilities) loads the DLL into **window 1**.
  - A consumer whose code sits at 0x4100 (window 1 - Turbo Pascal built with
    `/D:8000`) loads the DLL into **window 2**.

---

## Function reference

| # | Name | In | Out |
|---|------|----|-----|
| 0 | INIT | - | (libman load hook; checks window) |
| 1 | FINI | - | (libman free hook; closes link) |
| 2 | GETCAPS | - | A=0, DE=caps, IX=ABI version |
| 3 | NETINIT | - | A |
| 4 | NETDONE | - | A=0 |
| 5 | CONNECT | A=chan, DE=host, IX=port | A |
| 6 | SEND | A=chan, DE=buf, IX=len | A, DE=sent |
| 7 | RECV | A=chan, DE=buf, IX=max, IY=timeout_ms | A, DE=got, IX=flags |
| 8 | CLOSE | A=chan | A |
| 9 | STATUS | A=chan (or 0xFF) | A, DE=state |
| 10 | UDPOPEN | A=chan, DE=host, IX=rport, IY=lport\|0 | A |
| 11 | RESOLVE | DE=host, IX=dest(>=16) | A, dest="a.b.c.d" |
| 12 | PING | DE=host, IY=timeout_ms | A, DE=round-trip ms |
| 13 | RXPAUSE | - | A |
| 14 | RXRESUME | - | A |
| 15 | GETINFO | A=field, DE=dest, IX=max | A |
| 16 | LASTERR | DE=dest, IX=max | A=0 |
| 17 | SETOPT | A=option, DE=value | A |
| 18-23 | (reserved) | - | A=NERR_NOTSUP |

`host` and `port` are NUL-terminated ASCII strings (e.g. `"example.com",0` and
`"80",0`).

The channel byte selects one of two independent connections. A backend that
reports `CAP_MULTICHAN` accepts channel 0 and channel 1 and can hold both open
at the same time; one without it accepts only channel 0. Any other value returns
`NERR_PARAM`. Always gate on the capability bit rather than the backend name -
UNETESP 0.3 and later has it, UNETRTL does not. See
"[Two channels](#two-channels)" below.

`NETINIT` must be called (and succeed) before `CONNECT`, `UDPOPEN`, `RESOLVE`
or `PING`; otherwise those return `NERR_STATE`.

### Function 0 / 1 - INIT / FINI

libman calls these at load and free. Do not call them directly. INIT verifies
the DLL was not loaded into window 3; FINI closes any still-open link.

### Function 2 - GETCAPS

Returns the capability bitmask in DE and the ABI version (`major<<8|minor`) in
IX. Callable before `NETINIT`. Check the ABI major byte before relying on the
numbered functions. UNETESP 0.4 reports `0x031F` =
`TCP | UDP | RESOLVE | PING | RXFLOW | MULTICHAN | ASYNCSEND` (0.3 reported
`0x011F`, 0.2 `0x010F`). The ABI version stays `0x0100`: two channels and
suspendable sends are discovered through capability bits, not version bumps.

### Function 3 - NETINIT

Brings the link layer up: verifies the network was configured (see
"Network up" below), finds and initialises the UART at the configured baud,
probes the ESP (resetting it once if silent), enables RTS/CTS flow control on
both sides, clears any leftover socket and selects multi-connection mode
(`AT+CIPMUX=1`). The socket cleanup must precede the mode switch - ESP-AT
rejects `AT+CIPMUX` while a link is open - and because it really closes any
open link, NETINIT also resets both channels' state, so a repeated `NETINIT`
followed by `CONNECT` is safe.

After the mode switch NETINIT sends `AT+CIPTCPOPT=5,-1,0,4000` (best effort:
an `ERROR` is tolerated). This bounds the firmware's internal TCP send with a
4 s `SO_SNDTIMEO`. Without it - the firmware default is *no* timeout - ESP-AT
v2.2.2 holds its socket mutex across a blocking `lwip_send`, and because
`+IPD` printing needs the same mutex, one send stalled by Wi-Fi
retransmissions silences the module's entire UART output (prompts, `SEND OK`
and the inbound stream alike) until the send completes; verified in the
`v2.2.2.0_esp8266` core (`at_sending_data` / `at_process_recv_socket` /
`s_at_socket_mutex`). With the option set, a stuck send ends in the module's
own `SEND FAIL` within 4 s - before the DLL's 5 s client timeout - and the
stream resumes.
Returns `NERR_OK`, `NERR_NONET` (not configured), `NERR_HW` (no card / no
response) or `NERR_BUSY` (ESP IP stack still warming up after join).

### Function 4 / 8 - NETDONE / CLOSE

`CLOSE` closes **one** channel and is idempotent. Data still buffered for that
channel is discarded: to shut down gracefully, read until `NERR_CLOSED` first.

`NETDONE` closes every channel and hands the ESP back in single-connection mode
(`AT+CIPMUX=0`), which is what the stock utilities (WGET, FTP, TELNET, ...)
expect to find. The network itself stays up, so a later `CONNECT` still works -
it re-arms multi-connection mode by itself.

### Function 5 - CONNECT

Opens a TCP connection to `host:port` on the given channel. Retries internally
while the ESP reports `busy` (its IP stack may still be warming up right after
`NETUP`). `NERR_STATE` if that channel is already open (the other channel's
state does not matter), `NERR_DNS` if the name could not be resolved by the ESP,
`NERR_CANCEL` if the user cancelled a pending connect (with `CANCELKEYS` on),
`NERR_CONNECT` for any other failure.

Opening a channel clears whatever was buffered for it, so a new link never
replays the previous one's data. The other channel is untouched.

`CIPSTART` is parsed with the same link-aware binary reader as SEND. Its own
`<id>,CONNECT` is the definitive success event; the DLL does not wait for the
following `OK`, because an immediately streaming peer can keep continuous
`+IPD` ahead of that command tail. Any `+IPD` arriving before `CONNECT` is
stashed for the new channel; data after it remains on the UART and is delivered
by the first RECV instead of being consumed as command text. A stale bare `OK`
or a `CONNECT` notification for another link cannot complete the open. RTS is
temporarily paused after the matching `CONNECT` and resumed by the first RECV
or SEND, preserving already queued FIFO bytes across the libman/application
return without allowing an immediate peer greeting to overrun the 16550.

### Function 6 - SEND

Sends `len` bytes. On a TCP channel the payload is split internally into
2048-byte chunks (the ESP-AT `CIPSEND` maximum), so callers pass the whole
buffer in one call. On a UDP channel each SEND is **one datagram**; lengths
over 1472 (the ESP-AT UDP payload cap) return `NERR_PARAM`. DE returns the
number of bytes actually sent, even on `NERR_SEND`/`NERR_CANCEL`.

Note: data arriving from the peer **while** a SEND is in flight may be dropped
by the ESP backend (see the interactive-stream pattern below); drain RECV
before sending when the peer may talk unprompted.

### Function 7 - RECV

Reads up to `max` bytes from one channel with an `IY` millisecond timeout.
`IY=0` is a bounded non-blocking poll: the ESP backend still performs its
initial UART spin window and internally clamps the timeout to one millisecond;
it never turns zero into a 65-second wait.
Returns:

- `A=NERR_OK, DE>0` - data received.
- `A=NERR_OK, DE=0` - nothing for this channel yet. Usually the timeout expired;
  with two channels it can also mean the backend buffered a block for the
  *other* channel and handed control straight back (flag bit3, below), so a
  caller does not sit behind the busy channel's stream.
- `A=NERR_CLOSED` - the peer closed the connection. **Any bytes already
  buffered are delivered first (DE>0, A=NERR_OK); the *next* call returns
  NERR_CLOSED with DE=0**, so a "FIN with a final data segment" never loses the
  tail. A close on one channel never affects the other.

IX returns status flags, all scoped to the channel just read:

| bit | meaning |
|-----|---------|
| 0 | oversized datagram was truncated (never set by UNETESP - the tail arrives on the next call with bit1 instead) |
| 1 | more data is already buffered for this channel; call RECV again |
| 2 | data was lost since the last RECV on this channel: a UART overrun (16550 LSR) or a buffered frame dropped on overflow |
| 3 | data is pending on the **other** channel (optional; UNETESP 0.3 and later) |

### Function 9 - STATUS

With `A` = a channel number, returns that channel's state in DE:

| bit | meaning |
|-----|---------|
| 1 (`0x02`) | channel is connected (last known state) |
| 2 (`0x04`) | received data is buffered for it and not delivered yet (optional; only backends with `CAP_MULTICHAN` set it, so treat "clear" as "unknown" rather than "empty") |

STATUS reads memory only - it never touches the UART, so it is cheap enough to
poll between other work. A channel whose peer has closed reports the pending bit
without the connected bit, which is the cue to keep reading until `NERR_CLOSED`.

With `A = 0xFF`, returns network status **without touching the hardware**:
`A = NERR_OK` / `NERR_NONET`, and DE bit0 = the network is configured (env
published), bit1 = `NETINIT` has completed. Useful for a launcher that wants to
show status cheaply.

### Function 11 - RESOLVE

Resolves a host name to a dotted-quad string in the caller's `dest` buffer
(>= 16 bytes). On firmware that lacks `AT+CIPDOMAIN` (and on the current
jesperl emulator) this returns `NERR_NOTSUP`; the result is cached so later
calls fail fast. `GETCAPS` still advertises `RESOLVE` because the capability is
a static driver property - test the return value at run time. Most consumers do
not need RESOLVE at all: `CONNECT` accepts a host name directly (the ESP
resolves it in firmware).

### Function 12 - PING

ICMP-style reachability check; DE returns the round-trip time in milliseconds.

### Functions 13 / 14 - RXPAUSE / RXRESUME

See "Avoiding UART overrun" below. Both return `NERR_STATE` before `NETINIT`:
until the UART has been located, a register write could poke a different ISA
card.

### Function 15 - GETINFO

Copies a network property string into `dest` (NUL-terminated, truncated to
`max`; `max=0` returns `NERR_PARAM`). Fields: 0 backend tag ("ESP"), 1 IP, 2 mask, 3 gateway, 4 MAC, 5 DNS1,
6 DNS2, 7 IP source ("STATIC"/"DHCP"), 8 SSID, 9 baud, 10 NTP, 11 timezone,
12 hardware descriptor. Unset fields return an empty string. On UNETESP the
values come from the `NET_*` environment variables published by NETUP.

### Function 16 - LASTERR

Copies the **tail** of the last raw AT/driver response into `dest`: when the
response is longer than the buffer, the final bytes (the `ERROR`/`CLOSED`
line - the useful part) survive the truncation. `max=0` returns `NERR_PARAM`.
A diagnostic aid, like the ESP debug tail in the fido binkp client.

After a failed SEND the buffer instead holds

```
send failed <n>: <line>
```

because every transport failure maps to the single public status `NERR_SEND`.
`n` is the internal transport result (1 = ESP replied `ERROR`, 2 = `FAIL`,
3 = transmit timeout, 4 = no response); the optional line is the last complete
ESP response or recovery-probe line. The recovery probe still detects a late
`SEND OK` and module reboot exactly as before, but verbose byte counts,
first/tail capture, LSR formatting and textual probe verdicts are deliberately
not retained in the DLL image. This keeps `LASTERR` actionable while reserving
space for transport functionality.

Silent connect timeouts trigger a bounded recovery ladder: the DLL probes with
`AT` for up to ~10 s through the same +IPD-aware reader, reissues `CIPSTART`
once when command mode is proven alive, and accepts either a late target-link
`<id>,CONNECT` or `ALREADY CONNECTED` from that recovery retry as success. The
latter means the first attempt opened the same numbered link but its event was
lost; it is never accepted on an initial attempt, where it could describe a
stale endpoint. For SEND the probe is safe only after the complete payload left
the host; it can accept a late `SEND OK` or detect a reboot, but never reissues
the payload. Before the `>` prompt even an `AT` probe could be consumed as
payload if the prompt was merely late, so that path fails closed without
probing.

### Function 17 - SETOPT

- `UNET_OPT_CANCELKEYS` (1): DE=1 enables Esc / Ctrl+Z polling during blocking
  UART loops (a cancelled receive returns `NERR_CANCEL`). Default off - the DLL
  never touches the keyboard unless asked.
- `UNET_OPT_RXTRIG` (2): DE = 1/4/8/14 sets the 16550 RX FIFO auto-RTS trigger
  level. Default 4. Use a different value only for field diagnostics on
  specific hardware (see the overrun note). Returns `NERR_STATE` before
  `NETINIT` (the UART base is not known yet).
- `UNET_OPT_SENDSLICE` (3): DE = milliseconds of link **silence** after which
  a SEND suspends with `NERR_AGAIN` instead of blocking. 0 (the default)
  keeps sends fully blocking; non-zero values are clamped to >= 50. Gate on
  `UNET_CAP_ASYNCSEND`. See "Non-blocking SEND" below.

### Non-blocking SEND (CAP_ASYNCSEND, UNETESP >= 0.4)

A `CIPSEND` is a transaction: once the command text is out, a second copy may
be swallowed as payload, so "time out and retry" is never safe. Instead the
DLL keeps the transaction alive across calls:

- With `UNET_OPT_SENDSLICE` set, a SEND whose link stays **silent** for one
  quantum returns `NERR_AGAIN` with `DE` = bytes confirmed so far. Nothing is
  retransmitted and nothing is lost - `+IPD` frames that arrive while the
  transaction is parked were already stashed for their channels.
- Repeat the **same** call (same channel, buffer, length) to continue; the
  wait resumes exactly where it stopped, including a half-matched `+IPD,`
  prefix or a half-received response line. A different channel or different
  arguments while a transaction is pending return `NERR_STATE`.
- Between repeats the consumer may run its UI, poll the keyboard, and call
  RECV/STATUS freely: while a send is suspended RECV serves only buffered
  data and returns immediately (never touching the live stream), and STATUS
  never touches hardware. `UNET_RXF_XCHAN`/`UNET_ST_RXPEND` still work.
- Functions that transmit AT text (CONNECT, UDPOPEN, CLOSE, NETDONE, PING,
  RESOLVE, NETINIT) return `NERR_BUSY` while a SEND is pending and do not touch
  the UART. Only the same SEND may advance the transaction: completing it from
  another API call would lose its byte-count result, and a later SEND retry
  would duplicate stream bytes. Finish the SEND before CLOSE/NETDONE/free; use
  the explicit `NETRESET` tool if the module never returns to command mode.
- As long as data keeps flowing the quantum never fires: the slice measures
  silence, not total duration. A stalled ESP simply yields `NERR_AGAIN` every
  quantum until the module recovers or the consumer gives up.
- Silence that falls **inside** a `+IPD` frame capture still uses the internal
  5 s per-byte timeout. The captured prefix is committed and the exact unread
  payload count remains live; a later RECV/SEND continuation resumes that
  binary frame before any new AT text is allowed onto the UART.

`RACETEST -a` exercises this mode end to end (slice 200 ms, ticks `~` per
suspension, continuity-checked as always).

---

## Error codes

`NERR_OK`=0, `NERR_HW`=1, `NERR_NONET`=2, `NERR_DNS`=3, `NERR_CONNECT`=4,
`NERR_SEND`=5, `NERR_RECV_TIMEOUT`=6, `NERR_CLOSED`=7, `NERR_CANCEL`=8,
`NERR_PARAM`=9, `NERR_NOTSUP`=10, `NERR_STATE`=11, `NERR_TIMEOUT`=12,
`NERR_BUSY`=13, `NERR_PROTO`=14, `NERR_AGAIN`=15 (suspended send - not an
error; see "Non-blocking SEND").

---

## Network up

Before a consumer uses the network, it must be brought up by the standard
tools, exactly as for the stand-alone utilities:

- **ESP:** run `NETUP` (it joins Wi-Fi and publishes `NET=WIFI`, `NET_ESP_HW`,
  `NET_ESP_FW`, `NET_ESP_FLOW`, `NET_IP`, `NET_BAUD`, ...). `NETINIT` checks `NET=="WIFI"`
  and `NET_ESP_HW` non-empty. `NET_ESP_FW` is `2.2.1` or `2.2.2`; consumers
  that add an ESP-AT passive-receive path must gate it on `2.2.2`.
  `NET_ESP_FLOW` is `3` or `0` and records the UART flow mode negotiated by
  NETUP; the ESP backend reproduces it locally without reconfiguring the ESP.
- **RTL:** run `NETCFG -i` (static) and/or `IFUP` (DHCP) so `NET_IP` and
  `NET_MAC` are published.

`STATUS` with `A=0xFF` reports this state without touching the card.

---

## Usage patterns

### Request / response (HTTP GET or POST)

Open, send the whole request, read the response until the peer closes, then
close. Works for a POST whose body is any size (SEND chunks internally):

```
    NETINIT
    CONNECT   chan 0, "example.com", "80"
    SEND      chan 0, request buffer (headers + body), length
loop:
    RECV      chan 0, buf, max, 5000 ms
    ; A=NERR_OK, DE>0 -> consume DE bytes, loop
    ; A=NERR_OK, DE=0 -> idle, loop or give up
    ; A=NERR_CLOSED   -> consume any DE bytes, then stop
    CLOSE     chan 0
    NETDONE
```

The "FIN with a final segment" guarantee (see RECV) means the last bytes before
the close are always delivered.

### Interactive bidirectional stream (IRC / telnet / chat)

The same SEND/RECV pair drives a full-duplex session - no special "transparent"
mode is needed, and the identical code runs on both backends. Poll with a short
RECV timeout so the loop stays responsive:

```
    CONNECT   chan 0, host, port
loop:
    RECV      chan 0, buf, max, 150 ms   ; A=NERR_OK/DE=0 means "nothing yet, still alive"
    ; render received bytes; RXPAUSE around slow screen/disk work (see below)
    ; if the user typed something: SEND chan 0, line, len
    ; A=NERR_CLOSED -> session ended
    jr loop
```

**Data arriving during a SEND.** A peer frame can arrive between the `CIPSEND`
prompt and `SEND OK` (a window of a few tens of milliseconds per send). The ESP
send path parses *past* such interleaved `+IPD` frames without corrupting the
protocol state, and **UNETESP captures their payload into a 2 KB defer buffer
and replays it to the next RECV, in arrival order, ahead of any live data** -
so the race no longer loses bytes. A peer that only speaks when spoken to
(HTTP, NTP, most protocols) never enters the window; genuinely full-duplex peers
(chat, telnet server-push, binkp) are now handled losslessly without special
care. Notes:

- After a RECV that drained the defer buffer, `IX` bit1 is set while more
  captured (or live-partial) data remains - keep calling RECV, exactly as for a
  normal multi-frame read.
- If a single racing frame is larger than the free defer space it is dropped
  (not partially stored) and `IX` bit2 (data lost) is raised on the next RECV.
  With one MTU-sized frame per send window this does not occur in practice;
  **keeping SENDs short** (one line / one packet) keeps it that way.
- **Draining before sending** is no longer required for correctness, but is
  still a reasonable habit for latency-sensitive interactive loops.

The RTL backend has no such window (the card buffers receive independently), so
its consumers behave identically. (An ESP-only raw transparent pipe could still
be added behind the reserved `CAP_TRANSPARENT` bit and slots 18-23, but the
portable, now-lossless path is SEND/RECV.)

### Two channels

Backends with `CAP_MULTICHAN` hold two connections at once - channel 0 and
channel 1 - which is what passive FTP needs: commands and replies on the control
connection while the data connection transfers a file. UNETESP 0.3 and later
supports it (through ESP-AT multi-connection mode); UNETRTL does not, so branch
on the capability bit:

```
    GETCAPS                            ; DE bit4 (0x0010) = CAP_MULTICHAN
    CONNECT   chan 0, host, "21"       ; control
    ; ... login, TYPE I, PASV -> parse the 227 reply
    CONNECT   chan 1, pasv_host, pasv_port
    SEND      chan 0, "RETR file",13,10
loop:
    RECV      chan 1, buf, max, 4000 ms   ; data
    ; A=NERR_OK/DE>0   -> write DE bytes
    ; A=NERR_OK/DE=0   -> nothing yet; IX bit3 set means channel 0 has data
    ; A=NERR_CLOSED    -> server closed the data link: transfer complete
    RECV      chan 0, buf, max, 800 ms    ; picks up 150/226 whenever they came
    CLOSE     chan 1
    ; ... QUIT
    CLOSE     chan 0
    NETDONE                               ; also restores single-connection mode
```

Rules that make this work:

- **Read the channels in turn.** The backend reads one shared serial link, so a
  block that arrives for the channel you are *not* reading is buffered for it and
  the current read returns immediately with `DE=0` and `IX` bit3 set. That is a
  "switch channels" signal, not an idle link. `STATUS` reports the same thing
  (`0x04`) without consuming anything.
- **Order is preserved per channel.** Buffered data is always delivered before
  anything newer, and before that channel's `NERR_CLOSED`.
- **Both directions are safe while both channels are open.** Sending on the
  control channel during a data transfer is exactly the FTP pattern (`REST`,
  `RETR`, `STOR`, `LIST`), and data that arrives during those sends is captured
  the same way as in the single-channel case above.
- **Drain promptly.** Each channel has its own 2 KB buffer. If the channel you
  are ignoring receives more than that before you come back to it, the excess is
  dropped and flagged with `IX` bit2 on its next RECV. Alternating reads, keeping
  slow disk/screen work between them short, and using `RXPAUSE` around that work
  keeps the buffers shallow.
- **One thing at a time.** Do not call `CONNECT`, `RESOLVE` or `PING` while the
  peer on the other channel may transmit unprompted: those parse a line-based AT
  response and would consume peer data as text. In FTP this never happens - the
  data channel is opened between the `227` reply and the transfer command.

Uploads finish the other way round: the *client* closes the data channel to
signal end of file (`CLOSE` channel 1), then reads the `226` on the control
channel. `CLOSE` waits for the ESP's reply without swallowing peer data, so a
`226` racing the close is not lost.

---

## Avoiding UART overrun (ESP backend)

Lossless receive at speed depends on several layers; a consumer only has to
respect the last one:

1. **Hardware RTS/CTS on both sides.** `NETINIT` puts the 16550 in auto-flow
   mode with a 4-byte RX FIFO trigger and tells the ESP `flow=3`. When the
   FIFO fills, RTS drops in hardware and the ESP stops within a few byte-times;
   backpressure propagates through the ESP buffer and the TCP window.
2. **Command mode (+IPD), not transparent mode.** Frame boundaries give the ESP
   safe points to stop; a receive pause never corrupts a frame.
3. **RXPAUSE / RXRESUME - the consumer's job.** Before doing slow work between
   receives (writing to disk, repainting the screen), call RXPAUSE; call
   RXRESUME before the next RECV. `GETCAPS` bit `RXFLOW` tells you this backend
   needs it (the RTL backend does not - it buffers in the card and RXPAUSE is a
   no-op there, so the same consumer code is correct on both).
4. **Single owner of RTS.** The DLL never raises RTS on its own; it restores the
   pause state you set. Do not toggle RTS by any other means.

The default FIFO trigger is 4 bytes. The prior TR8 setting left only eight
byte-times for the ESP to observe RTS and caused periodic overruns in
SpecTalkZX. The "safer" 1-byte trigger throttles throughput to about 1 KB/s;
TR4 leaves 12 byte-times of headroom and is the tested default. `SETOPT RXTRIG`
can still select another trigger for field diagnostics.

---

## RTL backend appendix (UNETRTL.DLL - implementation guide)

The RTL8019A backend implements the *same* function numbers, error codes and
capability semantics, so a consumer is source-compatible. Implementation notes
for the sprinter-rtl8019a project:

- **Network up:** there is no `NET=WIFI` marker on RTL. Treat the network as up
  when `NET_IP` and `NET_MAC` are non-empty (published by `NETCFG -i` / `IFUP`).
  Recommended: also publish `NET=RTL` after bring-up (and remove it on
  `NETCFG -d`) so launchers can pick the DLL by `NET` value; still accept the
  legacy state (no `NET=`, but `NET_IP`+`NET_MAC` set).
- **NETINIT:** probe the card (honour `NET_RTL_HW`), then it is up.
- **CONNECT / SEND / RECV / CLOSE:** map onto the software stack -
  `RESOLVE.HOST` -> `RESOLVE.NEXT_HOP_FOR` -> `TCP.OPEN`, then `TCP.SEND` /
  `TCP.RECV` / `TCP.CLOSE`. SEND chunks at the TCP MSS (536); the ABI hides
  this exactly as UNETESP hides the 2048 CIPSEND cap.
- **RESOLVE:** software DNS via `dns_lib` / `resolve_lib`; format the A record
  as a dotted quad. `CAP_RESOLVE` is set and works (no `NERR_NOTSUP`).
- **PING:** software ICMP echo (as in the RTL `ping.asm`).
- **UDP:** connected UDP over the inline datagram framing used by the RTL
  UDPTEST / NTP / TFTP tools.
- **RXPAUSE / RXRESUME:** no-ops returning `NERR_OK`; the card buffers receive
  in its ~14.5 KB ring. Clear `CAP_RXFLOW`.
- **Capabilities:** at minimum `TCP | RESOLVE | PING`; add `UDP` and `RAWETH`
  as implemented. `CAP_RXFLOW` off.
- **Two channels (passive FTP):** implemented on the ESP side since UNETESP 0.3
  (`AT+CIPMUX=1`, one receive buffer per channel, `NETDONE` restoring
  `CIPMUX=0`); still open on RTL. True simultaneous connections there require
  two TCP contexts, demultiplexing inbound packets by IP/port tuple, a receive
  queue for the inactive connection, and independent seq/ACK/FIN timers -
  roughly +30-50% of the stack code. For the FTP control+data pattern the
  existing sequential `SAVE_CTX` / `RESTORE_CTX` context swap may be enough.
  When it lands, set `CAP_MULTICHAN`, accept channel 1, and follow the
  semantics in "[Two channels](#two-channels)": per-channel close, buffered
  data delivered before `NERR_CLOSED`, and - if the backend can buffer per
  channel - the optional `STATUS` pending bit and RECV flag bit3. Existing
  consumers are unaffected either way.
