/*
 * unet.h - C binding for the UNET universal network DLL (libman 1.3 / L1).
 *
 * For the SDCC Sprinter SDK. Loads a UNET backend DLL (UNETESP.DLL, or a
 * UNETRTL.DLL) into a 16 KB window and exposes the numbered functions as C
 * calls. One binary can drive either card - pass the DLL name to unet_load().
 *
 * Layout requirement: build the consumer in the COMPACT layout (CODE_LOC =
 * 0x8100, window 2) so the DLL can own window 1. All buffers you pass live in
 * the C program's data (window 2), which the DLL accepts; never load the DLL
 * into window 3 (the ESP UART is mapped there during calls).
 *
 * The full contract is in docs/UNETAPI.md; this header mirrors
 * src/include/unet.inc.
 */
#ifndef _UNET_H
#define _UNET_H

#include <sprinter.h>

/* ----- function numbers ----- */
#define UNET_FN_INIT        0
#define UNET_FN_FINI        1
#define UNET_FN_GETCAPS     2
#define UNET_FN_NETINIT     3
#define UNET_FN_NETDONE     4
#define UNET_FN_CONNECT     5
#define UNET_FN_SEND        6
#define UNET_FN_RECV        7
#define UNET_FN_CLOSE       8
#define UNET_FN_STATUS      9
#define UNET_FN_UDPOPEN     10
#define UNET_FN_RESOLVE     11
#define UNET_FN_PING        12
#define UNET_FN_RXPAUSE     13
#define UNET_FN_RXRESUME    14
#define UNET_FN_GETINFO     15
#define UNET_FN_LASTERR     16
#define UNET_FN_SETOPT      17

/* ----- error codes (returned in A / as -code) ----- */
#define NERR_OK             0
#define NERR_HW             1
#define NERR_NONET          2
#define NERR_DNS            3
#define NERR_CONNECT        4
#define NERR_SEND           5
#define NERR_RECV_TIMEOUT   6
#define NERR_CLOSED         7
#define NERR_CANCEL         8
#define NERR_PARAM          9
#define NERR_NOTSUP         10
#define NERR_STATE          11
#define NERR_TIMEOUT        12
#define NERR_BUSY           13
#define NERR_PROTO          14

/* ----- capability bits (from unet_caps) ----- */
#define UNET_CAP_TCP         0x0001
#define UNET_CAP_UDP         0x0002
#define UNET_CAP_RESOLVE     0x0004
#define UNET_CAP_PING        0x0008
#define UNET_CAP_MULTICHAN   0x0010
#define UNET_CAP_LISTEN      0x0020
#define UNET_CAP_RAWETH      0x0040
#define UNET_CAP_TRANSPARENT 0x0080
#define UNET_CAP_RXFLOW      0x0100

/* ----- GETINFO fields ----- */
#define UNET_IF_BACKEND     0
#define UNET_IF_IP          1
#define UNET_IF_MASK        2
#define UNET_IF_GW          3
#define UNET_IF_MAC         4
#define UNET_IF_DNS1        5
#define UNET_IF_DNS2        6
#define UNET_IF_IPSRC       7
#define UNET_IF_SSID        8
#define UNET_IF_BAUD        9
#define UNET_IF_NTP         10
#define UNET_IF_TZ          11
#define UNET_IF_HW          12

/* ----- SETOPT options ----- */
#define UNET_OPT_CANCELKEYS 1
#define UNET_OPT_RXTRIG     2

/* unet_load error codes (distinct from NERR_*, all negative) */
#define UNET_LOAD_OK         0
#define UNET_LOAD_ENOMEM    -1   /* GETMEM failed */
#define UNET_LOAD_EOPEN     -2   /* file not found / open failed */
#define UNET_LOAD_EFORMAT   -3   /* bad header / not an L1 DLL */
#define UNET_LOAD_ETOOBIG   -4   /* relocation bitmap larger than 1 KB */
#define UNET_LOAD_EINIT     -5   /* DLL INIT hook refused (e.g. wrong window) */
#define UNET_LOAD_EWINDOW   -6   /* window argument was not 1 or 2 */

/*
 * Load a UNET DLL into the given window (1 = 0x4000 or 2 = 0x8000; never 3).
 * Returns UNET_LOAD_OK (0) or a negative UNET_LOAD_* code.
 */
i8  unet_load(const char *dll_name, u8 window);

/* Unload: run the DLL FINI hook and free its page. */
void unet_free(void);

/* Capability bitmask (works before unet_init). */
u16 unet_caps(void);

/* Bring the link layer up. Returns NERR_OK or a NERR_* code. */
i8  unet_init(void);

/* Close the active channel; leave the network up. */
i8  unet_done(void);

/* Open a TCP connection. Returns NERR_OK or NERR_*. */
i8  unet_connect(const char *host, const char *port);

/* Open a connected UDP endpoint (lport may be NULL for a default local port). */
i8  unet_udpopen(const char *host, const char *rport, const char *lport);

/* Send len bytes. Returns bytes sent (>=0), or -(NERR_*) on failure. */
i16 unet_send(const void *buf, u16 len);

/*
 * Receive up to max bytes with a timeout. Returns:
 *   >0            bytes received
 *    0            timeout, connection still alive
 *   -NERR_CLOSED  peer closed (any bytes were returned on a prior call)
 *   -(NERR_*)     other error
 * flags (may be NULL) receives the RECV status bits (see docs/UNETAPI.md).
 */
i16 unet_recv(void *buf, u16 max, u16 timeout_ms, u16 *flags);

/* Close the active channel. */
i8  unet_close(void);

/* Resolve a host to a dotted quad in dst (>=16 bytes). NERR_NOTSUP if the
 * firmware/emulator lacks resolve; connect accepts host names directly. */
i8  unet_resolve(const char *host, char *dst);

/* Ping a host. Returns round-trip ms (>=0) or -(NERR_*). */
i16 unet_ping(const char *host, u16 timeout_ms);

/* Pause / resume receive (RTS) around slow consumer work. */
void unet_rxpause(void);
void unet_rxresume(void);

/* Copy a network info field into dst (NUL-terminated, truncated to max). */
i8  unet_getinfo(u8 field, char *dst, u16 max);

/* Copy the tail of the last driver response into dst (diagnostic). */
i8  unet_lasterr(char *dst, u16 max);

/* Set an option. Returns NERR_OK or NERR_PARAM. */
i8  unet_setopt(u8 option, u16 value);

/* Query network status without touching the hardware.
 * Returns NERR_OK if configured (bits: 1 = env set, 2 = init done), else
 * NERR_NONET. bits (may be NULL) receives the status bits. */
i8  unet_netstatus(u16 *bits);

#endif /* _UNET_H */
