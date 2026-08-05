; ======================================================
; UNETTEST - backend-neutral smoke test for the UNET network DLL.
;
;   UNETTEST [-d FILE.DLL] [-u UDPPORT] [-2 DATAPORT] HOST [PORT]
;
; Loads a UNET DLL (default UNETESP.DLL) via libman into window 1, then walks
; the API: l_info, GETCAPS, SETOPT, STATUS, NETINIT, GETINFO, RESOLVE, PING,
; CONNECT, SEND (HTTP HEAD), a short RECV loop, CLOSE, NETDONE, l_free.
; -u UDPPORT swaps the TCP half for UDPOPEN / SEND / RECV against a datagram
; echo server instead (see tools/dev/udp_echo.py in the sibling RTL project).
; -2 DATAPORT swaps it for the two-channel exercise (control on PORT, data on
; DATAPORT at the same time), which needs CAP_MULTICHAN and pairs with
; tools/race_server.py --dual. Backends without it report and skip.
; Because the whole exercise goes through the DLL, the SAME binary tests any
; backend - point -d at UNETRTL.DLL to exercise the RTL card.
;
; This is a diagnostic tool (excluded from the ZIP package). It lives at
; ORG 0x8100 (window 2) so the DLL can own window 1; the stack and all buffers
; stay in window 2, below 0xC000 and outside the DLL's window.
;
; Exit codes: 0 ok, 1 usage, 2 hardware not found, 3 comm/protocol error,
;             4 network not configured.
; ======================================================

EXE_VERSION	EQU 1

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"
	INCLUDE "unet.inc"

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080			; code file offset
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START			; load address
	DW START			; entry point
	DW STACK_TOP			; initial stack
	DS 106, 0

	ORG 0x8100

START
	; DSS passes the command-line buffer pointer in IX at entry.
	LD	(CMDLINE_PTR),IX
	LD	SP,STACK_TOP

	LD	HL,MSG_BANNER
	CALL	PUTS_LN

	CALL	PARSE_ARGS

	; --- resolve + load the DLL into window 1 ---
	CALL	RESOLVE_DLL_PATH		; HL -> first candidate
	CALL	SAY_LOADING			; "Loading <HL>" (preserves HL)
	LD	A,1				; window 1
	CALL	LIBMAN.l_load
	JR	NC,.LOADED
	; EXE-dir candidate could not be OPENED? Retry the bare name in cwd.
	LD	A,(USED_EXEDIR)
	OR	A
	JP	Z,ERR_LOAD			; bare name already tried
	LD	A,(LIBMAN.l_reason)
	CP	LIBMAN.LR_OPEN
	JP	NZ,ERR_LOAD			; real load error - report it as-is
	LD	HL,DLL_NAME
	CALL	SAY_LOADING
	LD	A,1
	CALL	LIBMAN.l_load
	JP	C,ERR_LOAD
.LOADED
	LD	(HANDLE),HL

	; --- l_info: print name + version ---
	LD	HL,(HANDLE)
	LD	DE,INFO_BUF
	CALL	LIBMAN.l_info
	JP	C,ERR_INFO
	LD	HL,MSG_DLL
	CALL	PUTS
	LD	HL,INFO_BUF + 16		; header name field
	CALL	PUTS
	LD	HL,MSG_VER
	CALL	PUTS
	LD	A,(INFO_BUF + 15)		; version high (major)
	CALL	PUT_DEC_A
	LD	A,'.'
	CALL	PUT_CHAR
	LD	A,(INFO_BUF + 14)		; version low (minor)
	CALL	PUT_DEC_A
	CALL	CRLF

	; Take a read-only snapshot of the relocated image before the first public
	; call.  Apart from making loader failures diagnosable on real DSS, this
	; avoids blindly jumping through a damaged export table.
	CALL	SNAPSHOT_DLL
	JP	C,ERR_SNAPSHOT

	; --- GETCAPS ---
	LD	B,UNET_FN_GETCAPS
	CALL	DO_CALL				; -> DE=caps, IX=abi
	LD	(CAPS),DE
	PUSH	IX
	POP	HL
	LD	(ABI_VERSION),HL
	LD	HL,MSG_CAPS
	CALL	PUTS
	LD	DE,(CAPS)
	CALL	PUT_HEX16
	CALL	CRLF
	LD	HL,MSG_ABI
	CALL	PUTS
	LD	DE,(ABI_VERSION)
	CALL	PUT_HEX16
	CALL	CRLF

	; ABI 1.x requires TCP support.  A different ABI or a capability mask
	; without TCP means GETCAPS did not execute the loaded UNET entry point.
	; Stop here: calling SETOPT through the same damaged table can hang DSS.
	LD	A,(ABI_VERSION + 1)		; accept any compatible ABI 1.x
	CP	HIGH UNET_ABI_VERSION
	JP	NZ,ERR_BAD_IMAGE
	LD	A,(CAPS)
	AND	UNET_CAP_TCP
	JP	Z,ERR_BAD_IMAGE

	; --- SETOPT CANCELKEYS=1 (allow Esc/Ctrl+Z to abort blocking calls) ---
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,1
	LD	B,UNET_FN_SETOPT
	CALL	DO_CALL

	; --- STATUS 0xFF: network state without touching hardware ---
	LD	A,0xFF
	LD	B,UNET_FN_STATUS
	CALL	DO_CALL				; -> A, DE=bits
	LD	HL,MSG_NETSTAT
	CALL	PUTS				; preserves DE (the status bits)
	CALL	PRINT_STATUS_BITS
	CALL	CRLF

	; --- NETINIT ---
	LD	B,UNET_FN_NETINIT
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_NETINIT
	LD	HL,MSG_NETUP
	CALL	PUTS_LN

	; --- GETINFO: station IP ---
	XOR	A
	LD	(STR_BUF),A			; never print stale DSS RAM on an API error
	LD	A,UNET_IF_IP
	LD	DE,STR_BUF
	LD	IX,STR_BUF_SIZE
	LD	B,UNET_FN_GETINFO
	CALL	DO_CALL
	LD	(API_STATUS),A
	LD	HL,MSG_IP
	CALL	PUTS
	LD	A,(API_STATUS)
	OR	A
	JR	NZ,.ip_failed
	LD	HL,STR_BUF
	CALL	PUTS_LN
	JR	.after_ip
.ip_failed
	LD	HL,MSG_FAILED
	CALL	PUTS_LN
.after_ip

	; --- RESOLVE host (optional; degrades to unsupported) ---
	LD	HL,MSG_RESOLVE
	CALL	PUTS
	XOR	A
	LD	(STR_BUF),A
	LD	DE,HOST_BUFF
	LD	IX,STR_BUF
	LD	B,UNET_FN_RESOLVE
	CALL	DO_CALL
	CP	NERR_OK
	JR	NZ,.res_bad
	LD	HL,STR_BUF
	CALL	PUTS_LN
	JR	.after_resolve
.res_bad
	CP	NERR_NOTSUP
	JR	NZ,.res_err
	LD	HL,MSG_UNSUP
	CALL	PUTS_LN
	JR	.after_resolve
.res_err
	LD	HL,MSG_FAILED
	CALL	PUTS_LN
.after_resolve

	; --- PING host ---
	LD	HL,MSG_PING
	CALL	PUTS
	LD	DE,HOST_BUFF
	LD	IY,3000
	LD	B,UNET_FN_PING
	CALL	DO_CALL				; -> A, DE=ms
	OR	A
	JR	NZ,.ping_bad
	LD	(TMP16),DE
	LD	DE,(TMP16)
	PUSH	DE
	POP	HL
	CALL	PUT_DEC_HL
	LD	HL,MSG_MS
	CALL	PUTS_LN
	JR	.after_ping
.ping_bad
	LD	HL,MSG_FAILED
	CALL	PUTS_LN
.after_ping
	; -u / -2 select an exercise other than the plain TCP one.
	LD	A,(DUAL_MODE)
	AND	A
	JR	Z,.check_udp
	CALL	DUAL_PHASE
	JP	.teardown
.check_udp
	LD	A,(UDP_MODE)
	AND	A
	JR	Z,.tcp_phase
	CALL	UDP_PHASE
	JP	.teardown
.tcp_phase

	; --- CONNECT host:port ---
	LD	HL,MSG_CONNECT
	CALL	PUTS
	LD	HL,HOST_BUFF
	CALL	PUTS
	LD	A,':'
	CALL	PUT_CHAR
	LD	HL,PORT_BUFF
	CALL	PUTS_LN
	XOR	A				; channel 0
	LD	DE,HOST_BUFF
	LD	IX,PORT_BUFF
	LD	B,UNET_FN_CONNECT
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_CONNECT

	; --- SEND an HTTP HEAD request ---
	CALL	BUILD_REQUEST			; -> REQ_BUF, BC=length
	LD	(REQ_LEN),BC
	XOR	A				; channel 0
	LD	DE,REQ_BUF
	LD	IX,(REQ_LEN)
	LD	B,UNET_FN_SEND
	CALL	DO_CALL				; -> A, DE=sent
	OR	A
	JP	NZ,ERR_SEND
	LD	HL,MSG_SENT
	CALL	PUTS_LN

	; --- RECV loop (up to RECV_MAX_BLOCKS blocks) ---
	LD	A,RECV_MAX_BLOCKS
	LD	(RECV_LEFT),A
	LD	HL,MSG_REPLY
	CALL	PUTS_LN
.recv_loop
	LD	A,(RECV_LEFT)
	AND	A
	JR	Z,.recv_done
	DEC	A
	LD	(RECV_LEFT),A
	XOR	A				; channel 0
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE - 1
	LD	IY,4000
	LD	B,UNET_FN_RECV
	CALL	DO_CALL				; -> A, DE=got
	CP	NERR_OK
	JR	Z,.recv_ok
	CP	NERR_CLOSED
	JR	Z,.recv_closed_data
	; error
	LD	HL,MSG_RECV_ERR
	CALL	PUTS_LN
	JR	.recv_done
.recv_ok
	LD	A,D
	OR	E
	JR	Z,.recv_loop			; timeout, nothing this round
	CALL	PRINT_RECV
	JR	.recv_loop
.recv_closed_data
	LD	A,D
	OR	E
	JR	Z,.recv_closed
	CALL	PRINT_RECV
.recv_closed
	LD	HL,MSG_CLOSED
	CALL	PUTS_LN
.recv_done
.teardown

	; --- CLOSE / NETDONE / free ---
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	B,UNET_FN_NETDONE
	CALL	DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_free

	LD	HL,MSG_DONE
	CALL	PUTS_LN
	LD	B,0
	JP	EXIT

; ======================================================
; Error exits
; ======================================================
; DLL load failed: print WHY from LIBMAN.l_reason / LIBMAN.l_dsserr, exit 2.
ERR_LOAD
	LD	HL,MSG_ERR_LOAD
	CALL	PUTS_LN
	LD	A,(LIBMAN.l_reason)
	CP	LIBMAN.LR_OPEN
	JR	Z,.OPEN
	CP	LIBMAN.LR_FORMAT
	JR	Z,.FMT
	CP	LIBMAN.LR_INIT
	JR	Z,.INIT
	CP	LIBMAN.LR_MEMORY
	JR	Z,.MEM
	CP	LIBMAN.LR_LIMIT
	JR	Z,.LIMIT
	CP	LIBMAN.LR_CALL
	JR	Z,.CALL
	LD	HL,MSG_LOAD_IO			; LR_IO or anything unexpected
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.CALL
	LD	A,(LIBMAN.l_call_error)
	CP	LIBMAN.LCERR_HANDLE
	JR	Z,.CALL_HANDLE
	CP	LIBMAN.LCERR_WINDOW
	JR	Z,.CALL_WINDOW
	CP	LIBMAN.LCERR_SETWIN
	JR	Z,.CALL_SETWIN
	LD	HL,MSG_LOAD_CALL
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.CALL_HANDLE
	LD	HL,MSG_LOAD_CALL_HANDLE
	CALL	PUTS_LN
	JR	.OUT
.CALL_WINDOW
	LD	HL,MSG_LOAD_CALL_WINDOW
	CALL	PUTS_LN
	JR	.OUT
.CALL_SETWIN
	LD	HL,MSG_LOAD_CALL_SETWIN
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.LIMIT
	LD	HL,MSG_LOAD_LIMIT		; lib_table full - no DSS code to show
	CALL	PUTS_LN
	JR	.OUT
.OPEN
	LD	HL,MSG_LOAD_OPEN
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	LD	HL,MSG_LOAD_HINT
	CALL	PUTS_LN
	JR	.OUT
.MEM
	LD	HL,MSG_LOAD_MEM
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.FMT
	LD	HL,MSG_LOAD_FMT
	CALL	PUTS_LN
	JR	.OUT
.INIT
	LD	HL,MSG_LOAD_INIT
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
.OUT
	LD	B,2
	JP	EXIT

; l_info failed after a successful load (bad handle): its own message, exit 2.
ERR_INFO
	LD	HL,MSG_ERR_INFO
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT

; Print " (code <n>)" + CRLF from LIBMAN.l_dsserr.
PRINT_LOAD_CODE
	LD	HL,MSG_LOAD_CODE
	CALL	PUTS
	LD	A,(LIBMAN.l_dsserr)
	CALL	PUT_DEC_A
	LD	A,')'
	CALL	PUT_CHAR
	JP	CRLF
ERR_NETINIT
	; map A (NERR_*) to an exit code and message
	CP	NERR_NONET
	JR	Z,.cfg
	CP	NERR_HW
	JR	Z,.hw
	LD	HL,MSG_ERR_NETINIT
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	LD	B,3
	JP	EXIT
.cfg
	LD	HL,MSG_ERR_NONET
	CALL	PUTS_LN
	LD	B,4
	JP	EXIT
.hw
	LD	HL,MSG_ERR_HW
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT
ERR_CONNECT
	LD	HL,MSG_ERR_CONNECT
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT
ERR_SEND
	LD	HL,MSG_ERR_SEND
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT
ERR_UDPOPEN
	; NERR_NOTSUP is a legitimate answer from a backend without
	; CAP_UDP, so report it apart from a genuine failure.
	CP	NERR_NOTSUP
	JR	Z,.unsup
	LD	HL,MSG_ERR_UDPOPEN
	CALL	PUTS_LN
	CALL	DUMP_LASTERR
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT
.unsup
	LD	HL,MSG_UDP_UNSUP
	CALL	PUTS_LN
	CALL	FREE_AND_DONE
	LD	B,0
	JP	EXIT

USAGE_EXIT
	LD	HL,MSG_USAGE
	CALL	PUTS_LN
	LD	B,1
	JP	EXIT

; Best-effort close + free after a mid-session error.
FREE_AND_DONE
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_free
	RET

; Print LASTERR tail for diagnostics.
DUMP_LASTERR
	LD	HL,MSG_LASTERR
	CALL	PUTS
	XOR	A
	LD	(STR_BUF),A
	LD	DE,STR_BUF
	LD	IX,STR_BUF_SIZE
	LD	B,UNET_FN_LASTERR
	CALL	DO_CALL
	OR	A
	JR	NZ,.failed
	LD	HL,STR_BUF
	CALL	PUTS_LN
	RET
.failed
	LD	HL,MSG_FAILED
	CALL	PUTS_LN
	RET

EXIT
	LD	C,DSS_EXIT
	RST	DSS

; ======================================================
; libman call helper: args already in A/DE/IX/IY, B = function number.
; ======================================================
DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_call
	RET	NC
	LD	HL,MSG_ERR_CALL
	CALL	PUTS
	LD	A,(LIBMAN.l_call_error)
	CALL	PUT_DEC_A
	LD	HL,MSG_LOAD_CODE
	CALL	PUTS
	LD	A,(LIBMAN.l_call_dsserr)
	CALL	PUT_DEC_A
	LD	A,')'
	CALL	PUT_CHAR
	CALL	CRLF
	LD	B,2
	JP	EXIT

; ======================================================
; Snapshot the first 256 bytes of the relocated DLL image.
; This deliberately mirrors l_info's page lookup but copies enough bytes to
; include the export table and UNETESP's GETCAPS body.  Estex-DSS SETWIN3
; clobbers HL, so the source address is saved across RST #10.
; Out: CF=0 copied, CF=1 invalid handle or DSS_SETWIN3 failure.
; ======================================================
SNAPSHOT_DLL
	XOR	A
	LD	(SNAPSHOT_DSS_ERROR),A
	LD	HL,(HANDLE)
	LD	A,L
	ADD	A,A
	ADD	A,A
	LD	L,A
	LD	H,0
	LD	DE,LIBMAN.lib_table
	ADD	HL,DE
	LD	A,(HL)
	OR	A
	SCF
	RET	Z
	INC	HL
	LD	B,(HL)				; DSS memory-block descriptor
	INC	HL
	LD	A,(HL)				; logical image-base high byte
	LD	(DLL_BASE_H),A
	OR	0xC0
	LD	H,A
	LD	L,0
	IN	A,(0xE2)
	LD	(SNAPSHOT_OLD_WIN),A
	PUSH	HL
	LD	A,B
	LD	BC,0x003B			; DSS_SETWIN3, page 0
	RST	DSS
	POP	HL
	JR	C,.map_error
	LD	DE,DLL_PROBE
	LD	BC,DLL_PROBE_SIZE
	LDIR
	LD	A,(SNAPSHOT_OLD_WIN)
	OUT	(0xE2),A
	OR	A
	RET
.map_error
	LD	(SNAPSHOT_DSS_ERROR),A
	LD	A,(SNAPSHOT_OLD_WIN)
	OUT	(0xE2),A
	SCF
	RET

ERR_SNAPSHOT
	LD	HL,MSG_ERR_SNAPSHOT
	CALL	PUTS
	LD	A,(SNAPSHOT_DSS_ERROR)
	CALL	PUT_DEC_A
	LD	A,')'
	CALL	PUT_CHAR
	CALL	CRLF
	LD	B,2
	JP	EXIT

ERR_BAD_IMAGE
	LD	HL,MSG_ERR_BAD_IMAGE
	CALL	PUTS_LN
	LD	HL,MSG_IMAGE_SIZE
	CALL	PUTS
	LD	DE,(INFO_BUF + 2)
	CALL	PUT_HEX16
	LD	HL,MSG_CODE_SIZE
	CALL	PUTS
	LD	DE,(INFO_BUF + 4)
	CALL	PUT_HEX16
	CALL	CRLF
	LD	HL,MSG_ENTRY2
	CALL	PUTS
	LD	HL,DLL_PROBE + 0x26
	LD	B,3
	CALL	PRINT_HEX_BYTES
	CALL	CRLF
	LD	HL,MSG_GETCAPS_CODE
	CALL	PUTS
	LD	HL,DLL_PROBE + 0x81
	LD	B,9
	CALL	PRINT_HEX_BYTES
	CALL	CRLF
	LD	B,2
	JP	EXIT

; Print B bytes from HL as two hex digits separated by spaces.
PRINT_HEX_BYTES
	LD	A,(HL)
	CALL	PUT_HEX8
	INC	HL
	DJNZ	.more
	RET
.more
	LD	A,' '
	CALL	PUT_CHAR
	JR	PRINT_HEX_BYTES

; ======================================================
; UDP exercise (-u PORT): UDPOPEN -> SEND -> RECV -> verify echo.
; The caller does CLOSE / NETDONE / l_free, exactly as for TCP.
;
; A datagram is either echoed intact or not at all, so a mismatch here
; is a real defect in the UDP path rather than a partial transfer.
; ======================================================
UDP_PHASE
	LD	HL,MSG_UDP
	CALL	PUTS
	LD	HL,HOST_BUFF
	CALL	PUTS
	LD	A,':'
	CALL	PUT_CHAR
	LD	HL,UDP_PORT_BUF
	CALL	PUTS_LN

	XOR	A				; channel 0
	LD	DE,HOST_BUFF
	LD	IX,UDP_PORT_BUF
	LD	IY,0				; local port: backend default
	LD	B,UNET_FN_UDPOPEN
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_UDPOPEN

	; --- SEND the probe payload straight from the image ---
	XOR	A				; channel 0
	LD	DE,UDP_PAYLOAD
	LD	IX,UDP_PAYLOAD_LEN
	LD	B,UNET_FN_SEND
	CALL	DO_CALL				; -> A, DE=sent
	OR	A
	JP	NZ,ERR_SEND
	LD	HL,MSG_SENT
	CALL	PUTS_LN

	; --- RECV: one datagram per call; A=0 with DE=0 means "timed out,
	;     link still alive", so retry rather than give up at once. ---
	LD	A,UDP_MAX_TRIES
	LD	(RECV_LEFT),A
.wait
	LD	A,(RECV_LEFT)
	AND	A
	JR	Z,.no_reply
	DEC	A
	LD	(RECV_LEFT),A
	XOR	A				; channel 0
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE - 1
	LD	IY,2000
	LD	B,UNET_FN_RECV
	CALL	DO_CALL				; -> A, DE=got, IX=flags
	OR	A
	JR	NZ,.err
	LD	A,D
	OR	E
	JR	Z,.wait				; nothing this round
	LD	(UDP_RX_LEN),DE
	PUSH	IX
	POP	HL
	LD	A,L
	LD	(UDP_RX_FLAGS),A
	JR	.got
.err
	LD	HL,MSG_RECV_ERR
	CALL	PUTS_LN
	JP	DUMP_LASTERR
.no_reply
	LD	HL,MSG_UDP_NOREPLY
	CALL	PUTS_LN
	JP	DUMP_LASTERR
.got
	LD	HL,MSG_UDP_REPLY
	CALL	PUTS
	LD	HL,(UDP_RX_LEN)
	CALL	PUT_DEC_HL
	LD	HL,MSG_UDP_DATA
	CALL	PUTS
	LD	DE,(UDP_RX_LEN)
	CALL	PRINT_RECV			; terminates the buffer, then prints
	CALL	CRLF
	LD	A,(UDP_RX_FLAGS)
	AND	1				; bit0: datagram was truncated
	JR	Z,.compare
	LD	HL,MSG_UDP_TRUNC
	CALL	PUTS_LN
.compare
	CALL	UDP_ECHO_MATCH
	LD	HL,MSG_UDP_OK
	JR	Z,.verdict
	LD	HL,MSG_UDP_BAD
.verdict
	JP	PUTS_LN

; ======================================================
; Two-channel exercise (-2 DATAPORT): hold a control and a data connection at
; the same time, the way a passive-FTP client does.
;
;   channel 0 -> HOST:PORT      control: echoes a line back
;   channel 1 -> HOST:DATAPORT  data: streams a counter, then closes
;
; It checks the three things a single-channel backend cannot do: the data
; stream stays byte-continuous while the control channel is in use, a control
; reply that arrives DURING the data transfer is buffered instead of lost, and
; the data channel's close is reported on that channel alone.
; Pair with tools/race_server.py --dual.
; ======================================================
DUAL_PHASE
	LD	A,(CAPS)
	AND	UNET_CAP_MULTICHAN
	JR	NZ,.supported
	; A single-channel backend (UNETRTL) is not a failure here.
	LD	HL,MSG_DUAL_UNSUP
	JP	PUTS_LN
.supported
	LD	HL,MSG_DUAL
	CALL	PUTS
	LD	HL,PORT_BUFF
	CALL	PUTS
	LD	A,'/'
	CALL	PUT_CHAR
	LD	HL,DUAL_PORT_BUF
	CALL	PUTS_LN

	; --- control channel ---
	LD	HL,MSG_DUAL_CTRL_OPEN
	CALL	PUTS
	LD	HL,HOST_BUFF
	CALL	PUTS
	LD	A,':'
	CALL	PUT_CHAR
	LD	HL,PORT_BUFF
	CALL	PUTS_LN
	XOR	A
	LD	DE,HOST_BUFF
	LD	IX,PORT_BUFF
	LD	B,UNET_FN_CONNECT
	CALL	DO_CALL
	OR	A
	JP	NZ,DUAL_CONNECT_FAILED

	; --- data channel, opened while the control one stays up ---
	LD	HL,MSG_DUAL_DATA_OPEN
	CALL	PUTS
	LD	HL,HOST_BUFF
	CALL	PUTS
	LD	A,':'
	CALL	PUT_CHAR
	LD	HL,DUAL_PORT_BUF
	CALL	PUTS_LN
	LD	A,1
	LD	DE,HOST_BUFF
	LD	IX,DUAL_PORT_BUF
	LD	B,UNET_FN_CONNECT
	CALL	DO_CALL
	OR	A
	JP	NZ,DUAL_CONNECT_FAILED

	; --- send on the control channel while data is already streaming ---
	XOR	A
	LD	DE,DUAL_PROBE
	LD	IX,DUAL_PROBE_LEN
	LD	B,UNET_FN_SEND
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_SEND
	LD	HL,MSG_SENT
	CALL	PUTS_LN

	; --- drain the data channel until its peer closes ---
	XOR	A
	LD	(DUAL_NEXT),A
	LD	(DUAL_BAD),A
	LD	(DUAL_FAIL),A
	LD	(DUAL_CLOSED),A
	LD	A,DUAL_MAX_IDLE
	LD	(DUAL_IDLE),A
	LD	HL,0
	LD	(DUAL_TOTAL),HL
	LD	A,DUAL_MAX_ROUNDS
	LD	(RECV_LEFT),A
.data_loop
	LD	A,(RECV_LEFT)
	AND	A
	JR	Z,.data_done
	DEC	A
	LD	(RECV_LEFT),A
	LD	A,1
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE - 1
	LD	IY,4000
	LD	B,UNET_FN_RECV
	CALL	DO_CALL				; -> A, DE=got
	CP	NERR_CLOSED
	JR	Z,.data_closed
	CP	NERR_CANCEL
	JR	Z,.data_cancel
	OR	A
	JR	NZ,.data_err
	LD	A,D
	OR	E
	JR	NZ,.data_bytes
	; An empty read caused by data pending on the control channel is not a
	; four-second data timeout. Keep channel 1 selected for this stress test;
	; the global round bound still prevents an endless cross-channel spin.
	LD	A,IXL
	AND	LOW UNET_RXF_XCHAN
	JR	NZ,.data_loop
	LD	A,(DUAL_IDLE)
	DEC	A
	LD	(DUAL_IDLE),A
	JR	NZ,.data_loop
	LD	HL,MSG_DUAL_IDLE
	CALL	PUTS_LN
	LD	A,1
	LD	(DUAL_FAIL),A
	JR	.data_done
.data_bytes
	LD	A,DUAL_MAX_IDLE
	LD	(DUAL_IDLE),A
	CALL	DUAL_CHECK_SEQ
	JR	.data_loop
.data_cancel
	LD	HL,MSG_CANCELLED
	CALL	PUTS_LN
	LD	A,1
	LD	(DUAL_FAIL),A
	JP	.close_both
.data_err
	LD	HL,MSG_RECV_ERR
	CALL	PUTS_LN
	LD	A,1
	LD	(DUAL_FAIL),A
	JR	.data_done
.data_closed
	LD	A,1
	LD	(DUAL_CLOSED),A
	LD	A,D
	OR	E
	CALL	NZ,DUAL_CHECK_SEQ		; trailing bytes precede the close
	LD	HL,MSG_DUAL_CLOSED
	CALL	PUTS_LN
.data_done
	LD	A,(DUAL_CLOSED)
	AND	A
	JR	NZ,.have_close
	LD	A,1
	LD	(DUAL_FAIL),A
	LD	HL,MSG_DUAL_NOT_CLOSED
	CALL	PUTS_LN
.have_close
	LD	HL,MSG_DUAL_BYTES
	CALL	PUTS
	LD	HL,(DUAL_TOTAL)
	CALL	PUT_DEC_HL
	CALL	CRLF
	LD	A,(DUAL_BAD)
	AND	A
	LD	HL,MSG_DUAL_SEQ_OK
	JR	Z,.seq_verdict
	LD	HL,MSG_DUAL_SEQ_BAD
.seq_verdict
	CALL	PUTS_LN

	; --- the control reply must have survived the transfer ---
	XOR	A
	LD	B,UNET_FN_STATUS
	CALL	DO_CALL				; -> DE = state bits
	LD	A,E
	AND	UNET_ST_RXPEND
	LD	HL,MSG_DUAL_PEND
	JR	NZ,.pend_verdict
	LD	HL,MSG_DUAL_NOPEND
.pend_verdict
	CALL	PUTS_LN

	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE - 1
	LD	IY,4000
	LD	B,UNET_FN_RECV
	CALL	DO_CALL				; -> A, DE=got
	OR	A
	JR	NZ,.ctrl_err
	LD	A,D
	OR	E
	JR	Z,.ctrl_none
	PUSH	DE
	LD	HL,MSG_DUAL_CTRL
	CALL	PUTS
	CALL	PRINT_RECV
	CALL	CRLF
	POP	DE
	CALL	DUAL_CONTROL_MATCH
	JR	Z,.close_both
	LD	HL,MSG_DUAL_CTRL_BAD
	CALL	PUTS_LN
	LD	A,1
	LD	(DUAL_FAIL),A
	JR	.close_both
.ctrl_none
	LD	HL,MSG_DUAL_CTRL_NONE
	CALL	PUTS_LN
	LD	A,1
	LD	(DUAL_FAIL),A
	JR	.close_both
.ctrl_err
	LD	HL,MSG_RECV_ERR
	CALL	PUTS_LN
	LD	A,1
	LD	(DUAL_FAIL),A
.close_both
	LD	A,1
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	A,(DUAL_FAIL)
	AND	A
	RET	Z
	LD	HL,MSG_DUAL_FAILED
	CALL	PUTS_LN
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT

; A failed CONNECT here is the interesting case, so report the DLL status
; number as well as the ESP's own last words - "connect failed" alone does not
; say whether the link was refused, the channel was rejected, or the ESP
; answered something unexpected.
DUAL_CONNECT_FAILED
	PUSH	AF
	LD	HL,MSG_ERR_CONNECT
	CALL	PUTS
	LD	HL,MSG_DUAL_STATUS
	CALL	PUTS
	POP	AF
	CALL	PUT_DEC_A
	CALL	CRLF
	CALL	DUMP_LASTERR
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT

; Verify that DE bytes in RECV_BUF continue the counter stream and account for
; them. The server sends 0,1,2,...,255,0,... so one byte of state is enough.
DUAL_CHECK_SEQ
	PUSH	DE
	LD	HL,(DUAL_TOTAL)
	ADD	HL,DE
	LD	(DUAL_TOTAL),HL
	POP	BC				; BC = count
	LD	HL,RECV_BUF
.loop
	LD	A,B
	OR	C
	RET	Z
	LD	A,(DUAL_NEXT)
	CP	(HL)
	JR	Z,.ok
	LD	A,1
	LD	(DUAL_BAD),A
	LD	(DUAL_FAIL),A
	LD	A,(HL)				; resynchronise on the byte we got
.ok
	INC	A
	LD	(DUAL_NEXT),A
	INC	HL
	DEC	BC
	JR	.loop

; The dual test proves that the response generated while data was in flight
; survived. A late fallback response is useful server diagnostics, but it is
; not proof of the FTP-style race we are testing.
; In: DE=received byte count. Out: ZF=1 only for the exact expected reply.
DUAL_CONTROL_MATCH
	LD	HL,DUAL_EXPECT_LEN
	OR	A
	SBC	HL,DE
	RET	NZ
	LD	HL,RECV_BUF
	LD	DE,DUAL_EXPECT
	LD	B,DUAL_EXPECT_LEN
.loop
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	HL
	INC	DE
	DJNZ	.loop
	XOR	A
	RET

; Compare the received datagram with the payload we sent.
; Out: ZF=1 on an exact match. Trashes A, B, DE, HL.
UDP_ECHO_MATCH
	LD	HL,(UDP_RX_LEN)
	LD	DE,UDP_PAYLOAD_LEN
	OR	A
	SBC	HL,DE
	RET	NZ				; length differs
	LD	HL,RECV_BUF
	LD	DE,UDP_PAYLOAD
	LD	B,UDP_PAYLOAD_LEN
.loop
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	HL
	INC	DE
	DJNZ	.loop
	XOR	A				; ZF=1
	RET

; ======================================================
; Build "HEAD / HTTP/1.0\r\nHost: <host>\r\nConnection: close\r\n\r\n"
; into REQ_BUF. Out: BC = length (no terminator sent).
; ======================================================
BUILD_REQUEST
	LD	HL,REQ_BUF
	LD	DE,REQ_HEAD
	CALL	APPEND
	LD	DE,HOST_BUFF
	CALL	APPEND
	LD	DE,REQ_TAIL
	CALL	APPEND
	; length = HL - REQ_BUF
	LD	DE,REQ_BUF
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	RET

; Append ASCIIZ (DE) to buffer (HL). Out: HL at terminator.
APPEND
	LD	A,(DE)
	AND	A
	RET	Z
	LD	(HL),A
	INC	HL
	INC	DE
	JR	APPEND

; ======================================================
; Command-line parsing:  [-d FILE.DLL] [-u UDPPORT] HOST [PORT]
; Flags may appear in any order but must precede HOST.
; ======================================================
PARSE_ARGS
	; defaults
	LD	HL,DEF_DLL
	LD	DE,DLL_NAME
	CALL	STRCPY
	LD	HL,DEF_HOST
	LD	DE,HOST_BUFF
	CALL	STRCPY
	LD	HL,DEF_PORT
	LD	DE,PORT_BUFF
	CALL	STRCPY
	XOR	A
	LD	(DLL_ARG_FLAG),A		; default: no -d, resolve beside the EXE
	LD	(UDP_MODE),A			; default: TCP exercise
	LD	(DUAL_MODE),A
	; init parse state
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	LD	(PARSE_LEFT),A
	INC	HL
	LD	(PARSE_PTR),HL
.next_flag
	LD	DE,TOKEN_BUF
	LD	C,TOKEN_BUF_SIZE
	CALL	NEXT_TOKEN
	RET	C				; no more args -> defaults
	LD	A,(TOKEN_BUF)
	CP	'-'
	JR	NZ,.host_is_tok
	LD	HL,TOKEN_BUF
	LD	DE,STR_DASH_D
	CALL	STREQ				; trashes C
	JR	Z,.flag_d
	LD	HL,TOKEN_BUF
	LD	DE,STR_DASH_U
	CALL	STREQ
	JR	Z,.flag_u
	LD	HL,TOKEN_BUF
	LD	DE,STR_DASH_2
	CALL	STREQ
	JR	Z,.flag_2
	JP	USAGE_EXIT			; unknown flag
.flag_d
	LD	DE,DLL_NAME
	LD	C,DLL_NAME_SIZE
	CALL	NEXT_TOKEN
	JP	C,USAGE_EXIT			; -d without a file name
	LD	A,1
	LD	(DLL_ARG_FLAG),A		; use DLL_NAME verbatim (may hold a path)
	JR	.next_flag
.flag_u
	LD	DE,UDP_PORT_BUF
	LD	C,PORT_BUFF_SIZE
	CALL	NEXT_TOKEN
	JP	C,USAGE_EXIT			; -u without a port
	LD	A,1
	LD	(UDP_MODE),A
	JR	.next_flag
.flag_2
	LD	DE,DUAL_PORT_BUF
	LD	C,PORT_BUFF_SIZE
	CALL	NEXT_TOKEN
	JP	C,USAGE_EXIT			; -2 without a data port
	LD	A,1
	LD	(DUAL_MODE),A
	JR	.next_flag
.host_is_tok
	LD	HL,TOKEN_BUF
	LD	DE,HOST_BUFF
	CALL	STRCPY
	LD	DE,PORT_BUFF
	LD	C,PORT_BUFF_SIZE
	CALL	NEXT_TOKEN			; optional; ignore CF
	RET

; ======================================================
; Choose the file name passed to LIBMAN.l_load.
;   -d given : the user's string verbatim (may carry its own path).
;   default  : "<exe_home>\UNETESP.DLL" via DSS APPINFO; on any APPINFO
;              problem fall back to the bare name (then cwd IS the EXE dir,
;              same tolerance NETUP applies to NET.CFG).
; Out: HL -> ASCIIZ candidate; (USED_EXEDIR)=1 when HL = DLL_PATH.
; ======================================================
RESOLVE_DLL_PATH
	XOR	A
	LD	(USED_EXEDIR),A
	LD	A,(DLL_ARG_FLAG)
	OR	A
	JR	NZ,.BARE			; -d: use DLL_NAME as typed
	LD	HL,DLL_PATH
	LD	B,APPINFO_EXE_HOMEDIR
	LD	C,DSS_APPINFO
	RST	DSS
	JR	C,.BARE				; APPINFO unsupported -> cwd
	LD	HL,DLL_PATH
	LD	BC,DLL_PATH_SIZE - DLL_DEF_RESERVE
.FIND_END
	LD	A,(HL)
	OR	A
	JR	Z,.HAVE_END
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.FIND_END
	JR	.BARE				; overlong/malformed result
.HAVE_END
	LD	A,(DLL_PATH)
	OR	A
	JR	Z,.BARE				; empty result
	DEC	HL
	LD	A,(HL)
	INC	HL
	CP	92				; '\'
	JR	Z,.APPEND
	CP	'/'
	JR	Z,.APPEND
	LD	(HL),92				; add path separator
	INC	HL
.APPEND
	EX	DE,HL				; DE -> append point
	LD	HL,DLL_NAME			; default name placed there by PARSE_ARGS
	CALL	STRCPY
	LD	A,1
	LD	(USED_EXEDIR),A
	LD	HL,DLL_PATH
	RET
.BARE
	LD	HL,DLL_NAME
	RET

; Print "Loading <HL>" + CRLF, preserving HL.
SAY_LOADING
	PUSH	HL
	LD	HL,MSG_LOADING
	CALL	PUTS
	POP	HL
	PUSH	HL
	CALL	PUTS_LN
	POP	HL
	RET

; Copy next whitespace-delimited token from the parse state to (DE),
; truncated to C-1 chars (C = destination size incl NUL).
; Out: CF=1 if no token remains.
NEXT_TOKEN
	PUSH	DE
	DEC	C				; capacity without the NUL
.skip
	LD	A,(PARSE_LEFT)
	AND	A
	JR	Z,.none
	LD	HL,(PARSE_PTR)
	LD	A,(HL)
	CP	0x21
	JR	NC,.start
	CALL	.advance
	JR	.skip
.start
	POP	DE
	PUSH	DE
.copy
	LD	A,(PARSE_LEFT)
	AND	A
	JR	Z,.end
	LD	HL,(PARSE_PTR)
	LD	A,(HL)
	CP	0x21
	JR	C,.end
	INC	C
	DEC	C				; capacity left?
	JR	Z,.nostore			; truncate: keep consuming the token
	LD	(DE),A
	INC	DE
	DEC	C
.nostore
	CALL	.advance
	JR	.copy
.end
	XOR	A
	LD	(DE),A
	POP	DE
	AND	A				; CF=0
	RET
.none
	POP	DE
	SCF
	RET
.advance
	LD	HL,(PARSE_PTR)
	INC	HL
	LD	(PARSE_PTR),HL
	LD	A,(PARSE_LEFT)
	DEC	A
	LD	(PARSE_LEFT),A
	RET

; ======================================================
; Small string / print helpers
; ======================================================
STRCPY
	LD	A,(HL)
	LD	(DE),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	STRCPY

; Compare ASCIIZ (HL) and (DE). Out: ZF=1 if equal.
STREQ
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	CP	C
	RET	NZ
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	STREQ

; Print ASCIIZ (HL).
PUTS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	RET

; Print ASCIIZ (HL) + CRLF.
PUTS_LN
	CALL	PUTS
CRLF
	LD	HL,MSG_CRLF
	JR	PUTS

; Print one char (A).
PUT_CHAR
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	RET

; Print DE as 4 hex digits.
PUT_HEX16
	LD	A,D
	CALL	PUT_HEX8
	LD	A,E
PUT_HEX8
	PUSH	AF
	RRA
	RRA
	RRA
	RRA
	CALL	PUT_NIB
	POP	AF
PUT_NIB
	AND	0x0F
	ADD	A,0x90
	DAA
	ADC	A,0x40
	DAA
	JP	PUT_CHAR

; Print A as unsigned decimal (0..255).
PUT_DEC_A
	LD	L,A
	LD	H,0
	; fall through
; Print HL as unsigned decimal.
PUT_DEC_HL
	LD	DE,DEC_BUF + 6
	XOR	A
	LD	(DE),A
.next
	DEC	DE
	CALL	DIV10_HL
	ADD	A,'0'
	LD	(DE),A
	LD	A,H
	OR	L
	JR	NZ,.next
	EX	DE,HL
	JP	PUTS

; HL /= 10, remainder in A.
DIV10_HL
	PUSH	BC
	LD	BC,0x0D0A
	XOR	A
	ADD	HL,HL
	RLA
	ADD	HL,HL
	RLA
	ADD	HL,HL
	RLA
.dl1
	ADD	HL,HL
	RLA
	CP	C
	JR	C,.dl2
	SUB	C
	INC	L
.dl2
	DJNZ	.dl1
	POP	BC
	RET

; Print "cfg=<0/1> init=<0/1>" from status bits in DE.
PRINT_STATUS_BITS
	PUSH	DE
	LD	HL,MSG_CFG
	CALL	PUTS
	POP	DE
	PUSH	DE
	LD	A,E
	AND	1
	CALL	PUT_BIT
	LD	HL,MSG_INIT
	CALL	PUTS
	POP	DE
	LD	A,E
	AND	2
	JR	Z,.zero
	LD	A,1
.zero
	JP	PUT_BIT

PUT_BIT
	ADD	A,'0'
	JP	PUT_CHAR

; Print RECV_BUF as text, DE = byte count. NUL-terminate then print.
PRINT_RECV
	LD	H,D
	LD	L,E
	LD	DE,RECV_BUF
	ADD	HL,DE				; HL = RECV_BUF + count
	LD	(HL),0				; terminate
	LD	HL,RECV_BUF
	JP	PUTS

; ======================================================
; Strings
; ======================================================
MSG_BANNER	DB "UNETTEST - universal network DLL smoke test",0
MSG_USAGE	DB "Usage: UNETTEST [-d FILE.DLL] [-u UDPPORT] [-2 DATAPORT] [HOST [PORT]]",0
MSG_LOADING	DB "Loading ",0
MSG_DLL		DB "DLL: ",0
MSG_VER		DB "  v",0
MSG_CAPS	DB "caps=0x",0
MSG_ABI		DB "abi=0x",0
MSG_NETSTAT	DB "net: ",0
MSG_CFG		DB "cfg=",0
MSG_INIT	DB " init=",0
MSG_NETUP	DB "NETINIT ok",0
MSG_IP		DB "IP: ",0
MSG_RESOLVE	DB "resolve: ",0
MSG_UNSUP	DB "unsupported (emulator/firmware gap)",0
MSG_PING	DB "ping: ",0
MSG_MS		DB " ms",0
MSG_CONNECT	DB "connect ",0
MSG_SENT	DB "request sent",0
MSG_REPLY	DB "--- reply ---",0
MSG_CLOSED	DB "--- closed ---",0
MSG_DONE	DB "done.",0
MSG_FAILED	DB "failed",0
MSG_RECV_ERR	DB "receive error",0
MSG_LASTERR	DB "lasterr: ",0
MSG_ERR_LOAD	DB "Cannot load DLL:",0
MSG_LOAD_OPEN	DB "DLL file not found",0
MSG_LOAD_HINT	DB "Put the DLL next to UNETTEST.EXE or use -d DIR",92,"FILE.DLL",0
MSG_LOAD_MEM	DB "out of DSS memory",0
MSG_LOAD_IO	DB "DLL read/seek error",0
MSG_LOAD_FMT	DB "not an L0/L1 DLL (bad file format)",0
MSG_LOAD_INIT	DB "DLL refused to start (wrong window?)",0
MSG_LOAD_LIMIT	DB "too many DLLs loaded (64 max)",0
MSG_LOAD_CALL	DB "LibMan INIT dispatch failed",0
MSG_LOAD_CALL_HANDLE	DB "LibMan lost the loaded DLL table entry.",0
MSG_LOAD_CALL_WINDOW	DB "LibMan produced an invalid DLL window descriptor.",0
MSG_LOAD_CALL_SETWIN	DB "DSS could not map the DLL page",0
MSG_ERR_INFO	DB "DLL loaded but info query failed.",0
MSG_ERR_CALL	DB "LibMan call failed at stage ",0
MSG_ERR_SNAPSHOT	DB "Cannot inspect loaded DLL (DSS code ",0
MSG_ERR_BAD_IMAGE	DB "Invalid DLL ABI/capabilities; stopping before SETOPT.",0
MSG_IMAGE_SIZE	DB "image=0x",0
MSG_CODE_SIZE	DB " code=0x",0
MSG_ENTRY2	DB "entry2: ",0
MSG_GETCAPS_CODE	DB "getcaps@+81: ",0
MSG_LOAD_CODE	DB " (code ",0
MSG_ERR_NETINIT	DB "NETINIT failed.",0
MSG_ERR_NONET	DB "Network not configured - run NETUP first.",0
MSG_ERR_HW	DB "Network hardware not found.",0
MSG_ERR_CONNECT	DB "Connect failed.",0
MSG_ERR_SEND	DB "Send failed.",0
MSG_ERR_UDPOPEN	DB "UDPOPEN failed.",0
MSG_UDP		DB "udp ",0
MSG_UDP_REPLY	DB "udp reply: len=",0
MSG_UDP_DATA	DB " data=",0
MSG_UDP_TRUNC	DB "(datagram truncated to the receive buffer)",0
MSG_UDP_OK	DB "udp echo ok",0
MSG_UDP_BAD	DB "udp echo MISMATCH",0
MSG_UDP_NOREPLY	DB "no udp reply",0
MSG_UDP_UNSUP	DB "UDP not supported by this backend.",0
MSG_DUAL	DB "dual channel ports ",0
MSG_DUAL_CTRL_OPEN DB "connect control ",0
MSG_DUAL_DATA_OPEN DB "connect data ",0
MSG_DUAL_STATUS	DB " status ",0
MSG_DUAL_UNSUP	DB "two channels not supported by this backend (no CAP_MULTICHAN)",0
MSG_DUAL_CLOSED	DB "data channel closed by peer",0
MSG_DUAL_NOT_CLOSED DB "data channel did not close cleanly",0
MSG_DUAL_IDLE	DB "data channel timed out",0
MSG_DUAL_BYTES	DB "data bytes: ",0
MSG_DUAL_SEQ_OK	DB "data stream continuous",0
MSG_DUAL_SEQ_BAD DB "data stream GAP - bytes were lost",0
MSG_DUAL_PEND	DB "control data buffered during the transfer (STATUS RXPEND)",0
MSG_DUAL_NOPEND	DB "no control data pending",0
MSG_DUAL_CTRL	DB "control reply: ",0
MSG_DUAL_CTRL_NONE DB "control channel returned nothing",0
MSG_DUAL_CTRL_BAD DB "unexpected/late control reply",0
MSG_DUAL_FAILED DB "dual channel test FAILED",0
MSG_CANCELLED	DB "cancelled",0
DUAL_PROBE	DB "UNETTEST DUAL CONTROL",13,10
DUAL_PROBE_LEN	EQU $ - DUAL_PROBE
DUAL_EXPECT	DB "CONTROL REPLY DURING TRANSFER",13,10
DUAL_EXPECT_LEN	EQU $ - DUAL_EXPECT
MSG_CRLF	DB 13,10,0

DEF_DLL		DB "UNETESP.DLL",0
DEF_HOST	DB "example.com",0
DEF_PORT	DB "80",0
STR_DASH_D	DB "-d",0
STR_DASH_U	DB "-u",0
STR_DASH_2	DB "-2",0

REQ_HEAD	DB "HEAD / HTTP/1.0",13,10,"Host: ",0
REQ_TAIL	DB 13,10,"Connection: close",13,10,13,10,0

; Echo probe: sent with an explicit length, so no terminator travels.
UDP_PAYLOAD	DB "SPRINTER UNETTEST UDP"
UDP_PAYLOAD_LEN	EQU $ - UDP_PAYLOAD

	ENDMODULE

; ======================================================
; Embedded libman 1.3 loader
; ======================================================
	INCLUDE "libman13.asm"

; ======================================================
; BSS (runtime buffers) - placed after all code, inside window 2.
; ======================================================
	MODULE MAIN

RECV_BUF_SIZE	EQU 512
STR_BUF_SIZE	EQU 96
REQ_BUF_SIZE	EQU 160
TOKEN_BUF_SIZE	EQU 64
DLL_NAME_SIZE	EQU 128			; -d value may carry a directory path
DLL_PATH_SIZE	EQU 272			; APPINFO dir (<=256) + '\' + name + NUL
DLL_DEF_RESERVE	EQU 16			; '\' + "UNETESP.DLL" + NUL headroom
HOST_BUFF_SIZE	EQU 64
PORT_BUFF_SIZE	EQU 16

BSS_BASE	EQU $
HANDLE		EQU BSS_BASE
CAPS		EQU HANDLE + 2
ABI_VERSION	EQU CAPS + 2
API_STATUS	EQU ABI_VERSION + 2
TMP16		EQU API_STATUS + 1
REQ_LEN		EQU TMP16 + 2
RECV_LEFT	EQU REQ_LEN + 2
CMDLINE_PTR	EQU RECV_LEFT + 1
PARSE_PTR	EQU CMDLINE_PTR + 2
PARSE_LEFT	EQU PARSE_PTR + 2
DLL_ARG_FLAG	EQU PARSE_LEFT + 1	; 1 = -d given, use DLL_NAME verbatim
USED_EXEDIR	EQU DLL_ARG_FLAG + 1	; 1 = first candidate was DLL_PATH
UDP_MODE	EQU USED_EXEDIR + 1	; 1 = -u given, run the UDP exercise
UDP_RX_LEN	EQU UDP_MODE + 1
UDP_RX_FLAGS	EQU UDP_RX_LEN + 2
DUAL_MODE	EQU UDP_RX_FLAGS + 1	; 1 = -2 given, run the two-channel exercise
DUAL_NEXT	EQU DUAL_MODE + 1	; next expected byte of the data stream
DUAL_BAD	EQU DUAL_NEXT + 1	; 1 = the data stream lost continuity
DUAL_FAIL	EQU DUAL_BAD + 1	; 1 = any fatal dual-test condition
DUAL_CLOSED	EQU DUAL_FAIL + 1	; 1 = data peer close was observed
DUAL_IDLE	EQU DUAL_CLOSED + 1	; consecutive real data timeouts left
DUAL_TOTAL	EQU DUAL_IDLE + 1	; bytes received on the data channel
DEC_BUF		EQU DUAL_TOTAL + 2
INFO_BUF	EQU DEC_BUF + 8
DLL_NAME	EQU INFO_BUF + 32
DLL_PATH	EQU DLL_NAME + DLL_NAME_SIZE
HOST_BUFF	EQU DLL_PATH + DLL_PATH_SIZE
PORT_BUFF	EQU HOST_BUFF + HOST_BUFF_SIZE
UDP_PORT_BUF	EQU PORT_BUFF + PORT_BUFF_SIZE
DUAL_PORT_BUF	EQU UDP_PORT_BUF + PORT_BUFF_SIZE
TOKEN_BUF	EQU DUAL_PORT_BUF + PORT_BUFF_SIZE
STR_BUF		EQU TOKEN_BUF + TOKEN_BUF_SIZE
REQ_BUF		EQU STR_BUF + STR_BUF_SIZE
RECV_BUF	EQU REQ_BUF + REQ_BUF_SIZE
DLL_BASE_H	EQU RECV_BUF + RECV_BUF_SIZE
SNAPSHOT_OLD_WIN	EQU DLL_BASE_H + 1
SNAPSHOT_DSS_ERROR	EQU SNAPSHOT_OLD_WIN + 1
DLL_PROBE	EQU SNAPSHOT_DSS_ERROR + 1
DLL_PROBE_SIZE	EQU 256
BSS_END		EQU DLL_PROBE + DLL_PROBE_SIZE

STACK_BOTTOM	EQU BSS_END
STACK_TOP	EQU STACK_BOTTOM + 0x600

RECV_MAX_BLOCKS	EQU 4
UDP_MAX_TRIES	EQU 3			; 3 x 2000 ms before giving up
DUAL_MAX_ROUNDS	EQU 200			; bounds the -2 data drain loop
DUAL_MAX_IDLE	EQU 3			; 3 x 4 s without channel-1 data

	ASSERT STACK_TOP <= 0xC000

	ENDMODULE

	END MAIN.START
