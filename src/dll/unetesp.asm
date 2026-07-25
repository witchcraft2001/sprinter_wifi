; ======================================================
; UNETESP.DLL - universal network DLL, ESP8266 / ESP-AT backend.
; libman 1.3 / L1 relocatable library. Implements the frozen UNET
; contract in src/include/unet.inc on top of the Sprinter-WiFi ESP
; library modules (esplib / esp_tcp / esp_udp / isa / util).
;
; Build (see tools/build.sh):
;   sprinter-mkdll build src/dll/unetesp.asm --format l1 --target 1.3 \
;     --assembler sjasmplus -I src/include -I src/lib \
;     --name "UNET ESP" --version 0.1 -o build/UNETESP.DLL
;
; Layout notes:
; - Assembled at ORG 0 here; mkdll rewrites the ORG to 0x20/0x120 for the
;   two relocation passes (the 32-byte L1 header precedes the code image).
; - The first bytes of the code image are the 24-entry JP dispatch table.
; - All BSS (the WIFI.RS_BUFF chain + our staging buffers) lives INSIDE the
;   image as DS zero bytes: libman packs several DLLs into one 16 KB page,
;   so memory past the declared image length may belong to another library.
;   mkdll zero-RLE-compresses these runs; the loader zero-fills them on load.
; ======================================================

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"
	INCLUDE "macro.inc"
	INCLUDE "unet.inc"

DEFAULT_TIMEOUT		EQU 2000
RESOLVE_TIMEOUT		EQU 5000
BUSY_DELAY_MS		EQU 400
BUSY_MAX_RETRY		EQU 8
MAX_HOST_LEN		EQU 128	; host/port length caps keep the fixed-size AT
MAX_PORT_LEN		EQU 15	; command build buffers (CMDBUILD, TCP/UDP
				; CMD_BUFFER) from overflowing
UNETESP_CAPS		EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING | UNET_CAP_RXFLOW

	ORG 0x0000			; mkdll rewrites this to 0x20 / 0x120

	MODULE UNET

; ------------------------------------------------------
; libman jump/export table (function index * 3 + image base)
; ------------------------------------------------------
	JP	INIT			; 0  load hook
	JP	FINI			; 1  free hook
	JP	F_GETCAPS		; 2
	JP	F_NETINIT		; 3
	JP	F_NETDONE		; 4
	JP	F_CONNECT		; 5
	JP	F_SEND			; 6
	JP	F_RECV			; 7
	JP	F_CLOSE			; 8
	JP	F_STATUS		; 9
	JP	F_UDPOPEN		; 10
	JP	F_RESOLVE		; 11
	JP	F_PING			; 12
	JP	F_RXPAUSE		; 13
	JP	F_RXRESUME		; 14
	JP	F_GETINFO		; 15
	JP	F_LASTERR		; 16
	JP	F_SETOPT		; 17
	JP	F_NOTSUP		; 18 reserved
	JP	F_NOTSUP		; 19 reserved
	JP	F_NOTSUP		; 20 reserved
	JP	F_NOTSUP		; 21 reserved
	JP	F_NOTSUP		; 22 reserved
	JP	F_NOTSUP		; 23 reserved

; ======================================================
; Function 0 - INIT (libman load hook)
; libman propagates this function's CF as the load error. Determine which
; 16 KB window we were relocated into and refuse window 3 (0xC000): the ESP
; UART is memory-mapped there during every call and the code would swap
; itself out. On success clear CF / A=0.
; ======================================================
INIT
	CALL	.here
.here
	POP	HL			; HL = real runtime address of .here
	LD	A,H
	AND	0xC0
	LD	(WIN_BASE),A
	CP	0xC0
	JR	Z,.refuse
	XOR	A			; CF=0, A=0 : ok
	RET
.refuse
	LD	A,NERR_HW
	SCF
	RET

; ======================================================
; Function 1 - FINI (libman free hook): close any open link.
; ======================================================
FINI
	CALL	CLOSE_LINK
	XOR	A
	RET

; ======================================================
; Function 2 - GETCAPS
; ======================================================
F_GETCAPS
	LD	DE,UNETESP_CAPS
	LD	IX,UNET_ABI_VERSION
	XOR	A
	RET

; ======================================================
; Function 3 - NETINIT
; ======================================================
F_NETINIT
	XOR	A
	LD	(WCOMMON.CANCELLED),A
	; env: NET == "WIFI"
	LD	HL,ENVN_NET
	CALL	ENV_GET_STAGE
	JP	Z,.nonet
	LD	HL,ENV_STAGE
	LD	DE,VAL_WIFI
	CALL	STRMATCH
	JP	NZ,.nonet
	; env: NET_ESP_HW present and non-empty
	LD	HL,ENVN_ESP_HW
	CALL	ENV_GET_STAGE
	JP	Z,.nonet
	LD	A,(ENV_STAGE)
	AND	A
	JP	Z,.nonet
	; A universal DLL follows the profile already selected and published by
	; NETUP. Forced builds contain their fixed receive path and need no lookup.
	CALL	SELECT_ENV_RX_PROFILE
	JP	C,.nonet
	; locate UART
	CALL	WIFI.UART_FIND
	JP	C,.nohw
	; Reproduce the ESP UART flow mode negotiated by NETUP before initializing
	; the local 16550. Never issue AT+UART_CUR from a client DLL.
	CALL	SELECT_ENV_FLOW
	JP	C,.nonet
	; apply configured baud and init UART
	CALL	APPLY_ENV_BAUD
	CALL	WIFI.UART_INIT
	; A delayed terminal response from the previous client may precede the
	; answer to our first AT. Resynchronise without destroying NETUP's
	; deliberately session-only Wi-Fi configuration.
	CALL	SYNC_AT
	JP	C,.nohw
	LD	HL,CMD_ATE0
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT			; ignore
	; drop leftover sockets before CIPMUX (else ERROR)
	LD	HL,CMD_CIPCLOSE_ALL
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT
	LD	HL,CMD_CIPCLOSE_ONE
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT
	; the CIPCLOSE pair above really closed any leftover socket - forget
	; stale channel state so a repeated NETINIT + CONNECT works
	XOR	A
	LD	(CH_STATE),A
	; single-connection mode with busy retry
	LD	HL,CMD_CIPMUX0
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT_BUSY
	JP	C,.busy
	LD	A,1
	LD	(INITED),A
	XOR	A
	RET
.nonet	LD	A,NERR_NONET
	OR	A
	RET
.nohw	LD	A,NERR_HW
	OR	A
	RET
.busy	LD	A,NERR_BUSY
	OR	A
	RET

; ======================================================
; Function 4 - NETDONE / Function 8 - CLOSE (shared)
; ======================================================
F_CLOSE
	AND	A
	JP	NZ,RET_PARAM		; v1: only channel 0
F_NETDONE
	CALL	CLOSE_LINK
	XOR	A
	RET

; ======================================================
; Function 5 - CONNECT (TCP)
; ======================================================
F_CONNECT
	AND	A
	JP	NZ,RET_PARAM		; only channel 0
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	A,(CH_STATE)
	AND	A
	JP	NZ,RET_STATE		; already open
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,(ARG_IX)
	LD	DE,MAX_PORT_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	XOR	A
	LD	(OPEN_MODE),A		; TCP
	CALL	OPEN_RETRY
	JR	C,.fail
	LD	A,1
	LD	(CH_STATE),A
	XOR	A
	RET
.fail
	; Return status in A with CF=0 (the Pascal LibCall propagates the
	; callee carry, so every UNET function must leave CF clear).
	CALL	CONSUME_CANCEL
	JP	C,RET_CANCEL
	LD	HL,NEEDLE_DNS
	CALL	RESP_CONTAINS
	JR	C,.dns
	LD	A,NERR_CONNECT
	RET				; CF=0 (RESP_CONTAINS not-found path)
.dns
	LD	A,NERR_DNS
	OR	A			; clear CF
	RET

; ======================================================
; Function 6 - SEND (chunked at 2048 = ESP-AT CIPSEND cap)
; ======================================================
F_SEND
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,(CH_STATE)
	AND	A
	JP	Z,RET_STATE
	; UDP channel: one datagram per SEND, ESP-AT payload cap 1472 bytes
	CP	2
	JR	NZ,.lenok
	LD	HL,1472
	LD	DE,(ARG_IX)
	OR	A
	SBC	HL,DE			; CF=1 if length > 1472
	JP	C,RET_PARAM
.lenok
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	HL,0
	LD	(SEND_DONE),HL
.chunk
	; remaining = length - done
	LD	HL,(ARG_IX)
	LD	DE,(SEND_DONE)
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JR	Z,.complete
	; chunk = min(remaining, 2048)
	LD	DE,2048
	OR	A
	SBC	HL,DE			; CF=1 if remaining < 2048
	JR	C,.small
	LD	BC,2048
	JR	.have
.small
	ADD	HL,DE			; restore remaining
	LD	B,H
	LD	C,L
.have
	LD	(CHUNK_LEN),BC
	LD	HL,(ARG_DE)
	LD	DE,(SEND_DONE)
	ADD	HL,DE
	LD	BC,(CHUNK_LEN)
	CALL	TCP.SEND_BUFFER
	JR	C,.senderr
	LD	HL,(SEND_DONE)
	LD	BC,(CHUNK_LEN)
	ADD	HL,BC
	LD	(SEND_DONE),HL
	JR	.chunk
.complete
	LD	DE,(SEND_DONE)
	XOR	A
	RET
.senderr
	CALL	CONSUME_CANCEL
	LD	DE,(SEND_DONE)
	JR	C,.cancelled
	LD	A,NERR_SEND
	OR	A			; clear CF (reached via JR C from SEND_BUFFER)
	RET
.cancelled
	LD	A,NERR_CANCEL
	OR	A
	RET

; ======================================================
; Function 7 - RECV
; ======================================================
F_RECV
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,(CH_STATE)
	AND	A
	JP	Z,RET_STATE
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	; TCP.RECEIVE: HL=buf, BC=max, DE=timeout
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	LD	DE,(ARG_IY)
	CALL	TCP.RECEIVE
	JR	C,.err
	LD	(RECV_GOT),BC
	CALL	BUILD_RECV_FLAGS
	LD	DE,(RECV_GOT)
	XOR	A
	RET
.err
	CP	RES_RS_TIMEOUT
	JR	Z,.timeout
	CP	RES_NOT_CONN
	JR	Z,.closed
	CALL	CONSUME_CANCEL
	JR	C,.cancel
	LD	IX,0
	LD	DE,0
	LD	A,NERR_PROTO
	OR	A			; clear CF (non-matching CP above may set it)
	RET
.timeout
	LD	A,(WCOMMON.CANCELLED)
	AND	A
	JR	NZ,.cancel
	CALL	BUILD_RECV_FLAGS
	LD	DE,0
	XOR	A
	RET
.cancel
	XOR	A
	LD	(WCOMMON.CANCELLED),A
	LD	IX,0
	LD	DE,0
	LD	A,NERR_CANCEL
	RET
.closed
	XOR	A
	LD	(CH_STATE),A
	CALL	BUILD_RECV_FLAGS
	LD	DE,0
	LD	A,NERR_CLOSED
	RET

; Build IX = RECV status flags; reset the sticky overrun accumulator.
; bit1 more data pending (PAYLOAD_LEFT != 0), bit2 UART overrun (LSR OE).
BUILD_RECV_FLAGS
	LD	L,0
	LD	H,0
	LD	A,(TCP.PAYLOAD_LEFT)
	LD	B,A
	LD	A,(TCP.PAYLOAD_LEFT+1)
	OR	B
	JR	Z,.no_more
	SET	1,L
.no_more
	LD	A,(TCP.LSR_ACCUM)
	AND	LSR_OE
	JR	Z,.no_oe
	SET	2,L
.no_oe
	PUSH	HL
	POP	IX
	XOR	A
	LD	(TCP.LSR_ACCUM),A
	RET

; ======================================================
; Function 9 - STATUS
; ======================================================
F_STATUS
	CP	0xFF
	JR	Z,.netstat
	AND	A
	JP	NZ,RET_PARAM		; v1: only channel 0
	LD	A,(CH_STATE)
	AND	A
	JR	Z,.closed
	LD	DE,2
	XOR	A
	RET
.closed
	LD	DE,0
	XOR	A
	RET
.netstat
	LD	HL,ENVN_NET
	CALL	ENV_GET_STAGE
	JR	Z,.notup
	LD	HL,ENV_STAGE
	LD	DE,VAL_WIFI
	CALL	STRMATCH
	JR	NZ,.notup
	LD	HL,ENVN_ESP_HW
	CALL	ENV_GET_STAGE
	JR	Z,.notup
	LD	A,(ENV_STAGE)
	AND	A
	JR	Z,.notup
	LD	DE,1			; bit0 configured
	LD	A,(INITED)
	AND	A
	JR	Z,.cfg
	LD	DE,3			; bit0|bit1 (NETINIT done)
.cfg
	XOR	A
	RET
.notup
	LD	DE,0
	LD	A,NERR_NONET
	OR	A			; clear CF (STRMATCH may leave it set)
	RET

; ======================================================
; Function 10 - UDPOPEN
; ======================================================
F_UDPOPEN
	AND	A
	JP	NZ,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	A,(CH_STATE)
	AND	A
	JP	NZ,RET_STATE
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,(ARG_IX)
	LD	DE,MAX_PORT_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,(ARG_IY)
	LD	A,H
	OR	L
	JR	Z,.default_local
	LD	DE,MAX_PORT_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	A,2			; UDP, explicit local port
	JR	.open
.default_local
	LD	A,1			; UDP, default local port
.open
	LD	(OPEN_MODE),A
	CALL	OPEN_RETRY
	JR	C,.fail
	LD	A,2
	LD	(CH_STATE),A
	XOR	A
	RET
.fail
	CALL	CONSUME_CANCEL
	JP	C,RET_CANCEL
	LD	HL,NEEDLE_DNS
	CALL	RESP_CONTAINS
	JR	C,.dns
	LD	A,NERR_CONNECT
	RET				; CF=0
.dns
	LD	A,NERR_DNS
	OR	A			; clear CF
	RET

; ======================================================
; Function 11 - RESOLVE (AT+CIPDOMAIN; degrades to NERR_NOTSUP)
; ======================================================
F_RESOLVE
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	A,(RESOLVE_SUP)
	CP	2
	JP	Z,RET_NOTSUP
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,(ARG_IX)
	LD	BC,16			; dest is a >=16-byte buffer
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	HL,CMDBUILD
	LD	DE,PFX_CIPDOMAIN
	CALL	APPEND_DE
	LD	DE,(ARG_DE)
	CALL	APPEND_DE
	LD	DE,SFX_QUOTE_CRLF
	CALL	APPEND_DE
	LD	HL,CMDBUILD
	LD	BC,RESOLVE_TIMEOUT
	CALL	SEND_AT_BUSY
	JR	C,.fail
	CALL	PARSE_CIPDOMAIN		; HL -> ip start, CF=1 if not found
	JR	C,.badparse
	LD	DE,(ARG_IX)
	LD	BC,16
	CALL	COPY_LIMITED_STOP
	LD	A,1
	LD	(RESOLVE_SUP),A
	XOR	A
	RET
.fail
	CALL	CONSUME_CANCEL
	JP	C,RET_CANCEL
	LD	HL,NEEDLE_CIPDOMAIN
	CALL	RESP_CONTAINS
	JR	C,.dns			; marker present but failed -> DNS failure
	LD	HL,NEEDLE_DNS
	CALL	RESP_CONTAINS
	JR	C,.dns
	CALL	RESP_IS_TIMEOUT
	JR	C,.timeout
	LD	A,2
	LD	(RESOLVE_SUP),A		; plain ERROR: firmware lacks CIPDOMAIN
	JP	RET_NOTSUP
.badparse
	LD	A,NERR_DNS
	OR	A			; clear CF (reached via JR C)
	RET
.dns
	LD	A,NERR_DNS
	OR	A
	RET
.timeout
	LD	A,NERR_TIMEOUT
	OR	A
	RET

; ======================================================
; Function 12 - PING (AT+PING)
; ======================================================
F_PING
	LD	(ARG_DE),DE
	LD	(ARG_IY),IY
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	HL,(ARG_DE)
	LD	DE,MAX_HOST_LEN
	CALL	CHECK_STRARG
	JP	C,RET_PARAM
	LD	HL,CMDBUILD
	LD	DE,PFX_PING
	CALL	APPEND_DE
	LD	DE,(ARG_DE)
	CALL	APPEND_DE
	LD	DE,SFX_QUOTE_CRLF
	CALL	APPEND_DE
	LD	HL,CMDBUILD
	LD	BC,(ARG_IY)
	CALL	SEND_AT_BUSY
	JR	C,.fail
	CALL	PARSE_PING_MS		; CF=0/DE=ms, CF=1 if none
	JR	C,.timeout
	XOR	A
	RET
.fail
	CALL	CONSUME_CANCEL
	JP	C,RET_CANCEL
	CALL	RESP_IS_TIMEOUT
	JR	C,.timeout
	LD	A,NERR_PROTO
	RET
.timeout
	LD	A,NERR_TIMEOUT
	OR	A			; clear CF (reached via JR C)
	RET

; ======================================================
; Function 13 / 14 - RXPAUSE / RXRESUME
; ======================================================
; Both require NETINIT first: before UART_FIND runs, the ISA slot/base is not
; established and a UART register write could poke a different card in slot 0.
F_RXPAUSE
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	LD	A,1
	LD	(RX_PAUSED),A
	CALL	WIFI.UART_RX_PAUSE
	XOR	A
	RET
F_RXRESUME
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	XOR	A
	LD	(RX_PAUSED),A
	CALL	WIFI.UART_RX_RESUME
	XOR	A
	RET

; ======================================================
; Function 15 - GETINFO
; ======================================================
F_GETINFO
	LD	(ARG_A),A
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	HL,(ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM		; max=0 has no room even for the NUL
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(ARG_A)
	CP	UNET_IF_BACKEND
	JR	Z,.backend
	CP	INFO_FIELD_COUNT
	JR	NC,.empty
	; index env-name table with (field - 1)
	LD	L,A
	LD	H,0
	DEC	HL
	ADD	HL,HL
	LD	DE,INFO_NAME_TABLE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL			; HL = env name
	CALL	ENV_GET_STAGE
	LD	HL,ENV_STAGE
	JR	.copyout
.backend
	LD	HL,LIT_ESP
	JR	.copyout
.empty
	LD	HL,LIT_EMPTY
.copyout
	LD	DE,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	COPY_LIMITED
	XOR	A
	RET

; ======================================================
; Function 16 - LASTERR (tail of last AT/driver response)
; ======================================================
F_LASTERR
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	HL,(ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	; copy the TAIL of the response: the final ERROR/CLOSED line is the
	; useful diagnostic when the response is longer than the caller buffer
	LD	HL,WIFI.RS_BUFF
	LD	BC,0
	LD	DE,RS_BUFF_SIZE		; global EQU; hard stop if unterminated
.len
	LD	A,(HL)
	AND	A
	JR	Z,.gotlen
	INC	HL
	INC	BC
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.len
.gotlen
	LD	H,B
	LD	L,C			; HL = response length
	LD	DE,(ARG_IX)
	DEC	DE			; DE = capacity (max-1)
	OR	A
	SBC	HL,DE			; HL = length - capacity
	JR	C,.head
	JR	Z,.head
	LD	DE,WIFI.RS_BUFF
	ADD	HL,DE			; skip to the last <capacity> bytes
	JR	.copy
.head
	LD	HL,WIFI.RS_BUFF
.copy
	LD	DE,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	COPY_LIMITED
	XOR	A
	RET

; ======================================================
; Function 17 - SETOPT
; ======================================================
F_SETOPT
	CP	UNET_OPT_CANCELKEYS
	JR	Z,.cancelkeys
	CP	UNET_OPT_RXTRIG
	JR	Z,.rxtrig
	JP	RET_PARAM
.cancelkeys
	LD	A,E
	OR	D
	JR	Z,.ck_off
	LD	A,1
	LD	(CANCEL_MODE),A
	XOR	A
	RET
.ck_off
	XOR	A
	LD	(CANCEL_MODE),A
	RET
.rxtrig
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE		; UART base unknown before NETINIT
	LD	A,E
	CP	1
	JR	Z,.tr1
	CP	4
	JR	Z,.tr4
	CP	8
	JR	Z,.tr8
	CP	14
	JR	Z,.tr14
	JP	RET_PARAM
.tr1	LD	E,FCR_TR1 | FCR_FIFO
	JR	.setfcr
.tr4	LD	E,FCR_TR4 | FCR_FIFO
	JR	.setfcr
.tr8	LD	E,FCR_TR8 | FCR_FIFO
	JR	.setfcr
.tr14	LD	E,FCR_TR14 | FCR_FIFO
.setfcr
	LD	HL,REG_FCR
	CALL	WIFI.UART_WRITE
	XOR	A
	RET

; ======================================================
; Reserved slots 18..23
; ======================================================
F_NOTSUP
	LD	A,NERR_NOTSUP
	OR	A
	RET

; ======================================================
; Shared error exits. Reached via JP C / JP Z, so clear CF explicitly:
; every UNET function must return status in A with CF=0.
; ======================================================
RET_PARAM
	LD	A,NERR_PARAM
	OR	A
	RET
RET_STATE
	LD	A,NERR_STATE
	OR	A
	RET
RET_NOTSUP
	LD	A,NERR_NOTSUP
	OR	A
	RET
RET_CANCEL
	LD	A,NERR_CANCEL
	OR	A
	RET

; ======================================================
; Helpers
; ======================================================

; Close the active link if any; leave the network up.
CLOSE_LINK
	LD	A,(CH_STATE)
	AND	A
	RET	Z
	CALL	TCP.CLOSE		; UDP.CLOSE routes here too
	XOR	A
	LD	(CH_STATE),A
	RET

; Open the link, retrying while the ESP answers "busy" (its IP stack may
; still be warming up right after NETUP - the first network command is the
; one that hits it; see ping.asm). OPEN_MODE selects the variant:
; 0 = TCP, 1 = UDP default local port, 2 = UDP explicit local port.
; Args are read from ARG_DE/ARG_IX/ARG_IY.
; Out: CF=0 ok, CF=1 / A = last ESP result code.
OPEN_RETRY
	LD	A,BUSY_MAX_RETRY
	LD	(BUSY_RETRY),A
.try
	LD	A,(OPEN_MODE)
	LD	HL,(ARG_DE)		; host
	LD	DE,(ARG_IX)		; port / remote port
	AND	A
	JR	Z,.tcp
	CP	2
	JR	Z,.udplocal
	CALL	UDP.OPEN
	JR	.res
.udplocal
	LD	IX,(ARG_IY)		; local port
	CALL	UDP.OPEN_LOCAL
	JR	.res
.tcp
	CALL	TCP.OPEN
.res
	RET	NC
	LD	(BUSY_LAST),A
	LD	A,(WCOMMON.CANCELLED)
	AND	A
	JR	NZ,.giveup		; user cancel: do not spin on retries
	LD	HL,NEEDLE_BUSY
	CALL	RESP_CONTAINS
	JR	NC,.giveup		; not busy -> real error
	LD	A,(BUSY_RETRY)
	AND	A
	JR	Z,.giveup
	DEC	A
	LD	(BUSY_RETRY),A
	LD	HL,BUSY_DELAY_MS
	CALL	UTIL.DELAY
	JR	.try
.giveup
	LD	A,(BUSY_LAST)
	SCF
	RET

; Consume a latched user-cancel flag. Out: CF=1 if it was set (now cleared).
CONSUME_CANCEL
	LD	A,(WCOMMON.CANCELLED)
	AND	A
	RET	Z			; CF=0
	XOR	A
	LD	(WCOMMON.CANCELLED),A
	SCF
	RET

; Validate a caller buffer pointer in HL.
; Reject window 0 (system), window 3 (ISA) and the DLL's own window.
; Out: CF=1 if invalid, CF=0 if usable.
CHECK_BUF
	LD	A,H
	AND	0xC0
	JR	Z,.bad			; window 0
	CP	0xC0
	JR	Z,.bad			; window 3 (ISA)
	LD	B,A
	LD	A,(WIN_BASE)
	CP	B
	JR	Z,.bad			; DLL's own window
	OR	A			; CF=0
	RET
.bad
	SCF
	RET

; Validate a caller buffer range [HL, HL+BC-1]: both ends must sit in a
; usable window (a buffer starting below 0xC000 must not extend into the
; ISA window or into the DLL's own window). BC=0 checks the start only.
; Out: CF=1 if invalid. Trashes A,B,C,HL.
CHECK_BUF_RANGE
	CALL	CHECK_BUF
	RET	C
	LD	A,B
	OR	C
	RET	Z			; empty range: CF=0 from OR
	DEC	BC
	ADD	HL,BC
	RET	C			; wraps past 0xFFFF
	JP	CHECK_BUF

; Validate an ASCIIZ string argument: start and terminator both in a usable
; window, and no longer than DE bytes (protects the fixed-size AT command
; build buffers). In: HL=string, DE=max length. Out: CF=1 if invalid.
; Preserves HL. Trashes A,B,DE.
CHECK_STRARG
	CALL	CHECK_BUF
	RET	C
	PUSH	HL
	INC	DE			; NUL must appear within max+1 bytes
.scan
	LD	A,(HL)
	AND	A
	JR	Z,.ends
	INC	HL
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.scan
	POP	HL
	SCF				; too long
	RET
.ends
	CALL	CHECK_BUF		; terminator still in a valid window
	POP	HL
	RET

; Send one AT command. In: HL=cmd ASCIIZ, BC=timeout ms.
; Out: A=RES_* (0 ok), CF=1 if A!=0.
SEND_AT
	LD	DE,WIFI.RS_BUFF
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	SCF
	RET

; Probe command mode several times. The first reply may be a delayed
; ERROR/CLOSED from a command issued by the previous process.
; Out: CF=0 - ESP answered OK, CF=1 - no usable response.
SYNC_AT
	LD	B,4
.try
	PUSH	BC
	LD	HL,CMD_AT
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT
	POP	BC
	RET	NC
	DJNZ	.try
	SCF
	RET

; Send one AT command, retrying while the ESP answers "busy".
; In: HL=cmd ASCIIZ, BC=timeout ms. Out: A=0/CF=0 ok, else CF=1/A=last code.
SEND_AT_BUSY
	LD	A,BUSY_MAX_RETRY
	LD	(BUSY_RETRY),A
.try
	LD	DE,WIFI.RS_BUFF
	CALL	WIFI.UART_TX_CMD	; preserves HL,BC
	LD	(BUSY_LAST),A
	AND	A
	JR	Z,.ok
	PUSH	HL
	PUSH	BC
	LD	HL,NEEDLE_BUSY
	CALL	RESP_CONTAINS
	POP	BC
	POP	HL
	JR	NC,.fail		; not busy -> real error
	LD	A,(BUSY_RETRY)
	AND	A
	JR	Z,.fail
	DEC	A
	LD	(BUSY_RETRY),A
	PUSH	HL
	PUSH	BC
	LD	HL,BUSY_DELAY_MS
	CALL	UTIL.DELAY
	POP	BC
	POP	HL
	JR	.try
.ok
	XOR	A
	RET
.fail
	LD	A,(BUSY_LAST)
	SCF
	RET

; Read env var (HL=name) into ENV_STAGE. Out: ZF=1 if unset (A=0).
ENV_GET_STAGE
	PUSH	HL
	XOR	A
	LD	(ENV_STAGE),A
	POP	HL
	LD	DE,ENV_STAGE
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	AND	A
	RET

; Select the shared esplib receive/RTS path from NET_ESP_FW. Out: CF=1 when
; NETUP did not publish one of the two supported profiles.
SELECT_ENV_RX_PROFILE
	IFDEF	ESP_AT_FORCE_221
	OR	A
	RET
	ELSE
	IFDEF	ESP_AT_FORCE_222
	OR	A
	RET
	ELSE
	LD	HL,ENVN_ESP_FW
	CALL	ENV_GET_STAGE
	JR	Z,.bad
	LD	HL,ENV_STAGE
	LD	DE,VAL_ESP_FW_221
	CALL	STRMATCH
	JR	Z,.fw221
	LD	HL,ENV_STAGE
	LD	DE,VAL_ESP_FW_222
	CALL	STRMATCH
	JR	NZ,.bad
	LD	A,2
	JR	.short
.fw221
	LD	A,1
.short
	CALL	WIFI.UART_SET_RX_PROFILE
	OR	A
	RET
.bad
	SCF
	RET
	ENDIF
	ENDIF

; Select the local MCR mode from NET_ESP_FLOW published by NETUP.
; Out: CF=1 when the value is absent/invalid.
SELECT_ENV_FLOW
	LD	HL,ENVN_ESP_FLOW
	CALL	ENV_GET_STAGE
	JR	Z,.bad
	LD	A,(ENV_STAGE)
	CP	'3'
	JR	Z,.flow3
	CP	'0'
	JR	NZ,.bad
	CALL	WIFI.UART_FLOW_OFF
	OR	A
	RET
.flow3
	CALL	WIFI.UART_FLOW_ON
	OR	A
	RET
.bad
	SCF
	RET

; Read NET_BAUD and program the local UART divisor (default 8 = 115200).
APPLY_ENV_BAUD
	LD	HL,ENVN_BAUD
	CALL	ENV_GET_STAGE
	JR	Z,.default
	LD	HL,ENV_STAGE
	LD	DE,BAUD_230400
	CALL	STRMATCH
	LD	A,4
	JR	Z,.set
	LD	HL,ENV_STAGE
	LD	DE,BAUD_57600
	CALL	STRMATCH
	LD	A,16
	JR	Z,.set
	LD	HL,ENV_STAGE
	LD	DE,BAUD_38400
	CALL	STRMATCH
	LD	A,24
	JR	Z,.set
	LD	HL,ENV_STAGE
	LD	DE,BAUD_19200
	CALL	STRMATCH
	LD	A,48
	JR	Z,.set
	LD	HL,ENV_STAGE
	LD	DE,BAUD_9600
	CALL	STRMATCH
	LD	A,96
	JR	Z,.set
.default
	LD	A,8
.set
	CALL	WIFI.UART_SET_DIVISOR
	RET

; Compare ASCIIZ (HL) and (DE). Out: ZF=1 if equal. Preserves HL,DE.
STRMATCH
	PUSH	HL
	PUSH	DE
.next
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	CP	C
	JR	NZ,.ne
	OR	A
	JR	Z,.eq
	INC	HL
	INC	DE
	JR	.next
.ne
	POP	DE
	POP	HL
	RET				; ZF=0
.eq
	POP	DE
	POP	HL
	RET				; ZF=1

; Append ASCIIZ (DE) to buffer (HL). Out: HL at terminator.
APPEND_DE
	LD	A,(DE)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	APPEND_DE

; Copy ASCIIZ (HL) to (DE), at most BC-1 bytes, NUL-terminated.
; BC=0 copies nothing (no room even for the terminator).
COPY_LIMITED
	LD	A,B
	OR	C
	RET	Z
	DEC	BC
.loop
	LD	A,B
	OR	C
	JR	Z,.term
	LD	A,(HL)
	AND	A
	JR	Z,.term
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	BC
	JR	.loop
.term
	XOR	A
	LD	(DE),A
	RET

; Copy (HL) to (DE), at most BC-1 bytes, stop at NUL/CR/LF/quote, NUL-terminate.
; BC=0 copies nothing.
COPY_LIMITED_STOP
	LD	A,B
	OR	C
	RET	Z
	DEC	BC
.loop
	LD	A,B
	OR	C
	JR	Z,.term
	LD	A,(HL)
	AND	A
	JR	Z,.term
	CP	13
	JR	Z,.term
	CP	10
	JR	Z,.term
	CP	34
	JR	Z,.term
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	BC
	JR	.loop
.term
	XOR	A
	LD	(DE),A
	RET

; Scan WIFI.RS_BUFF for ASCIIZ needle (HL). Out: CF=1 if found. Trashes A,B,DE,HL.
RESP_CONTAINS
	PUSH	HL
	LD	DE,WIFI.RS_BUFF
.scan
	LD	A,(DE)
	AND	A
	JR	Z,.no
	POP	HL
	PUSH	HL
	PUSH	DE
.cmp
	LD	A,(HL)
	AND	A
	JR	Z,.yes
	LD	B,A
	LD	A,(DE)
	CP	B
	JR	NZ,.nextpos
	INC	HL
	INC	DE
	JR	.cmp
.nextpos
	POP	DE
	INC	DE
	JR	.scan
.yes
	POP	DE
	POP	HL
	SCF
	RET
.no
	POP	HL
	OR	A
	RET

; RES_RS_TIMEOUT, or RS_BUFF contains "timeout". Out: CF=1 if a timeout.
RESP_IS_TIMEOUT
	LD	A,(BUSY_LAST)
	CP	RES_RS_TIMEOUT
	JR	Z,.yes
	LD	HL,NEEDLE_TIMEOUT
	JP	RESP_CONTAINS
.yes
	SCF
	RET

; Parse "+PING:<ms>" or "+<ms>" from RS_BUFF. Out: CF=0/DE=ms, CF=1 if none.
PARSE_PING_MS
	LD	HL,WIFI.RS_BUFF
.next
	LD	A,(HL)
	AND	A
	JR	Z,.none
	LD	DE,NEEDLE_PING
	CALL	UTIL.STARTSWITH		; ZF=1 if line starts with "+PING:"
	JR	Z,.found_ping
	LD	A,(HL)
	CP	'+'
	JR	Z,.found_short
	CALL	SKIP_LINE
	JR	.next
.found_ping
	LD	BC,6
	ADD	HL,BC
	JR	.decimal
.found_short
	INC	HL
.decimal
	CALL	SKIP_SPACES
	LD	A,(HL)
	CP	'0'
	JR	C,.none
	CP	'9'+1
	JR	NC,.none
	EX	DE,HL
	CALL	UTIL.ATOU		; DE=ptr -> HL=number
	EX	DE,HL			; DE=number
	AND	A			; CF=0
	RET
.none
	SCF
	RET

; Parse "+CIPDOMAIN:" line. Out: HL -> ip start, CF=1 if not found.
PARSE_CIPDOMAIN
	LD	HL,WIFI.RS_BUFF
.next
	LD	A,(HL)
	AND	A
	JR	Z,.none
	LD	DE,NEEDLE_CIPDOMAIN
	CALL	UTIL.STARTSWITH
	JR	Z,.found
	CALL	SKIP_LINE
	JR	.next
.found
	LD	BC,11			; length of "+CIPDOMAIN:"
	ADD	HL,BC
	LD	A,(HL)
	CP	34
	JR	NZ,.ok
	INC	HL
.ok
	AND	A
	RET
.none
	SCF
	RET

; Skip to just past the next LF (or to end of string).
SKIP_LINE
	LD	A,(HL)
	AND	A
	RET	Z
	INC	HL
	CP	10
	RET	Z
	JR	SKIP_LINE

; Skip spaces / tabs. Out: HL at first non-blank.
SKIP_SPACES
	LD	A,(HL)
	CP	' '
	JR	Z,.adv
	CP	9
	RET	NZ
.adv
	INC	HL
	JR	SKIP_SPACES

; ======================================================
; AT command / literal strings
; ======================================================
CMD_AT			DB "AT",13,10,0
CMD_ATE0		DB "ATE0",13,10,0
CMD_CIPMUX0		DB "AT+CIPMUX=0",13,10,0
CMD_CIPCLOSE_ALL	DB "AT+CIPCLOSE=5",13,10,0
CMD_CIPCLOSE_ONE	DB "AT+CIPCLOSE",13,10,0
PFX_PING		DB "AT+PING=",34,0
PFX_CIPDOMAIN		DB "AT+CIPDOMAIN=",34,0
SFX_QUOTE_CRLF		DB 34,13,10,0
BAUD_230400		DB "230400",0
BAUD_57600		DB "57600",0
BAUD_38400		DB "38400",0
BAUD_19200		DB "19200",0
BAUD_9600		DB "9600",0

NEEDLE_BUSY		DB "busy",0
NEEDLE_DNS		DB "DNS",0
NEEDLE_TIMEOUT		DB "timeout",0
NEEDLE_PING		DB "+PING:",0
NEEDLE_CIPDOMAIN	DB "+CIPDOMAIN:",0

ENVN_NET		DB "NET",0
ENVN_ESP_HW		DB "NET_ESP_HW",0
ENVN_ESP_FW		DB "NET_ESP_FW",0
ENVN_ESP_FLOW	DB "NET_ESP_FLOW",0
ENVN_BAUD		DB "NET_BAUD",0
VAL_WIFI		DB "WIFI",0
VAL_ESP_FW_221	DB "2.2.1",0
VAL_ESP_FW_222	DB "2.2.2",0
LIT_ESP			DB "ESP",0
LIT_EMPTY		DB 0

; GETINFO env-name table for fields 1..12 (field 0 = backend literal).
INFO_NAME_TABLE
	DW ENVN_IP, ENVN_MASK, ENVN_GW, ENVN_MAC, ENVN_DNS1, ENVN_DNS2
	DW ENVN_IPSRC, ENVN_SSID, ENVN_BAUD, ENVN_NTP, ENVN_TZ, ENVN_ESP_HW
INFO_FIELD_COUNT	EQU 13

ENVN_IP			DB "NET_IP",0
ENVN_MASK		DB "NET_MASK",0
ENVN_GW			DB "NET_GW",0
ENVN_MAC		DB "NET_MAC",0
ENVN_DNS1		DB "NET_DNS1",0
ENVN_DNS2		DB "NET_DNS2",0
ENVN_IPSRC		DB "NET_IP_SRC",0
ENVN_SSID		DB "NET_SSID",0
ENVN_NTP		DB "NET_NTP",0
ENVN_TZ			DB "NET_TZ",0

; ======================================================
; State (small initialised data, reset to these values on every load)
; ======================================================
WIN_BASE		DB 0	; high byte (top 2 bits) of our window base
INITED			DB 0	; NETINIT completed
CH_STATE		DB 0	; 0 closed, 1 TCP open, 2 UDP open
CANCEL_MODE		DB 0	; SETOPT CANCELKEYS
RX_PAUSED		DB 0	; consumer requested RX pause
RESOLVE_SUP		DB 0	; 0 unknown, 1 supported, 2 unsupported
OPEN_MODE		DB 0	; OPEN_RETRY variant: 0 TCP, 1 UDP, 2 UDP+lport
BUSY_RETRY		DB 0
BUSY_LAST		DB 0
ARG_A			DB 0
ARG_DE			DW 0
ARG_IX			DW 0
ARG_IY			DW 0
SEND_DONE		DW 0
CHUNK_LEN		DW 0
RECV_GOT		DW 0
	ENDMODULE

; ======================================================
; Minimal WCOMMON stub. The reused library modules reference
; @WCOMMON.CHECK_CANCEL_IN_ISA and @WCOMMON.LINE_END; we must NOT pull in the
; full wcommon.asm (it drags in NETCFG and hard-exits the process). Cancel
; polling is off unless the consumer enables it via SETOPT CANCELKEYS.
; ======================================================
	MODULE WCOMMON

CHECK_CANCEL_IN_ISA
	PUSH	AF
	LD	A,(UNET.CANCEL_MODE)
	AND	A
	JR	NZ,.enabled
	POP	AF
	AND	A			; CF=0 no cancel
	RET
.enabled
	POP	AF
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	CALL	@ISA.ISA_CLOSE
	LD	C,DSS_SCANKEY
	RST	DSS
	JR	Z,.nokey
	LD	A,E
	CP	0x1B
	JR	Z,.cancel
	CP	0x07
	JR	Z,.cancel
	CP	0x1A
	JR	NZ,.nokey
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.nokey
.cancel
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	SCF
	RET
.nokey
	CALL	@ISA.ISA_OPEN
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	AND	A
	RET

CANCELLED	DB 0
LINE_END	DB 13,10,0

	ENDMODULE

; ======================================================
; Reused Sprinter-WiFi library modules. Order matters: esp_tcp / esp_udp
; before esplib so the BSS chain anchors on WIFI.RS_BUFF (the final label).
; ======================================================
	INCLUDE "util.asm"
	INCLUDE "isa.asm"
	INCLUDE "esp_tcp.asm"
	INCLUDE "esp_udp.asm"
	INCLUDE "esplib.asm"

; ======================================================
; In-image BSS. Reserve the whole RS_BUFF chain plus our staging buffers as
; zero bytes so they live inside the declared 16 KB image (see header note).
; ======================================================
	MODULE UNET

ENV_STAGE	EQU UDP.UDP_BSS_END
ENV_STAGE_SIZE	EQU 192	; DSS ENV_GET has no length cap; headroom for long values
CMDBUILD	EQU ENV_STAGE + ENV_STAGE_SIZE
CMDBUILD_SIZE	EQU 160
DLL_BSS_END	EQU CMDBUILD + CMDBUILD_SIZE

	ENDMODULE

	DS UNET.DLL_BSS_END - $, 0	; reserve BSS as in-image zeros
	DB 0x55				; canary: keep the BSS region in the raw image
	ASSERT $ <= 0x4000		; image (incl. header at load) fits one 16 KB window
