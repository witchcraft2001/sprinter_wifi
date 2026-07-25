# UNET - universal network DLL API

UNET is a backend-agnostic network interface delivered as a libman 1.3 / L1
DLL. One contract, two interchangeable backends:

- **UNETESP.DLL** - Sprinter-WiFi (ESP8266 running ESP-AT firmware). Shipped
  and implemented in this package.
- **UNETRTL.DLL** - RTL8019A Ethernet card. Same function numbers and error
  codes; implemented separately in the sprinter-rtl8019a project (see the RTL
  appendix below).

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

Register discipline for every UNET function:

- Arguments are passed **only in A, DE, IX, IY**. HL and BC are consumed by the
  libman dispatcher.
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
| 5 | CONNECT | A=chan(0), DE=host, IX=port | A |
| 6 | SEND | A=chan, DE=buf, IX=len | A, DE=sent |
| 7 | RECV | A=chan, DE=buf, IX=max, IY=timeout_ms | A, DE=got, IX=flags |
| 8 | CLOSE | A=chan | A |
| 9 | STATUS | A=chan (or 0xFF) | A, DE=state |
| 10 | UDPOPEN | A=chan(0), DE=host, IX=rport, IY=lport\|0 | A |
| 11 | RESOLVE | DE=host, IX=dest(>=16) | A, dest="a.b.c.d" |
| 12 | PING | DE=host, IY=timeout_ms | A, DE=round-trip ms |
| 13 | RXPAUSE | - | A |
| 14 | RXRESUME | - | A |
| 15 | GETINFO | A=field, DE=dest, IX=max | A |
| 16 | LASTERR | DE=dest, IX=max | A=0 |
| 17 | SETOPT | A=option, DE=value | A |
| 18-23 | (reserved) | - | A=NERR_NOTSUP |

`host` and `port` are NUL-terminated ASCII strings (e.g. `"example.com",0` and
`"80",0`). The channel byte is reserved for a future second connection; v1
accepts only channel 0 and returns `NERR_PARAM` for anything else.

`NETINIT` must be called (and succeed) before `CONNECT`, `UDPOPEN`, `RESOLVE`
or `PING`; otherwise those return `NERR_STATE`.

### Function 0 / 1 - INIT / FINI

libman calls these at load and free. Do not call them directly. INIT verifies
the DLL was not loaded into window 3; FINI closes any still-open link.

### Function 2 - GETCAPS

Returns the capability bitmask in DE and the ABI version (`major<<8|minor`) in
IX. Callable before `NETINIT`. Check the ABI major byte before relying on the
numbered functions. UNETESP v1 reports `0x010F` =
`TCP | UDP | RESOLVE | PING | RXFLOW`.

### Function 3 - NETINIT

Brings the link layer up: verifies the network was configured (see
"Network up" below), finds and initialises the UART at the configured baud,
probes the ESP (resetting it once if silent), enables RTS/CTS flow control on
both sides, clears any leftover socket and selects single-connection mode.
Because clearing the sockets really closes any open link, NETINIT also resets
the channel state - a repeated `NETINIT` followed by `CONNECT` is safe.
Returns `NERR_OK`, `NERR_NONET` (not configured), `NERR_HW` (no card / no
response) or `NERR_BUSY` (ESP IP stack still warming up after join).

### Function 5 - CONNECT

Opens a TCP connection to `host:port`. Retries internally while the ESP
reports `busy` (its IP stack may still be warming up right after `NETUP`).
`NERR_DNS` if the name could not be resolved by the ESP, `NERR_CANCEL` if the
user cancelled a pending connect (with `CANCELKEYS` on), `NERR_CONNECT` for
any other failure.

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

Reads up to `max` bytes with an `IY` millisecond timeout. Returns:

- `A=NERR_OK, DE>0` - data received.
- `A=NERR_OK, DE=0` - timeout, connection still alive (use for polling).
- `A=NERR_CLOSED` - the peer closed the connection. **Any bytes already
  buffered are delivered first (DE>0, A=NERR_OK); the *next* call returns
  NERR_CLOSED with DE=0**, so a "FIN with a final data segment" never loses the
  tail.

IX returns status flags: bit1 = more data is immediately pending (the caller
buffer filled mid-frame; call RECV again), bit2 = a UART overrun (16550 LSR
overrun error) was observed since the last RECV. bit0 is reserved for backends
that truncate oversized datagrams; UNETESP delivers an oversized UDP datagram
across successive RECV calls instead (bit1 set) rather than dropping the tail.

### Function 9 - STATUS

With `A` = a channel number, returns the last-known channel state in DE
(0 = closed, 2 = connected). With `A = 0xFF`, returns network status **without
touching the hardware**: `A = NERR_OK` / `NERR_NONET`, and DE bit0 = the
network is configured (env published), bit1 = `NETINIT` has completed. Useful
for a launcher that wants to show status cheaply.

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

### Function 17 - SETOPT

- `UNET_OPT_CANCELKEYS` (1): DE=1 enables Esc / Ctrl+Z polling during blocking
  UART loops (a cancelled receive returns `NERR_CANCEL`). Default off - the DLL
  never touches the keyboard unless asked.
- `UNET_OPT_RXTRIG` (2): DE = 1/4/8/14 sets the 16550 RX FIFO auto-RTS trigger
  level. Default 4. Use a different value only for field diagnostics on
  specific hardware (see the overrun note). Returns `NERR_STATE` before
  `NETINIT` (the UART base is not known yet).

---

## Error codes

`NERR_OK`=0, `NERR_HW`=1, `NERR_NONET`=2, `NERR_DNS`=3, `NERR_CONNECT`=4,
`NERR_SEND`=5, `NERR_RECV_TIMEOUT`=6, `NERR_CLOSED`=7, `NERR_CANCEL`=8,
`NERR_PARAM`=9, `NERR_NOTSUP`=10, `NERR_STATE`=11, `NERR_TIMEOUT`=12,
`NERR_BUSY`=13, `NERR_PROTO`=14.

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

**Data arriving during a SEND.** The ESP send path is +IPD-aware only in the
sense that it parses *past* interleaved `+IPD` frames without corrupting the
protocol state - the payload of a frame that arrives between the `CIPSEND`
prompt and `SEND OK` is **discarded**, not buffered. In practice the window is
a few tens of milliseconds per send, and a peer that only speaks when spoken
to (HTTP, NTP, most protocols) is never inside it. For genuinely full-duplex
peers (chat, telnet server-push, binkp) follow two rules:

1. **Drain before sending**: call RECV with a short timeout until it returns
   `DE=0`, then SEND. Anything the peer already said is then safely delivered.
2. **Keep SENDs short** (one line / one packet), so the vulnerable window
   stays small.

This matches how the kit's TELNET client behaves at human interaction rates.
A future revision can close the race entirely by buffering the skipped
payload (the FTP client's no-wait send + receive-side `SEND OK` parsing); the
API will not change. (An ESP-only raw transparent pipe could also be added
behind the reserved `CAP_TRANSPARENT` bit and slots 18-23, but the portable
path is SEND/RECV.)

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
- **v2 - two channels (passive FTP):** the channel byte is already in the ABI.
  True simultaneous connections on RTL require two TCP contexts, demultiplexing
  inbound packets by IP/port tuple, a receive queue for the inactive
  connection, and independent seq/ACK/FIN timers - roughly +30-50% of the stack
  code. For the FTP control+data pattern the existing sequential
  `SAVE_CTX` / `RESTORE_CTX` context swap is sufficient. When multi-channel
  lands, set `CAP_MULTICHAN` and accept channel 1; existing consumers are
  unaffected. (On ESP the equivalent is `AT+CIPMUX=1`; `NETDONE` must then
  restore `CIPMUX=0`.)
