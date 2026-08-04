; ======================================================
; UNETESP.DLL - ESP-AT 2.2.2 network DLL, ESP8266 backend.
; libman 1.3 / L1 relocatable library. Implements the frozen UNET
; contract in src/include/unet.inc on top of the Sprinter-WiFi ESP
; library modules (esplib / esp_tcp / esp_udp / isa / util).
;
; FIRMWARE PROFILE: this DLL is deliberately limited to ESP-AT 2.2.2 and its
; complete trigger-4 receive path. The DEFINE below pins that at assembly time -
; the DLL contains only the 2.2.2 command set and TR4 receive, with no runtime
; 2.2.1 fallback. NETINIT refuses
; a session that NETUP did not bring up as NET_ESP_FW=2.2.2 (see
; SELECT_ENV_RX_PROFILE), so it fails loudly instead of driving 2.2.1 firmware
; with the wrong command set. The L1 header name announces the target and full
; package version (for example, "UNETESP v0.2.1") to consumers such as
; UNETTEST.
;
; Build (see tools/build.sh):
;   sprinter-mkdll build src/dll/unetesp.asm --format l1 --target 1.3 \
;     --assembler sjasmplus -I src/include -I src/lib \
;     --name "UNETESP v0.2.1" --version 0.2 --no-compress \
;     -o build/UNETESP.DLL
;
; The L1 header has a compact, encoded major.minor version plus a 15-byte
; human-readable name field. tools/build.sh puts the full package version into
; that field as `UNETESP v<version>`, so consumers can identify the exact DLL
; revision without decoding the numeric header.
;
; Layout notes:
; - Assembled at ORG 0 here; mkdll rewrites the ORG to 0x20/0x120 for the
;   two relocation passes (the 32-byte L1 header precedes the code image).
; - The first bytes of the code image are the 24-entry JP dispatch table.
; - All BSS (the WIFI.RS_BUFF chain + our staging buffers) lives INSIDE the
;   image as DS zero bytes: libman packs several DLLs into one 16 KB page,
;   so memory past the declared image length may belong to another library.
; - The shipped image is deliberately uncompressed. This keeps the on-target
;   libman 1.3 path deterministic while the DLL remains comfortably below its
;   16 KB image/input-page limit.
; ======================================================

; 2.2.2-only, trigger-4 receive. Must precede the esplib include at the end of
; this file (that is where the DEFINE takes effect).
	DEFINE	ESP_AT_FORCE_222
; Capture peer +IPD data that races a SEND (arrives in the CIPSEND '>' / SEND OK
; window) into a 2 KB defer buffer and replay it to the next RECV, instead of
; discarding it. Closes the full-duplex race in docs/UNETAPI.md; grows the image
; by ~2 KB (still well under the 16 KB ceiling). Only the DLL enables this — the
; stock apps build without it and stay byte-identical. See esp_tcp.asm.
	DEFINE	ESP_TCP_RX_DEFER
; Two simultaneous channels (AT+CIPMUX=1): channel 0 and channel 1 can each hold
; a TCP or UDP link, which is what a passive-FTP client needs (control on one,
; data on the other). Adds a second receive-defer stash so a frame for the
; channel not being read is buffered for it instead of lost. See esp_tcp.asm.
	DEFINE	ESP_TCP_MUX

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
UNETESP_CAPS		EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING | UNET_CAP_RXFLOW | UNET_CAP_MULTICHAN | UNET_CAP_ASYNCSEND
UNET_CHANNELS		EQU 2	; channels this build accepts; checked against
				; TCP_MUX_CHANNELS after the library include

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
; Function 1 - FINI (libman free hook): close any open link and hand the ESP
; back in single-connection mode, so a consumer that frees the DLL without
; calling NETDONE does not leave the session in a state the stock utilities do
; not expect. Both steps no-op when NETINIT never succeeded.
; ======================================================
FINI
	; FINI is the one teardown path allowed to undo a consumer pause: once the
	; DLL page is freed nobody can call RXRESUME, while closing links with RTS
	; deasserted can wedge the ESP on its first reply.
	LD	A,(INITED)
	AND	A
	JR	Z,.done
	XOR	A
	LD	(RX_PAUSED),A
	CALL	WIFI.UART_RX_RESUME
.done
	CALL	F_NETDONE
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
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	RESOLVE_PENDING		; do not interleave setup with a pending send
	JP	C,RET_BUSY
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
	XOR	A
	LD	(RX_PAUSED),A		; UART_INIT leaves RTS in receive-ready state
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
	CALL	RESET_CHANNEL_STATE
	; multi-connection mode with busy retry. It must follow the CIPCLOSE pair:
	; ESP-AT rejects AT+CIPMUX while any link is still open.
	LD	HL,CMD_CIPMUX1
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT_BUSY
	JP	C,.busy
	LD	A,1
	LD	(MUX_ACTIVE),A
	; Bound the firmware's internal TCP send. ESP-AT (verified in the
	; v2.2.2.0_esp8266 core, at_sending_data) holds s_at_socket_mutex across
	; a blocking lwip_send with NO timeout by default, and +IPD printing
	; (at_process_recv_socket) needs the same mutex: one stuck send silences
	; the whole UART for as long as Wi-Fi retransmissions take. so_sndtimeo
	; caps that at 4 s - the module then answers "SEND FAIL" on its own,
	; before our 5 s client timeout. Link id 5 = every connection.
	; Best effort: an ERROR here only means the old unbounded behaviour.
	LD	HL,CMD_CIPTCPOPT
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT_BUSY
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
; Function 8 - CLOSE (one channel)
; ======================================================
F_CLOSE
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	RESOLVE_PENDING		; no AT text may interleave a suspended send
	JP	C,RET_BUSY
	CALL	CLOSE_CHANNEL
	RET

; ======================================================
; Function 4 - NETDONE: close every channel and hand the ESP back in the
; single-connection mode the stock utilities expect. The network itself
; (Wi-Fi join, UART settings) stays up, so a later CONNECT still works: it
; re-arms multi-connection mode through ENSURE_MUX.
; ======================================================
F_NETDONE
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	RESOLVE_PENDING		; no AT text may interleave a suspended send
	JP	C,RET_BUSY
	CALL	CLOSE_LINK
	AND	A
	RET	NZ			; do not inject CIPMUX while a close is unresolved
	LD	A,(MUX_ACTIVE)
	AND	A
	JR	Z,.done
	LD	HL,CMD_CIPMUX0
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT_BUSY		; best effort; state is cleared either way
	XOR	A
	LD	(MUX_ACTIVE),A
.done
	XOR	A
	RET

; ======================================================
; Function 5 - CONNECT (TCP)
; ======================================================
F_CONNECT
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	GET_CH_STATE
	AND	A
	JP	NZ,RET_STATE		; this channel is already open
	CALL	RESOLVE_PENDING		; no AT text may interleave a suspended send
	JP	C,RET_BUSY
	CALL	ENSURE_MUX
	JP	C,RET_BUSY
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
	CALL	SET_CH_STATE
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
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	CALL	GET_CH_STATE
	AND	A
	JP	Z,RET_STATE
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	CH_PEER_CLOSED		; sending on a closed link cannot succeed
	JP	C,.closed_entry
	LD	A,(ARG_CH)
	LD	(TCP.LINK_ID),A		; the send routines address the link through it
	CALL	SETUP_ASYNC_MODE	; arm/disarm suspendable mode from OPT_SLICE
	; A suspended transaction resumes here; a fresh call while one is pending
	; on the OTHER channel must not interleave AT text with it.
	LD	A,(PEND_CH)
	CP	0xFF
	JR	Z,.fresh
	LD	B,A
	LD	A,(ARG_CH)
	CP	B
	JP	NZ,RET_STATE
	; The resume contract requires identical arguments.
	LD	HL,(ARG_DE)
	LD	DE,(PEND_BUF)
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,RET_STATE
	LD	HL,(ARG_IX)
	LD	DE,(PEND_LEN)
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,RET_STATE
	CALL	TCP.SEND_BUFFER_RESUME
	JP	C,.senderr
	JP	.chunk_done
.fresh
	CALL	GET_CH_STATE
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
	LD	A,1
	LD	(SEND_TRY),A		; one ladder reissue per call
	LD	HL,0
	LD	(SEND_DONE),HL
	LD	HL,(ARG_DE)
	LD	(PEND_BUF),HL		; resume-contract reference
	LD	HL,(ARG_IX)
	LD	(PEND_LEN),HL
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
.chunk_done
	LD	HL,(SEND_DONE)
	LD	BC,(CHUNK_LEN)
	ADD	HL,BC
	LD	(SEND_DONE),HL
	JR	.chunk
.complete
	CALL	CLEAR_PEND
	LD	DE,(SEND_DONE)
	XOR	A
	RET
.senderr
	; A suspension is not an error: park the transaction and hand control
	; back; the consumer repeats the call to continue it.
	CP	RES_AGAIN
	JR	NZ,.realerr
	LD	A,(ARG_CH)
	LD	(PEND_CH),A
	LD	DE,(SEND_DONE)
	LD	A,NERR_AGAIN
	OR	A
	RET
.realerr
	LD	(SEND_RES),A		; the transport reason, before CONSUME_CANCEL
	CALL	CLEAR_PEND		; any real outcome ends the transaction
	CALL	CONSUME_CANCEL
	JR	C,.cancelled_de
	; Only silence after the complete payload left the host is safe to probe.
	; Before the '>' prompt, an AT probe can itself become CIPSEND payload if the
	; prompt was merely late. While a +IPD payload is incomplete, its remaining
	; binary bytes still own the receive parser and a probe response cannot be
	; parsed safely either.
	LD	A,(SEND_RES)
	CP	RES_RS_TIMEOUT
	JR	NZ,.fail
	LD	A,(TCP.SEND_PHASE)
	AND	A
	JR	Z,.fail
	LD	HL,(TCP.PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.fail
	; The ~10 s ladder is a blocking tool; a consumer that chose sliced sends
	; opted out of blocking - report the failure and let it decide.
	LD	HL,(OPT_SLICE)
	LD	A,H
	OR	L
	JR	NZ,.fail
	CALL	PROBE_AT
	CALL	CONSUME_CANCEL		; user abort during the probe rounds
	JP	C,.cancelled_de
	LD	A,(TCP.WSO_FLAGS)
	BIT	1,A			; "ready": the module rebooted mid-session
	JR	NZ,.reboot
	; Payload was handed over but SEND OK never arrived. Only a late
	; "SEND OK" caught by the probe proves delivery; a bare OK from the
	; probe's own AT does not, and a reissue here would duplicate bytes.
	LD	A,(TCP.WSO_FLAGS)
	BIT	0,A
	JR	Z,.fail
	LD	HL,(SEND_DONE)
	LD	BC,(CHUNK_LEN)
	ADD	HL,BC
	LD	(SEND_DONE),HL
	JP	.chunk
.reboot
	CALL	NOTE_SEND_FAILURE
	CALL	REBOOT_EVENT
.closed_now
	LD	DE,(SEND_DONE)
	LD	A,NERR_CLOSED
	OR	A
	RET
.fail
	CALL	NOTE_SEND_FAILURE
	LD	DE,(SEND_DONE)
	LD	A,NERR_SEND
	OR	A			; clear CF (reached via JR C from SEND_BUFFER)
	RET
.cancelled_de
	LD	DE,(SEND_DONE)
.cancelled
	LD	A,NERR_CANCEL
	OR	A
	RET
.closed_entry
	; A peer close latched while a transaction was suspended ends it.
	LD	A,(PEND_CH)
	LD	HL,ARG_CH
	CP	(HL)
	CALL	Z,CLEAR_PEND
	JP	RET_CLOSED

; Arm or disarm the suspendable-send machinery for this call from OPT_SLICE.
SETUP_ASYNC_MODE
	LD	HL,(OPT_SLICE)
	LD	A,H
	OR	L
	JR	Z,.off
	LD	(TCP.WSO_TIMEOUT),HL
	LD	A,1
	LD	(TCP.ASYNC_MODE),A
	RET
.off
	LD	HL,TCP_DEFAULT_TIMEOUT
	LD	(TCP.WSO_TIMEOUT),HL
	XOR	A
	LD	(TCP.ASYNC_MODE),A
	RET

; End any suspended transaction and restore blocking-mode timeouts.
CLEAR_PEND
	LD	A,0xFF
	LD	(PEND_CH),A
	LD	HL,TCP_DEFAULT_TIMEOUT
	LD	(TCP.WSO_TIMEOUT),HL
	JP	TCP.ASYNC_RESET

; A suspended send owns both the ESP parser and its eventual byte-count result.
; Only a repeat of the SAME SEND may advance it: completing it here on behalf
; of CLOSE/CONNECT/etc. would lose the success result, and a later repeat by the
; caller would duplicate the stream bytes. Other AT-producing calls therefore
; fail closed with BUSY and never touch the UART.
; Out: CF=0 when no transaction exists; CF=1/A=NERR_BUSY while one is pending.
RESOLVE_PENDING
	LD	A,(PEND_CH)
	CP	0xFF
	RET	Z
	LD	A,NERR_BUSY
	SCF
	RET

; Keep LASTERR useful without retaining the old verbose trace/tail telemetry.
; SEND_RES is a one-digit internal RES_* code and LINE_BUFFER holds the last
; complete response/probe line (empty when the ESP produced none).
NOTE_SEND_FAILURE
	LD	HL,WIFI.RS_BUFF
	LD	DE,MSG_SEND_FAIL
	CALL	TCP.APPEND_STR
	LD	A,(SEND_RES)
	ADD	A,'0'
	LD	(HL),A
	INC	HL
	LD	A,(TCP.LINE_BUFFER)
	AND	A
	JR	Z,.done
	LD	(HL),':'
	INC	HL
	LD	(HL),' '
	INC	HL
	LD	DE,TCP.LINE_BUFFER
	CALL	TCP.APPEND_STR
.done
	LD	(HL),0
	RET

; CF=0 when the probe reached the module's AT parser: a clean OK, or an
; ERROR/FAIL that late-terminated the command the ladder gave up on.
PROBE_ALIVE
	LD	A,(PROBE_RES)
	AND	A
	RET	Z
	CP	RES_ERROR
	RET	Z
	CP	RES_FAIL
	RET	Z
	SCF
	RET


; Probe whether the ESP is responsive after a silent timeout, WITHOUT losing
; peer data: the reply is read through TCP.WAIT_SEND_OK, which stashes any +IPD
; frame into its channel's defer window and latches "<id>,CLOSED" lines exactly
; like a normal send window. Line markers (ready/busy/CONNECT/"SEND OK")
; accumulate in TCP.WSO_FLAGS for the caller's ladder.
;
; The rounds are deliberately patient (~10 s total): ESP-AT serves the AT
; parser and all UART output from one task, and in CIPMUX=1 under bidirectional
; load that task can block inside a command for seconds - +IPD delivery stops
; with it - and then recover on its own. Observed on real 2.2.2 hardware at
; 230400: the module stays associated and keeps its session baud, so this is a
; stall, not a crash; a probe that gives up after one round misdiagnoses it.
; Out: PROBE_RES = 0 when the module answered, RES code otherwise.
PROBE_AT
	LD	A,PROBE_ROUNDS-1
	LD	(PROBE_LEFT),A
.round
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	HL,PROBE_BYTE_TIMEOUT
	LD	(TCP.WSO_TIMEOUT),HL
	LD	HL,CMD_PROBE_AT
	CALL	WIFI.UART_TX_STRING
	JR	C,.txfail
	CALL	TCP.MUX_WAIT_SEND_OK
.settle
	PUSH	AF
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	HL,TCP_DEFAULT_TIMEOUT
	LD	(TCP.WSO_TIMEOUT),HL
	POP	AF
	LD	(PROBE_RES),A
	AND	A
	RET	Z
	; An Esc/Ctrl+Z latched during a round must end the ladder here, not
	; after another ~10 s of probing. The flag is left for the caller to
	; consume and map to NERR_CANCEL.
	LD	A,(WCOMMON.CANCELLED)
	AND	A
	RET	NZ
	LD	A,(PROBE_LEFT)
	AND	A
	RET	Z
	DEC	A
	LD	(PROBE_LEFT),A
	LD	HL,500
	CALL	UTIL.DELAY
	JR	.round
.txfail
	LD	A,RES_TX_TIMEOUT
	JR	.settle

; The module printed its boot banner: every link is gone and CIPMUX is back at
; its power-on default. Latch both channels closed so pending data/close
; reporting stays truthful, and force the next CONNECT through ENSURE_MUX.
REBOOT_EVENT
	XOR	A
	LD	(MUX_ACTIVE),A
	XOR	A
	CALL	TCP.MUX_LATCH_CLOSED
	LD	A,1
	JP	TCP.MUX_LATCH_CLOSED

; A bare CRLF is legitimately ignored by ESP-AT, so probe with a command that
; always answers when the module is listening at all.
CMD_PROBE_AT	DB "AT",13,10,0
MSG_SEND_FAIL	DB "send failed ",0
MSG_CONN_SILENT	DB "connect failed: no ESP response",0

; ======================================================
; Function 7 - RECV
; ======================================================
F_RECV
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	CALL	GET_CH_STATE
	AND	A
	JP	Z,RET_STATE
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	; TCP.RECEIVE_MUX: A=channel, HL=buf, BC=max, DE=timeout
	LD	HL,(ARG_DE)
	LD	BC,(ARG_IX)
	LD	DE,(ARG_IY)
	LD	A,(ARG_CH)
	CALL	TCP.RECEIVE_MUX
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
	CALL	SET_CH_STATE
	CALL	BUILD_RECV_FLAGS
	LD	DE,0
	LD	A,NERR_CLOSED
	RET

; Build IX = RECV status flags for the channel in ARG_CH; reset its sticky
; loss flags. Per channel: bit1 more data pending, bit2 data lost (UART overrun
; or a buffered frame dropped). bit3 reports pending data on the OTHER channel,
; which is what turns an empty read into "switch channels" instead of "idle".
BUILD_RECV_FLAGS
	LD	HL,0
	LD	(RECV_FLAGS),HL
	LD	A,(ARG_CH)
	CALL	TCP.MUX_HAS_PENDING
	JR	NC,.no_more
	LD	HL,RECV_FLAGS
	SET	1,(HL)
.no_more
	; MUX_HAS_PENDING left our channel selected, so DEFER_LOST is ours.
	LD	A,(TCP.LSR_ACCUM)
	AND	LSR_OE
	JR	NZ,.lost
	LD	A,(TCP.DEFER_LOST)
	AND	A
	JR	Z,.no_lost
.lost
	LD	HL,RECV_FLAGS
	SET	2,(HL)
.no_lost
	XOR	A
	LD	(TCP.LSR_ACCUM),A
	LD	(TCP.DEFER_LOST),A
	; the other channel of this two-channel build
	LD	A,(ARG_CH)
	XOR	1
	CALL	TCP.MUX_HAS_PENDING
	JR	NC,.no_xchan
	LD	HL,RECV_FLAGS
	SET	3,(HL)
.no_xchan
	; leave the reading channel selected for the next call
	LD	A,(ARG_CH)
	CALL	TCP.DEFER_SELECT
	LD	IX,(RECV_FLAGS)
	XOR	A
	RET

; ======================================================
; Function 9 - STATUS
; ======================================================
F_STATUS
	CP	0xFF
	JR	Z,.netstat
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	HL,0
	LD	(RECV_FLAGS),HL		; reused as the state accumulator
	CALL	GET_CH_STATE
	AND	A
	JR	Z,.notopen
	CALL	CH_PEER_CLOSED
	JR	C,.notopen		; closed by the peer: no longer connected
	LD	HL,RECV_FLAGS
	SET	1,(HL)			; UNET_ST_CONN
.notopen
	; Report buffered-but-undelivered data so a consumer can tell "idle" from
	; "there is something waiting on this channel". Memory only: STATUS never
	; touches the UART.
	LD	A,(ARG_CH)
	CALL	TCP.MUX_HAS_PENDING
	JR	NC,.nopend
	LD	HL,RECV_FLAGS
	SET	2,(HL)			; UNET_ST_RXPEND
.nopend
	LD	DE,(RECV_FLAGS)
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
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(ARG_DE),DE
	LD	(ARG_IX),IX
	LD	(ARG_IY),IY
	LD	A,(INITED)
	AND	A
	JP	Z,RET_STATE
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	GET_CH_STATE
	AND	A
	JP	NZ,RET_STATE
	CALL	RESOLVE_PENDING		; no AT text may interleave a suspended send
	JP	C,RET_BUSY
	CALL	ENSURE_MUX
	JP	C,RET_BUSY
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
	CALL	SET_CH_STATE
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
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	LD	A,(RESOLVE_SUP)
	CP	2
	JP	Z,RET_NOTSUP
	CALL	RESOLVE_PENDING		; no AT text may interleave a suspended send
	JP	C,RET_BUSY
	CALL	ANY_CHANNEL_OPEN
	JP	NZ,RET_BUSY		; UART_TX_CMD is not binary +IPD-aware
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
	CALL	CHECK_RX_ACTIVE
	JP	C,RET_STATE
	CALL	RESOLVE_PENDING		; no AT text may interleave a suspended send
	JP	C,RET_BUSY
	CALL	ANY_CHANNEL_OPEN
	JP	NZ,RET_BUSY		; UART_TX_CMD is not binary +IPD-aware
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
	CP	UNET_OPT_SENDSLICE
	JR	Z,.sendslice
	JP	RET_PARAM
.sendslice
	; 0 disables (blocking sends); anything else is a silence quantum in ms,
	; clamped to >= 50 so the per-byte poll stays meaningful.
	LD	A,D
	OR	E
	JR	Z,.slice_store
	LD	HL,50
	OR	A
	SBC	HL,DE			; CF=1 when DE > 50
	JR	C,.slice_store
	LD	DE,50
.slice_store
	LD	(OPT_SLICE),DE
	XOR	A
	RET
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
RET_BUSY
	LD	A,NERR_BUSY
	OR	A
	RET
RET_CLOSED
	LD	A,NERR_CLOSED
	OR	A
	RET

; ======================================================
; Helpers
; ======================================================

; ------------------------------------------------------
; Channel plumbing
; ------------------------------------------------------
; Commands and active receive require the ESP->Sprinter direction to be open.
; Sending CIPSEND/CIPSTART while RXPAUSE holds RTS deasserted guarantees a
; prompt timeout and can fill the ESP UART TX ring indefinitely.
CHECK_RX_ACTIVE
	LD	A,(RX_PAUSED)
	AND	A
	RET	Z
	SCF
	RET

; Out: Z when both channels are closed, NZ when either is open.
ANY_CHANNEL_OPEN
	LD	A,(CH_STATE)
	LD	HL,CH_STATE+1
	OR	(HL)
	RET

; Validate the channel number in A and latch it. Out: CF=1 when out of range.
CHECK_CHANNEL
	CP	UNET_CHANNELS
	CCF
	RET	C
	LD	(ARG_CH),A
	RET

; Out: HL = &CH_STATE[ARG_CH].
CH_STATE_ADDR
	LD	A,(ARG_CH)
	LD	HL,CH_STATE
	ADD	A,L
	LD	L,A
	RET	NC
	INC	H
	RET

; Out: A = state of the selected channel (0 closed / 1 TCP / 2 UDP).
GET_CH_STATE
	CALL	CH_STATE_ADDR
	LD	A,(HL)
	RET

; In: A = new state for the selected channel.
SET_CH_STATE
	PUSH	AF
	CALL	CH_STATE_ADDR
	POP	AF
	LD	(HL),A
	RET

; Out: CF=1 when the peer already closed the selected channel.
CH_PEER_CLOSED
	LD	A,(ARG_CH)
	JP	TCP.MUX_IS_CLOSED

; Forget every channel's state and buffered data. Used by NETINIT, where the
; CIPCLOSE pair has really dropped any leftover socket.
RESET_CHANNEL_STATE
	XOR	A
	LD	(CH_STATE),A
	LD	(CH_STATE+1),A
	JP	TCP.RX_DEFER_RESET_ALL

; Re-arm AT+CIPMUX=1 if NETDONE handed the ESP back in single-connection mode.
; Out: CF=1 when the ESP stayed busy.
ENSURE_MUX
	LD	A,(MUX_ACTIVE)
	AND	A
	RET	NZ			; CF=0
	LD	HL,CMD_CIPMUX1
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_AT_BUSY
	RET	C
	LD	A,1
	LD	(MUX_ACTIVE),A
	OR	A			; CF=0
	RET

; Close one channel: AT+CIPCLOSE=<ch>. The reply is read through the IPD-aware
; line loop, because the peer on the OTHER channel may transmit while this one
; is closing (an FTP server sends "226 Transfer complete" on the control link
; exactly when the client closes the data link).
CLOSE_CHANNEL
	CALL	GET_CH_STATE
	AND	A
	RET	Z			; already closed: idempotent
	LD	A,(ARG_CH)
	LD	(TCP.LINK_ID),A
	CALL	TCP.MUX_CAPTURE_PENDING_PAYLOAD
	JR	C,.rx_busy		; never inject AT text into a partial +IPD payload
	LD	HL,TCP.CMD_BUFFER
	LD	DE,CMD_CIPCLOSE_PREFIX
	CALL	TCP.APPEND_STR
	CALL	TCP.APPEND_LINK_ID
	LD	DE,CMD_CRLF_STR
	CALL	TCP.APPEND_STR
	LD	HL,TCP.CMD_BUFFER
	CALL	WIFI.UART_TX_STRING
	JR	C,.tx_busy
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CLOSED),A
	CALL	TCP.MUX_WAIT_SEND_OK	; tolerate explicit ERROR: link may be gone already
	JR	NC,.wait_done
	CP	RES_RS_TIMEOUT
	JR	Z,.wait_busy		; ambiguous: keep local state, do not send more AT
	CP	RES_BUSY
	JR	Z,.wait_busy		; command was rejected: the link is still open
.wait_done
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CLOSED),A
.forget
	XOR	A
	CALL	SET_CH_STATE
	LD	A,(ARG_CH)
	CALL	TCP.MUX_CLEAR_CLOSED
	LD	A,(ARG_CH)
	CALL	TCP.RX_DEFER_RESET_CH	; an explicit close discards buffered data
	XOR	A
	RET
.tx_busy
.wait_busy
.rx_busy
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CLOSED),A
	LD	A,NERR_BUSY
	OR	A
	RET

; Close every open channel; leave the network up.
CLOSE_LINK
	LD	A,(ARG_CH)
	PUSH	AF
	XOR	A
	LD	(ARG_CH),A
	CALL	CLOSE_CHANNEL
	AND	A
	JR	NZ,.restore
	LD	A,1
	LD	(ARG_CH),A
	CALL	CLOSE_CHANNEL
.restore
	POP	AF
	LD	(ARG_CH),A
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
	LD	A,1
	LD	(CONN_TRY),A		; one ladder retry per call
	XOR	A
	LD	(TCP.WSO_FLAGS),A
.try
	CALL	MUX_OPEN
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
	; Silence deserves one probe: the module may be slow (retry), rebooted
	; (re-arm CIPMUX and retry), or may have opened the link right after our
	; timeout ("<id>,CONNECT" caught by the probe = the connect DID succeed).
	LD	A,(BUSY_LAST)
	CP	RES_RS_TIMEOUT
	JR	NZ,.hardfail
	LD	A,(CONN_TRY)
	AND	A
	JR	Z,.hardfail
	DEC	A
	LD	(CONN_TRY),A
	CALL	PROBE_AT
	LD	A,(WCOMMON.CANCELLED)	; left latched: F_CONNECT maps it to
	AND	A			; NERR_CANCEL via its own CONSUME_CANCEL
	JR	NZ,.hardfail
	LD	A,(TCP.WSO_FLAGS)
	BIT	3,A
	JR	NZ,.late_connect
	BIT	1,A
	JR	NZ,.rearm
	CALL	PROBE_ALIVE
	JR	C,.hardfail		; truly silent: nothing left to try
	JR	.try			; parser idle: the lost CIPSTART is dead
.late_connect
	XOR	A			; CF=0: the link is open
	RET
.rearm
	CALL	REBOOT_EVENT
	CALL	ENSURE_MUX
	JR	C,.hardfail
	JR	.try
.hardfail
	CALL	NOTE_CONNECT_FAILURE
	LD	A,(BUSY_LAST)
	SCF
	RET

; Open one link in multi-connection mode:
;   TCP: AT+CIPSTART=<ch>,"TCP","<host>",<port>
;   UDP: AT+CIPSTART=<ch>,"UDP","<host>",<rport>,<lport>,2
; Mode 2 lets the remote peer change, matching the single-connection behaviour.
; OPEN_MODE: 0 = TCP, 1 = UDP default local port, 2 = UDP explicit local port.
; Out: CF=0 ok, CF=1 / A = ESP result code.
MUX_OPEN
	LD	A,(ARG_CH)
	LD	(TCP.LINK_ID),A
	CALL	TCP.RX_DEFER_RESET_CH	; a fresh link must not replay old data
	LD	A,(ARG_CH)
	CALL	TCP.MUX_CLEAR_CLOSED
	LD	HL,0
	LD	(TCP.PAYLOAD_LEFT),HL
	XOR	A
	LD	(TCP.LSR_ACCUM),A

	LD	HL,TCP.CMD_BUFFER
	LD	DE,CMD_CIPSTART_PREFIX
	CALL	TCP.APPEND_STR
	CALL	TCP.APPEND_LINK_ID
	LD	DE,CMD_PROTO_TCP
	LD	A,(OPEN_MODE)
	AND	A
	JR	Z,.proto
	LD	DE,CMD_PROTO_UDP
.proto
	CALL	TCP.APPEND_STR
	LD	IX,(ARG_DE)		; host
	CALL	TCP.APPEND_IX_STR
	LD	DE,CMD_QUOTE_COMMA
	CALL	TCP.APPEND_STR
	LD	IX,(ARG_IX)		; port / remote port
	CALL	TCP.APPEND_IX_STR
	LD	A,(OPEN_MODE)
	AND	A
	JR	Z,.finish		; TCP needs nothing else
	LD	DE,CMD_COMMA_STR
	CALL	TCP.APPEND_STR
	LD	A,(OPEN_MODE)
	CP	2
	JR	Z,.explicit_lport
	; Default local port, one per channel so two default UDP channels cannot
	; collide on the same ESP-side port.
	LD	DE,UDP_LPORT_CH0
	LD	A,(ARG_CH)
	AND	A
	JR	Z,.lport
	LD	DE,UDP_LPORT_CH1
.lport
	CALL	TCP.APPEND_STR
	JR	.udptail
.explicit_lport
	LD	IX,(ARG_IY)
	CALL	TCP.APPEND_IX_STR
.udptail
	LD	DE,CMD_UDP_MODE
	CALL	TCP.APPEND_STR
.finish
	LD	DE,CMD_CRLF_STR
	CALL	TCP.APPEND_STR
	LD	HL,TCP.CMD_BUFFER
	LD	BC,TCP_OPEN_TIMEOUT
	LD	A,1
	LD	(TCP.MUX_ACCEPT_CONNECT),A
	CALL	MUX_TX_COMMAND
	PUSH	AF
	XOR	A
	LD	(TCP.MUX_ACCEPT_CONNECT),A
	POP	AF
	RET

; Send a command while one or both mux links may already be producing +IPD.
; The generic UART_TX_CMD stops only on text lines and can consume an immediate
; peer greeting as part of CIPSTART's response (CONNECT, +IPD, OK is a legal
; race). WAIT_SEND_OK already understands link prefixes, binary +IPD frames,
; CLOSED, busy, ERROR and a command-mode OK, so use it from the first byte.
; In: HL=ASCIIZ command, BC=per-byte timeout. Out: normal RES_*/CF contract.
MUX_TX_COMMAND
	LD	(TCP.WSO_TIMEOUT),BC
	; SEND_STATE_RESET and the pending-payload rescue both use HL internally.
	; Keep the caller's command pointer until the actual UART transmit; losing
	; it here makes UART_TX_STRING send from address zero instead of CMD_BUFFER.
	PUSH	HL
	CALL	TCP.SEND_STATE_RESET
	XOR	A
	LD	(WIFI.RS_BUFF),A
	LD	(TCP.LINE_BUFFER),A
	LD	(TCP.MUX_ACCEPT_OK),A
	CALL	TCP.MUX_CAPTURE_PENDING_PAYLOAD
	POP	HL
	JR	C,.finish
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	CALL	WIFI.UART_TX_STRING
	JR	NC,.wait
	LD	A,RES_TX_TIMEOUT
	SCF
	JR	.finish
.wait
	CALL	TCP.MUX_WAIT_SEND_OK
.finish
	PUSH	AF
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	HL,TCP_DEFAULT_TIMEOUT
	LD	(TCP.WSO_TIMEOUT),HL
	; Preserve the last complete/partial response line for LASTERR and the
	; existing busy/DNS diagnostics, just as UART_TX_CMD preserved RS_BUFF.
	LD	HL,WIFI.RS_BUFF
	LD	DE,TCP.LINE_BUFFER
	CALL	TCP.APPEND_STR
	LD	(HL),0
	POP	AF
	RET

; Keep CONNECT failures actionable even when the ESP produced no complete
; response line. PROBE_AT deliberately does not overwrite RS_BUFF, so without
; this a timeout/recovery failure surfaced as an empty LASTERR.
NOTE_CONNECT_FAILURE
	LD	A,(WIFI.RS_BUFF)
	AND	A
	RET	NZ
	LD	HL,WIFI.RS_BUFF
	LD	DE,MSG_CONN_SILENT
	JP	TCP.APPEND_STR

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
; Out: CF=1 if invalid, CF=0 if usable. Preserves BC, DE and HL: callers such
; as CHECK_BUF_RANGE keep their length in BC.
CHECK_BUF
	LD	A,H
	AND	0xC0
	JR	Z,.bad			; window 0
	CP	0xC0
	JR	Z,.bad			; window 3 (ISA)
	LD	A,(WIN_BASE)
	XOR	H
	AND	0xC0
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
	; 2.2.2-only DLL: refuse a session NETUP did not bring up as 2.2.2 rather
	; than silently driving 2.2.1 firmware with the 2.2.2 command set. The
	; compiled receive path is fixed (2.2.2/TR4); this only gates NETINIT.
	LD	HL,ENVN_ESP_FW
	CALL	ENV_GET_STAGE
	JR	Z,.bad222
	LD	HL,ENV_STAGE
	LD	DE,VAL_ESP_FW_222
	CALL	STRMATCH
	JR	NZ,.bad222
	OR	A			; NET_ESP_FW == 2.2.2 -> ok (CF=0)
	RET
.bad222
	SCF
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
CMD_CIPMUX1		DB "AT+CIPMUX=1",13,10,0
; SO_LINGER off, TCP_NODELAY off, SO_SNDTIMEO 4000 ms for all links (id 5).
CMD_CIPTCPOPT		DB "AT+CIPTCPOPT=5,-1,0,4000",13,10,0
CMD_CIPCLOSE_ALL	DB "AT+CIPCLOSE=5",13,10,0
CMD_CIPCLOSE_ONE	DB "AT+CIPCLOSE",13,10,0
; Multi-connection command fragments, assembled around the link digit.
CMD_CIPSTART_PREFIX	DB "AT+CIPSTART=",0
CMD_CIPCLOSE_PREFIX	DB "AT+CIPCLOSE=",0
CMD_PROTO_TCP		DB ",",34,"TCP",34,",",34,0
CMD_PROTO_UDP		DB ",",34,"UDP",34,",",34,0
CMD_QUOTE_COMMA		DB 34,",",0
CMD_COMMA_STR		DB ",",0
CMD_UDP_MODE		DB ",2",0	; remote peer may change
CMD_CRLF_STR		DB 13,10,0
UDP_LPORT_CH0		DB "1069",0
UDP_LPORT_CH1		DB "1070",0
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
	IFNDEF	ESP_AT_FORCE_221		; only the universal build matches "2.2.1"
	IFNDEF	ESP_AT_FORCE_222		; (forced 2.2.2 pins the profile at build time)
VAL_ESP_FW_221	DB "2.2.1",0
	ENDIF
	ENDIF
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
CH_STATE		DB 0,0	; per channel: 0 closed, 1 TCP open, 2 UDP open
MUX_ACTIVE		DB 0	; AT+CIPMUX=1 currently in force
ARG_CH			DB 0	; channel argument of the call in progress
RECV_FLAGS		DW 0	; RECV flag / STATUS state accumulator
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
SEND_RES		DB 0		; transport result retained for compact LASTERR
SEND_TRY		DB 0		; ladder reissue budget of the current F_SEND
CONN_TRY		DB 0		; ladder retry budget of the current OPEN_RETRY
; Suspended-send transaction (CAP_ASYNCSEND).
PEND_CH			DB 0xFF		; channel of the suspended send, 0xFF = none
PEND_BUF		DW 0		; resume-contract reference: same buffer...
PEND_LEN		DW 0		; ...and same length must be passed again
OPT_SLICE		DW 0		; UNET_OPT_SENDSLICE value, 0 = blocking
PROBE_RES		DB 0		; last PROBE_AT outcome (used by recovery)
PROBE_LEFT		DB 0
PROBE_ROUNDS		EQU 5	; x (1.5 s wait + 0.5 s pause) = ~10 s patience
PROBE_BYTE_TIMEOUT EQU 1500
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
; esp_udp.asm is deliberately NOT included: its AT+CIPSTART/CIPCLOSE builders are
; single-connection only. In multi-connection mode a UDP link is opened by
; MUX_OPEN and shares the link-aware CIPSEND/CIPCLOSE/+IPD paths with TCP.
	INCLUDE "esplib.asm"

	ASSERT UNET_CHANNELS == TCP_MUX_CHANNELS

; ======================================================
; In-image BSS. Reserve the whole RS_BUFF chain plus our staging buffers as
; zero bytes so they live inside the declared 16 KB image (see header note).
; ======================================================
	MODULE UNET

ENV_STAGE	EQU TCP.TCP_BSS_END
ENV_STAGE_SIZE	EQU 192	; DSS ENV_GET has no length cap; headroom for long values
CMDBUILD	EQU ENV_STAGE + ENV_STAGE_SIZE
CMDBUILD_SIZE	EQU 160
DLL_BSS_END	EQU CMDBUILD + CMDBUILD_SIZE

	ENDMODULE

	DS UNET.DLL_BSS_END - $, 0	; reserve BSS as in-image zeros
	DB 0x55				; canary: keep the BSS region in the raw image
	ASSERT $ <= 0x4000		; image (incl. header at load) fits one 16 KB window
