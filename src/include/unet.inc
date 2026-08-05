; ======================================================
; UNET - universal network DLL contract (libman 1.3 / L1)
; Shared ABI for UNETESP.DLL (ESP8266 / ESP-AT) and the future
; UNETRTL.DLL (RTL8019A). One interface, swappable backend.
;
; Consumers (asm / C / Pascal) load a backend DLL through libman 1.3
; (l_load / l_call / l_free) and drive the network through the numbered
; functions below. This file is the single source of truth for the
; function numbers, register ABI, error codes, capability bits, GETINFO
; fields and options. It is FROZEN: new capabilities extend the reserved
; slots and the caps bitmask, never renumber existing functions.
;
; -----------------------------------------------------------------------
; Calling convention (libman l_call):
;   Consumer: HL = handle, B = function number, then CALL l_call.
;   Arguments are passed ONLY in A, DE, IX, IY (HL and BC are consumed by
;   the libman dispatcher). Results come back in A, DE, IX, IY.
;   Every UNET function returns its status in A (0 = NERR_OK, else a
;   NERR_* code). The libman dispatcher does NOT propagate a user
;   function's carry flag, so consumers MUST test A, not CF.
;
; Memory / window discipline (enforced and documented):
;   - Load the DLL into window 1 (0x4000) or window 2 (0x8000) only.
;     NEVER window 3 (0xC000): the ESP backend maps the ISA UART there
;     during every call and would swap its own code out. UNETESP refuses
;     to initialise if it detects it was loaded into window 3.
;   - All caller buffers (host/port strings, send/recv payload, GETINFO
;     destinations) must live BELOW 0xC000 and OUTSIDE the 16 KB window
;     the DLL was loaded into - the WHOLE buffer, not just its first byte;
;     both ends of the range are validated. Violations return NERR_PARAM.
;     WIN0 pointers are accepted: mapping a caller-owned page over DSS/system
;     memory there, and restoring it safely, is entirely the caller's duty.
;   - Host strings are limited to 128 bytes, port strings to 15 bytes
;     (longer arguments return NERR_PARAM).
;   - Keep at least ~256 bytes of free stack across a call.
;   - The library is NOT reentrant; one call at a time.
; ======================================================

	IFNDEF	_UNET_INC
	DEFINE	_UNET_INC

; ABI version reported by GETCAPS in IX (major<<8 | minor). Consumers
; should verify the major byte before relying on the numbered functions.
UNET_ABI_VERSION	EQU 0x0100

; ------------------------------------------------------
; Function numbers (index passed in B to l_call)
; ------------------------------------------------------
UNET_FN_INIT		EQU 0	; libman load hook. Checks window, XOR A. Do not call directly.
UNET_FN_FINI		EQU 1	; libman free hook. Closes any open link, A=0. Do not call directly.
UNET_FN_GETCAPS		EQU 2	; ->  A=0, DE=caps bitmask, IX=UNET_ABI_VERSION. Callable before NETINIT.
UNET_FN_NETINIT		EQU 3	; ->  A (0 / NERR_NONET / NERR_HW / NERR_BUSY). Bring the link layer up.
UNET_FN_NETDONE		EQU 4	; Close the active channel, leave the network up. A=0. Idempotent.
UNET_FN_CONNECT		EQU 5	; A=channel, DE=host ASCIIZ, IX=port ASCIIZ  ->  A
				;   channel 0..1 when GETCAPS reports CAP_MULTICHAN,
				;   otherwise channel 0 only (else NERR_PARAM)
				;   retries internally while the backend reports "busy"
UNET_FN_SEND		EQU 6	; A=channel, DE=buffer, IX=length  ->  A, DE=bytes sent
				;   TCP: chunked internally at 2048 (ESP-AT CIPSEND cap).
				;   UDP: one datagram per call, length > 1472 -> NERR_PARAM.
				;   Peer data arriving DURING a send may be dropped by the ESP
				;   backend - drain RECV before sending (see docs/UNETAPI.md).
				;   With UNET_OPT_SENDSLICE > 0 may return NERR_AGAIN:
				;   repeat the same call to continue the transaction.
UNET_FN_RECV		EQU 7	; A=channel, DE=buffer, IX=max, IY=timeout_ms  ->  A, DE=received, IX=flags
				;   A=NERR_OK, DE=0            : nothing for this channel yet
				;                                (timeout, or the backend buffered
				;                                data for the OTHER channel - see
				;                                UNET_RXF_XCHAN)
				;   A=NERR_CLOSED             : peer closed (any DE bytes are valid first)
				;   IX flags: see UNET_RXF_* below
UNET_FN_CLOSE		EQU 8	; A=channel  ->  A. Idempotent. Closes ONE channel;
				;   use NETDONE to close every channel at once.
UNET_FN_STATUS		EQU 9	; A=channel  ->  A=0, DE=state (see UNET_ST_* below)
				;   A=0xFF     ->  network status WITHOUT touching hardware:
				;                  A=0/NERR_NONET, DE bit0 env configured, bit1 NETINIT done
UNET_FN_UDPOPEN		EQU 10	; A=channel, DE=host, IX=rport ASCIIZ, IY=lport ASCIIZ|0  ->  A
				;   retries internally while the backend reports "busy"
UNET_FN_RESOLVE		EQU 11	; DE=host ASCIIZ, IX=dest(>=16 bytes)  ->  A, dest="a.b.c.d",0
UNET_FN_PING		EQU 12	; DE=host ASCIIZ, IY=timeout_ms  ->  A, DE=round-trip ms
UNET_FN_RXPAUSE		EQU 13	; drop RTS so a slow consumer can catch up  ->  A
				;   NERR_STATE before NETINIT (UART base not known yet)
UNET_FN_RXRESUME	EQU 14	; raise RTS to resume receive  ->  A (NERR_STATE before NETINIT)
UNET_FN_GETINFO		EQU 15	; A=field id, DE=dest, IX=max(incl NUL)  ->  A; empty string if
				;   unset. IX=0 -> NERR_PARAM.
UNET_FN_LASTERR		EQU 16	; DE=dest, IX=max  ->  A=0; copies the TAIL of the last AT/driver
				;   response (the final ERROR/CLOSED line survives truncation)
UNET_FN_SETOPT		EQU 17	; A=option id, DE=value  ->  A
UNET_FN_RESERVED18	EQU 18	; reserved -> NERR_NOTSUP
UNET_FN_RESERVED19	EQU 19
UNET_FN_RESERVED20	EQU 20
UNET_FN_RESERVED21	EQU 21
UNET_FN_RESERVED22	EQU 22
UNET_FN_RESERVED23	EQU 23
UNET_FN_COUNT		EQU 24	; total slots in the jump table

; ------------------------------------------------------
; Error codes (returned in A). Superset of the ftpclient NERR_* set.
; ------------------------------------------------------
NERR_OK			EQU 0	; success
NERR_HW			EQU 1	; network hardware not found / not responding
NERR_NONET		EQU 2	; network not brought up (env not published)
NERR_DNS		EQU 3	; host name could not be resolved
NERR_CONNECT		EQU 4	; TCP/UDP connect failed
NERR_SEND		EQU 5	; send failed
NERR_RECV_TIMEOUT	EQU 6	; receive timed out (reserved; RECV returns OK/DE=0 for idle)
NERR_CLOSED		EQU 7	; connection closed by peer
NERR_CANCEL		EQU 8	; user cancelled (Esc / Ctrl+Z) - only when SETOPT CANCELKEYS=1
NERR_PARAM		EQU 9	; invalid argument (bad channel, buffer out of range, ...)
NERR_NOTSUP		EQU 10	; operation not supported by this backend/firmware
NERR_STATE		EQU 11	; wrong state (e.g. CONNECT before NETINIT, or already open)
NERR_TIMEOUT		EQU 12	; generic operation timeout (ping / resolve)
NERR_BUSY		EQU 13	; backend busy (ESP IP stack still warming up)
NERR_PROTO		EQU 14	; unexpected/protocol error in backend response
NERR_AGAIN		EQU 15	; SEND suspended: the link was silent for one
				; UNET_OPT_SENDSLICE quantum. Repeat the SAME call
				; (same channel/buffer/length) to continue the
				; transaction; DE = bytes confirmed so far. Only
				; backends with UNET_CAP_ASYNCSEND return this.

; ------------------------------------------------------
; Capability bits (returned in DE by GETCAPS)
; ------------------------------------------------------
UNET_CAP_TCP		EQU 0x0001	; TCP client connect/send/recv/close
UNET_CAP_UDP		EQU 0x0002	; connected UDP
UNET_CAP_RESOLVE	EQU 0x0004	; RESOLVE returns a dotted-quad (may still NERR_NOTSUP at runtime)
UNET_CAP_PING		EQU 0x0008	; ICMP-style ping
UNET_CAP_MULTICHAN	EQU 0x0010	; channels 0 and 1 can be open at the same time
					; (UNETESP >= 0.3; UNETRTL: 0)
UNET_CAP_LISTEN		EQU 0x0020	; inbound/listen sockets (neither backend: 0)
UNET_CAP_RAWETH		EQU 0x0040	; raw Ethernet frames (RTL only)
UNET_CAP_TRANSPARENT	EQU 0x0080	; ESP transparent byte-pipe mode (reserved extension)
UNET_CAP_RXFLOW		EQU 0x0100	; consumer must honour RXPAUSE/RXRESUME for lossless receive
UNET_CAP_ASYNCSEND	EQU 0x0200	; SEND can suspend with NERR_AGAIN instead of
					; blocking (see UNET_OPT_SENDSLICE); UNETRTL: 0

; UNETESP v1 advertises: TCP | UDP | RESOLVE | PING | RXFLOW = 0x010F
; UNETESP v0.3 adds MULTICHAN = 0x011F
; UNETESP v0.4 adds ASYNCSEND = 0x031F

; ------------------------------------------------------
; STATUS(channel) state bits (returned in DE)
; ------------------------------------------------------
UNET_ST_CONN		EQU 0x0002	; channel is connected (last known state)
UNET_ST_RXPEND		EQU 0x0004	; received data is buffered for this channel and
					; not delivered yet. OPTIONAL: only backends that
					; buffer per channel set it (UNETESP >= 0.3 with
					; CAP_MULTICHAN); UNETRTL never does, so consumers
					; must treat "not set" as "unknown", not as "empty".

; ------------------------------------------------------
; RECV flag bits (returned in IX)
; ------------------------------------------------------
UNET_RXF_TRUNC		EQU 0x0001	; oversized datagram was truncated. UNETESP never
					; truncates - its tail arrives on the next call
					; with UNET_RXF_MORE set.
UNET_RXF_MORE		EQU 0x0002	; more data is already buffered for this channel
UNET_RXF_LOST		EQU 0x0004	; UART overrun (LSR OE) or a dropped buffered frame
					; since the last call; per channel from v0.3
UNET_RXF_XCHAN		EQU 0x0008	; data is pending on the OTHER channel (v0.3,
					; optional). A read that returns DE=0 with this bit
					; set means "switch channels", not "link idle".

; ------------------------------------------------------
; GETINFO field ids (A on entry)
; ------------------------------------------------------
UNET_IF_BACKEND		EQU 0	; short backend tag, e.g. "ESP" / "RTL"
UNET_IF_IP		EQU 1	; station IPv4, dotted quad
UNET_IF_MASK		EQU 2	; netmask
UNET_IF_GW		EQU 3	; gateway
UNET_IF_MAC		EQU 4	; station MAC
UNET_IF_DNS1		EQU 5	; primary DNS
UNET_IF_DNS2		EQU 6	; secondary DNS
UNET_IF_IPSRC		EQU 7	; "STATIC" / "DHCP"
UNET_IF_SSID		EQU 8	; Wi-Fi SSID (ESP only; empty on RTL)
UNET_IF_BAUD		EQU 9	; UART baud (ESP only; empty on RTL)
UNET_IF_NTP		EQU 10	; configured NTP server
UNET_IF_TZ		EQU 11	; timezone
UNET_IF_HW		EQU 12	; hardware descriptor ("<slot>/#<base>")

; ------------------------------------------------------
; SETOPT option ids (A) and values (DE)
; ------------------------------------------------------
UNET_OPT_CANCELKEYS	EQU 1	; DE=1 poll Esc/Ctrl+Z during blocking UART loops (default 0)
UNET_OPT_RXTRIG		EQU 2	; DE=1/4/8/14 - RX FIFO auto-RTS trigger level (ESP; default 4).
				; NERR_STATE before NETINIT (UART base not known yet).
				; TR4 is the stable compromise: TR1 throttles ESP to ~1 KB/s,
				; while TR8 leaves too little headroom and causes overruns. Use
				; other values only for field diagnostics on specific hardware.
UNET_OPT_SENDSLICE	EQU 3	; DE=ms of link SILENCE after which SEND suspends with
				; NERR_AGAIN instead of blocking (0 = blocking, the default;
				; minimum 50 is enforced). Requires UNET_CAP_ASYNCSEND.
				; While a send is suspended, RECV serves only already
				; buffered data and returns immediately, and other
				; transmitting calls return NERR_BUSY without touching
				; the UART (see docs/UNETAPI.md).

	ENDIF
