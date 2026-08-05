# UNET bindings

Language bindings for the UNET universal network DLL. They let a program
written in C or Pascal (in addition to plain asm) load a UNET backend DLL
(`UNETESP.DLL`, or a future `UNETRTL.DLL`) through libman and drive TCP, UDP,
resolve and ping through one backend-agnostic interface.

The DLL contract is documented in [`../docs/UNETAPI.md`](../docs/UNETAPI.md);
the asm include is [`../src/include/unet.inc`](../src/include/unet.inc). These
bindings are developer material and are not shipped in the distribution ZIP.

Common rule for every consumer: **the DLL must own a full 16 KB window, and
never window 3** (the ESP UART is mapped there during calls). Load buffers you
pass to the DLL must live below `0xC000` and outside the DLL's window.
WIN0 pointers are allowed; a consumer that remaps WIN0 over DSS/system memory
is responsible for preserving and restoring that mapping safely.

DLL name resolution: libman opens the DLL by name through DSS, which searches
only the **current directory** - not `PATH`, not the program's own directory.
Run a consumer from the directory that holds the DLL, or pass a full path.
`UNETTEST.EXE` additionally tries its own EXE directory first (via DSS
`APPINFO`); the C and Pascal demos do not, so run them from the DLL's folder.

## asm

No binding needed - include the libman loader and call the numbered functions
directly. See [`../src/apps/unettest.asm`](../src/apps/unettest.asm) for a
complete example (it embeds [`../src/lib/libman13.asm`](../src/lib/libman13.asm)
and uses [`../src/include/unet.inc`](../src/include/unet.inc)).

## sdcc/ - C (SDCC Sprinter SDK)

- `unet.h`  - the C API (function numbers, error/capability codes, prototypes).
- `unet.c`  - a compact L1 DLL loader (allocate a page, map it, read the file,
  decompress the zero-RLE image, apply the relocation bitmap, run INIT) plus the
  call wrappers.
- `unetll.s` - a small sdasz80 trampoline that marshals the A/DE/IX/IY register
  convention the DLL expects.
- `unetdemo.c` + `Makefile` - a worked example.

Build the consumer in the **compact layout** (`CODE_LOC = 0x8100`, window 2) so
the DLL owns window 1; the Makefile sets this. The SDK targets **SDCC 2.9.0** -
point `SDK_DIR` at your SDK and set `SDCC290_BIN_DIR` in the SDK's
`config.local.mk` if needed:

```
make SDK_DIR=/path/to/sdcc-sprinter-sdk/
```

The loader streams the file through a 256-byte chunk buffer and decompresses
straight into the window, so its static footprint is ~1.3 KB (chunk + the 1 KB
relocation bitmap) and any DLL whose decoded image fits the 16 KB window
loads, regardless of file size.

Verified: the C files compile, `unetll.s` assembles, and the loader's
decode+relocation logic was checked byte-for-byte against a native assembly of
the DLL at its load address.

## tpascal/ - Turbo Pascal (DSS TPC)

- `UNETPAS.INC` - a thin wrapper over the SDK's `LIBMAN.INC`: UNET function
  numbers, error/capability codes, and typed call wrappers (`UNetLoad`,
  `UNetInit`, `UNetConnect`, `UNetSend`, `UNetRecv`, `UNetPing`, ...).
- `UNETDEMO.PAS` - a worked example.

Include order (the DSS cores and `LIBMAN.INC` come first):

    program MyApp;
    #I DSSCORE.INC       (use the real  {$I ...}  directive)
    #I DSSFILE.INC
    #I DSSSYS.INC
    #I LIBMAN.INC
    #I UNETPAS.INC

Build with `TPC /D:8000 /L:LIB UNETDEMO.PAS`. `/D:8000` keeps the program below
window 2 so the DLL can be loaded into window 2 (`UNetLoad('UNETESP.DLL', 2)`).

Verified: `UNETPAS.INC` and `UNETDEMO.PAS` compile under the DSS TPC compiler.

## Two channels

A backend that reports `UNET_CAP_MULTICHAN` / `UNetCapMultichan` in its
capability mask can hold **two** connections at once - channel 0 and channel 1 -
which is what a passive-FTP client needs (control on one, data on the other).
`UNETESP.DLL` 0.3 and later does; `UNETRTL.DLL` does not, so always gate on the
bit rather than assuming it:

```c
if (unet_caps() & UNET_CAP_MULTICHAN) {
    unet_connect_ch(0, host, "21");     /* control */
    unet_connect_ch(1, host, pasv_port); /* data    */
}
```

Both languages keep the original single-channel functions as channel-0 wrappers,
so existing programs need no changes. The channel-aware names are
`unet_connect_ch` / `unet_send_ch` / `unet_recv_ch` / `unet_close_ch` /
`unet_udpopen_ch` / `unet_status_ch` in C, and `UNetConnectCh`, `UNetSendCh`,
`UNetRecvCh`, `UNetCloseCh`, `UNetUdpOpenCh`, `UNetStatusCh` in Pascal.

Read the two channels in turn. A read that returns 0 bytes with `UNET_RXF_XCHAN`
(`UNetRxfXChan`) set in the RECV flags is not an idle link: the backend buffered
a block for the *other* channel and handed control back so you can switch. The
same information is available without reading, through `unet_status_ch` /
`UNetStatusCh` (`UNET_ST_RXPEND` / `UNetStRxPend`). A channel's close is
reported on that channel alone, and only after every byte it already received
has been delivered.

## Non-blocking sends (TUI programs)

A backend with `UNET_CAP_ASYNCSEND` / `UNetCapAsyncSend` (UNETESP 0.4+) can
suspend a send instead of blocking through an ESP stall. Enable it once with
`unet_setopt(UNET_OPT_SENDSLICE, 200)` / `UNetSetOpt(UNetOptSendSlice, 200)`;
then a send whose link stays silent for 200 ms returns `NERR_AGAIN` /
`NErrAgain`, and repeating the **same** call continues the transaction without
retransmitting anything:

```c
while ((r = unet_send_ch(ch, buf, len)) == -NERR_AGAIN) {
    tui_poll();                      /* keep the UI alive between slices */
    unet_recv_ch(ch, rx, sizeof rx, 50, &flags);  /* buffered data only */
}
```

While a transaction is pending, AT-producing calls such as CLOSE return
`NERR_BUSY`; finish the same SEND before closing/freeing the DLL. If the module
never returns to command mode, use the explicit `NETRESET` utility. See the
"Non-blocking SEND" section of [docs/UNETAPI.md](../docs/UNETAPI.md) for the
exact contract.

## Bring the network up first

None of these bindings configure the network. Run `NETUP` (Wi-Fi) or
`NETCFG -i` / `IFUP` (RTL) before a consumer calls `unet_init` / `UNetInit`.
