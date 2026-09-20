; ======================================================
; ESP-AT TCP helper routines for Sprinter ESP Network Kit
; Single-connection TCP client over Sprinter-WiFi UART.
; ======================================================

	IFNDEF	_ESP_TCP
	DEFINE	_ESP_TCP

TCP_DEFAULT_TIMEOUT	EQU 5000
	IFDEF	TCP_LONG_OPEN_TIMEOUT
TCP_OPEN_TIMEOUT	EQU 60000			; DNS plus an external ESP8266 TCP connect
	ELSE
TCP_OPEN_TIMEOUT	EQU 20000			; connect timeout; was 60000 — too long to wait out a wedged/half-open link
	ENDIF
TCP_BUSY_RETRIES	EQU 10				; CIPSTART retries while the ESP answers "busy p..."
TCP_BUSY_DELAY		EQU 400				; ms between busy retries
TCP_CMD_SIZE		EQU 192
TCP_LINE_SIZE		EQU 64
TCP_DEBUG_SIZE		EQU 12
	IFDEF TCP_ACTIVE_IPD_MAX_OVERRIDE
TCP_ACTIVE_IPD_MAX	EQU TCP_ACTIVE_IPD_MAX_OVERRIDE
	ELSE
TCP_ACTIVE_IPD_MAX	EQU 1500
	ENDIF
; Busy-poll iterations spent waiting for the next UART byte before the normal
; one-millisecond timeout pace. Sized to bridge FIFO bursts at 115200 baud;
; it is a one-off fast probe, not a chargeable millisecond tick.
RX_SPIN_BUDGET		EQU 200
	IFDEF ISA_RX_GUARD
; Guarded FTP polls continuously instead of pulsing RTS on every empty tick.
; ~1 ms at the Sprinter's 21 MHz, including the LSR/error loop itself; no
; additional DELAY_1MS. Host-side cycle vectors bound this accounting.
RX_GUARD_SPIN_BUDGET	EQU 156
	ENDIF
; Short timeout for peeking whether another back-to-back +IPD frame is coming
; within one RECEIVE call. Bounds the end-of-stream wait on an idle keep-alive
; socket without giving up on a still-active burst. This wait is paid once per
; filled receive buffer when no next +IPD is ready; 800 ms dominated 115200
; downloads. FTP uses the same burst strategy with 120 ms.
TCP_CONT_TIMEOUT	EQU 120

; Optional receive-defer window (ESP_TCP_RX_DEFER). When a +IPD frame arrives
; between the CIPSEND '>' prompt and "SEND OK", the base library discards its
; payload (SKIP_IPD_FRAME). With ESP_TCP_RX_DEFER defined, that payload is
; instead captured into a small buffer and handed to the next RECEIVE, closing
; the full-duplex race documented in docs/UNETAPI.md. One MTU-sized frame fits
; with headroom; a frame that would overflow is dropped (old behaviour) and the
; sticky DEFER_LOST flag is raised. A UART timeout mid-frame is NOT a loss by
; itself: the bytes that arrived are kept and the exact unread tail stays live
; (PAYLOAD_LEFT), so the stream resumes without a gap; only a caller that
; cannot resume raises DEFER_LOST. Only the UNET DLL enables this; every stock
; app builds without it and its .EXE stays byte-identical.
	IFDEF ESP_TCP_RX_DEFER
	IFNDEF TCP_RX_DEFER_SIZE
TCP_RX_DEFER_SIZE	EQU 2048
	ENDIF
	ENDIF

; Optional two-channel mode (ESP_TCP_MUX, requires ESP_TCP_RX_DEFER). Adds the
; AT+CIPMUX=1 dialect: link-aware "+IPD,<link>,<len>:" headers, "<link>,CLOSED"
; notifications and one receive-defer stash per channel, so a client can hold a
; control and a data connection at the same time (passive FTP). A frame that
; arrives for the channel the caller is not reading is stashed for that channel
; instead of being lost. Only the UNET DLL enables this; every stock app builds
; without it and its .EXE stays byte-identical.
	IFDEF ESP_TCP_MUX
	IFNDEF ESP_TCP_RX_DEFER
	DISPLAY "ESP_TCP_MUX requires ESP_TCP_RX_DEFER"
	ASSERT 0
	ENDIF
TCP_MUX_CHANNELS	EQU 2	; channels this build demultiplexes (ESP-AT allows 0..4)
TCP_MUX_MAX_LINK	EQU 4	; highest link id accepted from an ESP-AT header
RES_AGAIN		EQU 20	; send suspended on link silence (ASYNC_MODE only):
				; resume with SEND_BUFFER_RESUME, nothing was lost
RES_CONN_EVT		EQU 21	; WAIT_IPD_HEADER_MUX matched a spontaneous
				; "<link>,CONNECT" while a channel is listening
				; (UNET_CAP_LISTEN). MUX_CONNECT_LINK holds the
				; link id (0xFF if no digit prefix was seen).
	ENDIF

	MODULE TCP

; The single-connection OPEN/TX_CMD_BUSY_RETRY/CLOSE/RECEIVE/WAIT_IPD_HEADER/
; READ_IPD_LEN/SKIP_IPD_FRAME family below is dead weight in an ESP_TCP_MUX
; build: MUX_OPEN/MUX_WAIT_SEND_OK/RECEIVE_MUX/WAIT_IPD_HEADER_MUX replace it
; end to end. Gating it here (rather than deleting it) keeps every
; single-connection app (ftp/wget/tftp/etc, which never define ESP_TCP_MUX)
; byte-identical while freeing image bytes for the mux-only UNETESP.DLL build.
	IFNDEF ESP_TCP_MUX
; ------------------------------------------------------
; Open a single TCP connection.
; In: HL - host ASCIIZ, DE - port ASCIIZ.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
OPEN
	LD	(PTR_HOST),HL
	LD	(PTR_PORT),DE
	LD	HL,0
	LD	(PAYLOAD_LEFT),HL
	XOR	A
	LD	(LSR_ACCUM),A
	IFDEF ESP_TCP_RX_DEFER
	CALL	RX_DEFER_RESET		; a fresh link must not replay old peer data
	ENDIF

	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSTART_PREFIX
	CALL	APPEND_STR
	LD	IX,(PTR_HOST)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CIPSTART_MIDDLE
	CALL	APPEND_STR
	LD	IX,(PTR_PORT)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CRLF
	CALL	APPEND_STR

	LD	HL,CMD_BUFFER
	LD	BC,TCP_OPEN_TIMEOUT
	JP	TX_CMD_BUSY_RETRY

; ------------------------------------------------------
; Send the AT command at HL (timeout BC), retrying while the ESP answers
; "busy p...". Right after NETUP's join the IP stack may still be coming up,
; so the first network command of a utility fails with RES_BUSY even though
; plain AT already works; a short settle-and-retry loop bridges that window
; the same way PING's dedicated loop does.
; Out: CF=0/A=0 on success, CF=1/A=result code on failure.
; ------------------------------------------------------
TX_CMD_BUSY_RETRY
	LD	(BUSY_CMD),HL
	LD	(BUSY_TIMEOUT),BC
	LD	A,TCP_BUSY_RETRIES
	LD	(BUSY_LEFT),A
.TRY
	LD	HL,(BUSY_CMD)
	LD	DE,WIFI.RS_BUFF
	LD	BC,(BUSY_TIMEOUT)
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	CP	RES_BUSY
	JR	NZ,.FAIL
	LD	A,(BUSY_LEFT)
	AND	A
	JR	Z,.EXHAUSTED
	DEC	A
	LD	(BUSY_LEFT),A
	LD	HL,TCP_BUSY_DELAY
	CALL	UTIL.DELAY
	JR	.TRY
.EXHAUSTED
	LD	A,RES_BUSY
.FAIL
	SCF
	RET

; ------------------------------------------------------
; Close the current TCP connection.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
CLOSE
	LD	HL,CMD_CIPCLOSE
	LD	DE,WIFI.RS_BUFF
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	SCF
	RET
	ENDIF

; ------------------------------------------------------
; Send a raw TCP payload.
; In: HL - payload, BC - payload length.
; Out: CF=0/A=0 on success, CF=1/A=result code on failure.
; ------------------------------------------------------
SEND_BUFFER
	CALL	START_SEND_BUFFER
	RET	C
	IFDEF ESP_TCP_MUX
	JP	MUX_WAIT_SEND_OK
	ELSE
	JP	WAIT_SEND_OK
	ENDIF

; ------------------------------------------------------
; Send a raw TCP payload and return immediately after UART transmit.
; In: HL - payload, BC - payload length.
; Out: CF=0/A=0 after bytes were accepted by the UART.
;      CF=1/A=result code on prompt/tx timeout.
; Notes:
; - Some interactive protocols (FTP control channel) can receive remote data
;   before ESP prints SEND OK. Waiting for SEND OK as text can consume +IPD
;   payload, so such callers should scan for +IPD themselves after this call.
; ------------------------------------------------------
	IFNDEF ESP_TCP_MUX
SEND_BUFFER_NO_WAIT
	CALL	START_SEND_BUFFER
	RET
	ENDIF

	IFDEF ESP_TCP_MUX
; ------------------------------------------------------
; Continue a send transaction that suspended with RES_AGAIN (ASYNC_MODE).
; Same contract as SEND_BUFFER. The CIPSEND command is NOT retransmitted -
; the ESP already holds it - only the pending wait continues from its saved
; state, so a resume can never duplicate stream bytes.
; ------------------------------------------------------
SEND_BUFFER_RESUME
	LD	A,(ASYNC_PEND)
	CP	2
	JP	Z,MUX_WAIT_SEND_OK	; payload sent: still awaiting SEND OK
	CALL	MUX_WAIT_PROMPT
	RET	C
	LD	HL,(SEND_PTR)
	LD	BC,(SEND_LEN)
	CALL	WIFI.UART_TX_BUFFER
	JR	C,.TX_TIMEOUT
	LD	A,1
	LD	(SEND_PHASE),A
	JP	MUX_WAIT_SEND_OK
.TX_TIMEOUT
	LD	A,RES_TX_TIMEOUT
	SCF
	RET

; Forget any suspended transaction state (explicit close / session teardown).
ASYNC_RESET
	XOR	A
	LD	(ASYNC_MODE),A
	LD	(ASYNC_PEND),A
	LD	(PROMPT_RESUME),A
	LD	(WSO_RESUME),A
	RET
	ENDIF

START_SEND_BUFFER
	LD	(SEND_PTR),HL
	LD	(SEND_LEN),BC

	LD	H,B
	LD	L,C
	LD	DE,NUM_BUFFER
	CALL	UTIL.UTOA

	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSEND_PREFIX
	CALL	APPEND_STR
	IFDEF ESP_TCP_MUX
	CALL	APPEND_LINK_ID		; AT+CIPSEND=<link>,<len>
	LD	DE,CMD_COMMA
	CALL	APPEND_STR
	ENDIF
	LD	DE,NUM_BUFFER
	CALL	APPEND_STR
	LD	DE,CMD_CRLF
	CALL	APPEND_STR

	IFDEF ESP_TCP_MUX
	; Drop the previous response line: if this send fails before any line
	; arrives, the caller must not be shown a stale one as the reason.
	XOR	A
	LD	(LINE_BUFFER),A
	CALL	SEND_STATE_RESET
	CALL	MUX_CAPTURE_PENDING_PAYLOAD
	RET	C			; partial +IPD still owns the UART stream
	ELSE
	IFDEF ESP_TCP_RX_DEFER
	; Do NOT flush the RX FIFO: bytes already queued are the start of a +IPD
	; frame that WAIT_PROMPT will capture. Only rescue a payload the app left
	; unread so it can't be mistaken for the '>' prompt / SEND OK.
	CALL	CAPTURE_PENDING_PAYLOAD
	RET	C			; partial +IPD still owns the UART stream
	ELSE
	CALL	WIFI.UART_EMPTY_RS
	ENDIF
	ENDIF
	LD	HL,CMD_BUFFER
	CALL	WIFI.UART_TX_STRING
	JR	C,.TX_TIMEOUT

	IFDEF ESP_TCP_MUX
	CALL	MUX_WAIT_PROMPT
	ELSE
	CALL	WAIT_PROMPT
	ENDIF
	RET	C

	LD	HL,(SEND_PTR)
	LD	BC,(SEND_LEN)
	CALL	WIFI.UART_TX_BUFFER
	JR	C,.TX_TIMEOUT

	IFDEF ESP_TCP_MUX
	; The recovery ladder must know whether the payload left the host: before
	; this point a lost CIPSEND may be reissued, after it a reissue would
	; duplicate bytes in the stream.
	LD	A,1
	LD	(SEND_PHASE),A
	ENDIF
	XOR	A
	RET

.TX_TIMEOUT
	LD	A,RES_TX_TIMEOUT
	SCF
	RET

	IFNDEF ESP_TCP_MUX
; ------------------------------------------------------
; Receive one +IPD payload block.
; In: HL - destination buffer, BC - max stored bytes, DE - timeout ms.
; Out: CF=0/A=0/BC=stored bytes on success.
;      CF=1/A=result code on timeout or protocol error.
; Notes:
; - The full ESP payload is consumed even if it is larger than BC.
; - Data is binary; no zero terminator is appended.
; ------------------------------------------------------
RECEIVE
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_RECORD_RECEIVE_CALL
	ENDIF
	; Reassert the profile-specific streaming trigger without flushing queued
	; +IPD bytes. The 2.2.1 routine is a no-op and retains its proven trigger 8.
	CALL	WIFI.UART_SET_DATA_RX_MODE
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	(RECV_FULL_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL

	IFDEF ESP_TCP_RX_DEFER
	; Replay peer data captured during a prior SEND before reading the UART,
	; so it is delivered ahead of any live +IPD (preserves stream order).
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JP	NZ,RECEIVE_FROM_DEFER
	LD	HL,(DEFER_R)
	LD	DE,(DEFER_W)
	OR	A
	SBC	HL,DE			; R-W; CF=1 while R<W (frames queued)
	JP	C,RECEIVE_FROM_DEFER
	ENDIF

	CALL	ISA.ISA_OPEN
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.CONTINUE_PAYLOAD
	CALL	WAIT_IPD_HEADER
	JR	C,.DONE
	CALL	READ_IPD_LEN
	JR	C,.DONE
.CONTINUE_PAYLOAD
	CALL	READ_PAYLOAD
.MORE_ACTIVE
	JR	C,.DONE
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.DONE
	CALL	CAN_READ_ANOTHER_ACTIVE_IPD
	JR	C,.RETURN_STORED_OK
	; Peek for another back-to-back +IPD with a short timeout. At line rate the
	; next frame arrives within it; if the stream has paused/ended (e.g. a
	; keep-alive socket idle after the final byte) we return the data already
	; buffered instead of blocking the full receive timeout. No data is lost:
	; any later bytes are picked up by the next RECEIVE call.
	LD	HL,TCP_CONT_TIMEOUT
	LD	(RECV_TIMEOUT),HL
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_BEGIN_CONTINUATION
	ENDIF
	CALL	WAIT_IPD_HEADER
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_END_CONTINUATION
	ENDIF
	LD	HL,(RECV_FULL_TIMEOUT)
	LD	(RECV_TIMEOUT),HL
	JR	NC,.NEXT_ACTIVE
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_RECORD_CONTINUATION_MISS
	ENDIF
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	Z,.DONE
	LD	B,H
	LD	C,L
	XOR	A
	JR	.DONE
.RETURN_STORED_OK
	LD	HL,(RECV_STORED)
	LD	B,H
	LD	C,L
	XOR	A
	JR	.DONE
.NEXT_ACTIVE
	CALL	READ_IPD_LEN
	JR	NC,.CONTINUE_PAYLOAD
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	Z,.DONE
	LD	B,H
	LD	C,L
	XOR	A
.DONE
	CALL	ISA.ISA_CLOSE
	RET
	ENDIF

; CF=0 when there is enough caller buffer left to consume another full
; ESP active +IPD block without returning to slow DSS/file code.
CAN_READ_ANOTHER_ACTIVE_IPD
	LD	HL,(RECV_REMAIN)
	LD	DE,TCP_ACTIVE_IPD_MAX
	LD	A,H
	CP	D
	RET	NZ
	LD	A,L
	CP	E
	RET

; ------------------------------------------------------
; Wait for ESP CIPSEND prompt.
; Reads bytes until '>'. If a "+IPD,N:<payload>" frame arrives mid-wait
; (ESP forwards queued network data interleaved with AT-command output),
; consume it by length and continue waiting. Without this, the IPD
; binary payload bytes would be silently discarded one at a time as
; "not '>'" and lost; a TFTP retransmit of the lost block would then
; be eaten the same way on every subsequent ACK SEND_PACKET round-trip,
; producing the partial-then-timeout-forever symptom on real hardware.
; ------------------------------------------------------
WAIT_PROMPT
	PUSH	IX
	LD	IX,IPD_PREFIX
	IFDEF ESP_TCP_MUX
	; A suspended wait (ASYNC_MODE) resumes exactly where it left off,
	; including a half-matched "+IPD," prefix - restarting the match there
	; would misread the rest of the header as junk and lose the frame.
	LD	A,(PROMPT_RESUME)
	AND	A
	JR	Z,.NEXT
	XOR	A
	LD	(PROMPT_RESUME),A
	LD	IX,(PROMPT_STATE)
	ENDIF
.NEXT
	IFDEF ESP_TCP_MUX
	LD	BC,(WSO_TIMEOUT)	; slice in async mode, 5 s otherwise
	ELSE
	LD	BC,TCP_DEFAULT_TIMEOUT
	ENDIF
	IFDEF ESP_TCP_MUX
	LD	A,(MUX_WINDOW_OPEN)
	AND	A
	JR	Z,.READ_CLOSED
	CALL	READ_BYTE_TIMEOUT_OPEN
	JR	.READ_DONE
.READ_CLOSED
	CALL	READ_BYTE_TIMEOUT
.READ_DONE
	ELSE
	CALL	READ_BYTE_TIMEOUT
	ENDIF
	IFDEF ESP_TCP_MUX
	JP	C,.RD_TIMEOUT
	ELSE
	JR	C,.TIMEOUT_POP
	ENDIF
	LD	E,A
	CP	'>'
	JR	Z,.OK_POP
	LD	A,(IX+0)
	CP	E
	JR	NZ,.IPD_RESET
	INC	IX
	LD	A,(IX+0)
	AND	A
	JR	Z,.IPD_HIT
	JR	.NEXT
.IPD_RESET
	LD	IX,IPD_PREFIX
	LD	A,E
	CP	'+'
	JR	NZ,.NEXT
	INC	IX
	JR	.NEXT
.IPD_HIT
	IFDEF ESP_TCP_MUX
	CALL	MUX_CAPTURE_IPD_FRAME
	ELSE
	IFDEF ESP_TCP_RX_DEFER
	CALL	CAPTURE_IPD_FRAME
	ELSE
	CALL	SKIP_IPD_FRAME
	ENDIF
	ENDIF
	JR	C,.TIMEOUT_POP
	LD	IX,IPD_PREFIX
	JR	.NEXT
.OK_POP
	POP	IX
	XOR	A
	RET
	IFDEF ESP_TCP_MUX
.RD_TIMEOUT
	; Silence at a clean point (not inside a frame capture). In async mode
	; that is a suspension, not a failure: park the prefix-match state and
	; hand control back to the consumer.
	LD	A,(ASYNC_MODE)
	AND	A
	JR	Z,.TIMEOUT_POP
	LD	(PROMPT_STATE),IX
	LD	A,1
	LD	(PROMPT_RESUME),A
	LD	(ASYNC_PEND),A		; 1 = awaiting the '>' prompt
	POP	IX
	LD	A,RES_AGAIN
	SCF
	RET
	ENDIF
.TIMEOUT_POP
	POP	IX
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; ------------------------------------------------------
; Wait until ESP reports SEND OK / ERROR / FAIL.
; Like WAIT_PROMPT, this is IPD-aware: when the line being accumulated
; starts with "+IPD," we switch to length-driven skip instead of trying
; to match a CR/LF terminator inside binary payload.
; ------------------------------------------------------
WAIT_SEND_OK
	IFDEF ESP_TCP_MUX
	; A suspended wait resumes mid-line: LINE_REMAIN/IPD_STATE_PTR survived
	; in memory, only the store pointer needs recomputing.
	LD	A,(WSO_RESUME)
	AND	A
	JR	NZ,.RESUME
	ENDIF
.RESTART
	LD	IX,LINE_BUFFER
	LD	A,TCP_LINE_SIZE-1
	LD	(LINE_REMAIN),A
	LD	HL,IPD_PREFIX
	LD	(IPD_STATE_PTR),HL
	IFDEF ESP_TCP_MUX
	JR	.NEXT_BYTE
.RESUME
	XOR	A
	LD	(WSO_RESUME),A
	LD	A,TCP_LINE_SIZE-1
	LD	HL,LINE_REMAIN
	SUB	(HL)			; characters already stored in this line
	LD	E,A
	LD	D,0
	LD	IX,LINE_BUFFER
	ADD	IX,DE
	ENDIF
.NEXT_BYTE
	IFDEF ESP_TCP_MUX
	; Indirect so the recovery probe can run this loop with a short per-byte
	; timeout; every normal caller sees TCP_DEFAULT_TIMEOUT.
	LD	BC,(WSO_TIMEOUT)
	ELSE
	LD	BC,TCP_DEFAULT_TIMEOUT
	ENDIF
	IFDEF ESP_TCP_MUX
	LD	A,(MUX_WINDOW_OPEN)
	AND	A
	JR	Z,.READ_CLOSED
	CALL	READ_BYTE_TIMEOUT_OPEN
	JR	.READ_DONE
.READ_CLOSED
	CALL	READ_BYTE_TIMEOUT
.READ_DONE
	ELSE
	CALL	READ_BYTE_TIMEOUT
	ENDIF
	IFDEF ESP_TCP_MUX
	JP	C,.TIMEOUT		; mux dialect handling puts .TIMEOUT out of JR reach
	ELSE
	JR	C,.TIMEOUT
	ENDIF
	LD	E,A
	CP	13
	JR	Z,.NEXT_BYTE
	CP	10
	JR	Z,.END_LINE
	; If still potentially matching "+IPD," at the start of this line,
	; advance the state; otherwise IPD detection is dead for this line.
	LD	HL,(IPD_STATE_PTR)
	LD	A,H
	OR	L
	JR	Z,.STORE_CHAR
	LD	A,(HL)
	CP	E
	JR	NZ,.IPD_GAVE_UP
	INC	HL
	LD	(IPD_STATE_PTR),HL
	LD	A,(HL)
	AND	A
	JR	Z,.IPD_LINE_HIT
	JR	.STORE_CHAR
.IPD_GAVE_UP
	LD	HL,0
	LD	(IPD_STATE_PTR),HL
.STORE_CHAR
	LD	A,(LINE_REMAIN)
	AND	A
	JR	Z,.NEXT_BYTE
	LD	(IX+0),E
	INC	IX
	DEC	A
	LD	(LINE_REMAIN),A
	JR	.NEXT_BYTE
.IPD_LINE_HIT
	IFDEF ESP_TCP_MUX
	CALL	MUX_CAPTURE_IPD_FRAME
	JP	C,.TIMEOUT		; the marker chain puts .TIMEOUT out of JR reach
	JP	.RESTART
	ELSE
	IFDEF ESP_TCP_RX_DEFER
	CALL	CAPTURE_IPD_FRAME
	ELSE
	CALL	SKIP_IPD_FRAME
	ENDIF
	JR	C,.TIMEOUT
	JP	.RESTART
	ENDIF
.END_LINE
	LD	(IX+0),0
	LD	A,(LINE_BUFFER)
	AND	A
	JP	Z,.RESTART
	IFDEF ESP_TCP_MUX
	; In AT+CIPMUX=1 the ESP prefixes link-scoped notifications with "<id>,".
	; Strip it before matching, and treat "<id>,CLOSED" as a peer-close event
	; for that link: a foreign link closing must not abort our send, and our
	; own link closing is still followed by SEND OK / ERROR / FAIL.
	CALL	MUX_LINE_STRIP
	LD	HL,CLOSED_PREFIX
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JR	C,.NOT_CLOSED
	LD	A,(MUX_LINE_LINK)
	CALL	MAP_LINK_TO_CH		; MUX_LATCH_CLOSED indexes MUX_CLOSED_MASK by
	CALL	MUX_LATCH_CLOSED	; channel, not by raw firmware link id
	LD	A,(MUX_ACCEPT_CLOSED)
	AND	A
	JP	Z,.RESTART
	LD	A,(MUX_LINE_LINK)
	LD	HL,LINK_ID
	CP	(HL)
	JP	NZ,.RESTART
	XOR	A
	LD	(ASYNC_PEND),A
	RET
.NOT_CLOSED
	; AT+CIPCLOSE=<id> terminates with a plain OK; the flag lets that caller
	; share this IPD-aware line loop instead of a blind UART_TX_CMD, which
	; would swallow peer data racing the close.
	LD	A,(MUX_ACCEPT_OK)
	AND	A
	JR	Z,.NOT_OK
	LD	HL,MSG_OK
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JR	C,.NOT_OK
	; CIPSTART is complete only when its own <id>,CONNECT arrives. A bare OK
	; can be the tail of the previous command and, on a streaming peer, waiting
	; for the OK after CONNECT can starve forever behind continuous +IPD.
	LD	A,(MUX_ACCEPT_CONNECT)
	AND	A
	JR	NZ,.NOT_OK
	JP	.OK
.NOT_OK
	LD	HL,MSG_SEND_OK
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JR	NC,.SENDOK_HIT
	LD	HL,MSG_ERROR
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JP	NC,.ERROR
	LD	HL,MSG_FAIL
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JP	NC,.FAIL
	; Evidence markers for the recovery ladder (see PROBE_AT in the DLL):
	; matched once per complete non-matching line, never in the byte loop, so
	; the hot path cost is nil. "ready" is the module's own reboot banner.
	LD	HL,MSG_READY
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JR	NC,.MARK_READY
	LD	HL,MSG_CONNECT_LN
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JR	NC,.MARK_CONNECT
	LD	HL,MSG_ALREADY_CONNECTED
	LD	DE,(MUX_LINE_PTR)
	CALL	UTIL.STRCMP
	JR	NC,.MARK_ALREADY
	LD	DE,MSG_BUSY_PFX
	LD	HL,(MUX_LINE_PTR)
	CALL	UTIL.STARTSWITH
	JR	Z,.MARK_BUSY
	JP	.RESTART
.SENDOK_HIT
	LD	HL,WSO_FLAGS
	SET	0,(HL)
	JR	.OK
.MARK_READY
	LD	HL,WSO_FLAGS
	SET	1,(HL)
	JP	.RESTART
.MARK_BUSY
	LD	HL,WSO_FLAGS
	SET	2,(HL)
	; In command-response mode (MUX_ACCEPT_OK), "busy p..." is terminal:
	; the interpreter rejected the command and no OK will follow. Returning it
	; immediately lets CIPSTART/CIPCLOSE retry safely without a false timeout.
	LD	A,(MUX_ACCEPT_OK)
	AND	A
	JP	Z,.RESTART
	XOR	A
	LD	(ASYNC_PEND),A
	LD	A,RES_BUSY
	SCF
	RET
.MARK_ALREADY
	; A retry after a silent CIPSTART can find that its first attempt really
	; opened the requested link but the <id>,CONNECT notification was lost.
	; Record the firmware's unambiguous reply; OPEN_RETRY decides whether this
	; is a recovery retry (safe to accept) or a stale pre-existing link.
	LD	HL,WSO_FLAGS
	SET	4,(HL)
	JP	.RESTART
.MARK_CONNECT
	; Only the requested link is evidence for this recovery/open. A foreign
	; CONNECT must neither complete CIPSTART nor poison the recovery flag -
	; but it may be an inbound accept arriving in this command window, so
	; offer it to LISTEN before restarting the line loop.
	LD	A,(MUX_LINE_LINK)
	LD	HL,LINK_ID
	CP	(HL)
	JR	Z,.MARK_CONNECT_OWN
	LD	A,(MUX_LINE_LINK)
	CALL	MUX_TRY_ACCEPT
	JP	.RESTART
.MARK_CONNECT_OWN
	LD	HL,WSO_FLAGS
	SET	3,(HL)
	LD	A,(MUX_ACCEPT_CONNECT)
	AND	A
	JP	Z,.RESTART
	; Stop the ESP at the UART boundary before returning through libman to the
	; application. Otherwise an immediate peer greeting can overrun the 16-byte
	; 16550 FIFO in the small CONNECT->first RECV scheduling gap. No FIFO bytes
	; are flushed; the next data/command operation resumes RTS first.
	LD	A,(MUX_WINDOW_OPEN)
	AND	A
	JR	Z,.PAUSE_CLOSED
	CALL	WIFI.UART_RX_PAUSE_OPEN
	JR	.PAUSED
.PAUSE_CLOSED
	CALL	WIFI.UART_RX_PAUSE
.PAUSED
	LD	A,1
	LD	(MUX_CONNECT_PAUSED),A
	XOR	A
	LD	(ASYNC_PEND),A
	RET
	ELSE
	LD	HL,MSG_SEND_OK
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.OK
	LD	HL,MSG_ERROR
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.ERROR
	LD	HL,MSG_FAIL
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.FAIL
	JP	.RESTART
	ENDIF
.OK
	IFDEF ESP_TCP_MUX
	XOR	A
	LD	(ASYNC_PEND),A		; any terminal outcome ends the transaction
	ENDIF
	XOR	A
	RET
.ERROR
	IFDEF ESP_TCP_MUX
	XOR	A
	LD	(ASYNC_PEND),A
	ENDIF
	LD	A,RES_ERROR
	SCF
	RET
.FAIL
	IFDEF ESP_TCP_MUX
	XOR	A
	LD	(ASYNC_PEND),A
	ENDIF
	LD	A,RES_FAIL
	SCF
	RET
.TIMEOUT
	IFDEF ESP_TCP_MUX
	; In async mode silence between bytes is a suspension: keep the partial
	; line state (the resume entry recomputes the store pointer) and report
	; RES_AGAIN. Only sends set ASYNC_MODE; the close path and the recovery
	; probe always run this loop in blocking mode.
	LD	A,(ASYNC_MODE)
	AND	A
	JR	Z,.hard_timeout
	LD	A,1
	LD	(WSO_RESUME),A
	LD	A,2
	LD	(ASYNC_PEND),A		; 2 = awaiting SEND OK
	LD	A,RES_AGAIN
	SCF
	RET
.hard_timeout
	; Terminate whatever of the line had arrived, so a caller reporting the
	; failure can show it ("busy p..." reads very differently from nothing at
	; all). Derive the position from LINE_REMAIN rather than IX: the capture
	; helpers reached from this loop make no promise about IX.
	LD	A,TCP_LINE_SIZE-1
	LD	HL,LINE_REMAIN
	SUB	(HL)			; A = characters stored in this line
	LD	E,A
	LD	D,0
	LD	HL,LINE_BUFFER
	ADD	HL,DE
	LD	(HL),0
	ENDIF
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

	IFNDEF ESP_TCP_MUX
; ------------------------------------------------------
; SKIP_IPD_FRAME: consume the "<len>[,<ip>,<port>]:<payload>" suffix
; of a "+IPD," frame whose 5-byte prefix has already been read from
; UART. Handles single-conn (CIPDINFO=0 and =1) and mux formats by
; treating the last numeric field before ':' as the payload length.
; Returns CF=0 on success, CF=1 / A=RES_RS_TIMEOUT on UART timeout.
; Preserves no working registers (caller must save what it needs).
; ------------------------------------------------------
SKIP_IPD_FRAME
	PUSH	BC,DE,HL
	LD	HL,0
	LD	(IPD_REMOTE_LEN),HL
	XOR	A
	LD	(IPD_HAVE_REMOTE_LEN),A
.LEN_LOOP
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.TIMEOUT_POP
	CP	':'
	JR	Z,.LEN_DONE
	CP	','
	JR	Z,.NEXT_FIELD
	CP	'0'
	JR	C,.REMOTE_INFO
	CP	'9'+1
	JR	NC,.REMOTE_INFO
	SUB	'0'
	LD	E,A
	LD	D,0
	LD	B,H
	LD	C,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,BC
	ADD	HL,HL
	ADD	HL,DE
	JR	.LEN_LOOP
.NEXT_FIELD
	LD	(IPD_REMOTE_LEN),HL
	LD	A,1
	LD	(IPD_HAVE_REMOTE_LEN),A
	LD	HL,0
	JR	.LEN_LOOP
.REMOTE_INFO
	LD	A,(IPD_HAVE_REMOTE_LEN)
	AND	A
	JR	Z,.TIMEOUT_POP
.SKIP_REMOTE_INFO
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.TIMEOUT_POP
	CP	':'
	JR	NZ,.SKIP_REMOTE_INFO
	LD	HL,(IPD_REMOTE_LEN)
.LEN_DONE
	LD	A,H
	OR	L
	JR	Z,.DONE_POP
.DISCARD
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.TIMEOUT_POP
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,.DISCARD
.DONE_POP
	POP	HL,DE,BC
	XOR	A
	RET
.TIMEOUT_POP
	POP	HL,DE,BC
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
	ENDIF

	IFDEF ESP_TCP_RX_DEFER
; ======================================================
; Receive-defer window (ESP_TCP_RX_DEFER). Captures +IPD payload that races a
; SEND (arrives in the CIPSEND '>' / SEND OK window) instead of discarding it,
; and replays it to the next RECEIVE. Frames are stored back-to-back as
; {2-byte LE length, payload}. See the note near the top of this file and
; docs/UNETAPI.md. All UART reads here use READ_BYTE_TIMEOUT (no ISA window is
; held by the SEND-side callers), matching SKIP_IPD_FRAME.
; ======================================================

; Clear the whole defer window. Called on a fresh TCP/UDP open.
RX_DEFER_RESET
	LD	HL,0
	LD	(DEFER_W),HL
	LD	(DEFER_R),HL
	LD	(DEFER_FRAME_LEFT),HL
	XOR	A
	LD	(DEFER_LOST),A
	RET

; Slide the unread region [R..W) down to offset 0 so W-=R, R=0. Safe while a
; frame is partially delivered (DEFER_FRAME_LEFT!=0): R points mid-payload and
; the remaining bytes move down unchanged. Regs already saved by the caller.
DEFER_COMPACT
	LD	HL,(DEFER_R)
	LD	A,H
	OR	L
	RET	Z			; R==0: nothing to compact
	LD	DE,(DEFER_R)
	LD	HL,(DEFER_W)
	OR	A
	SBC	HL,DE			; HL = W-R = count
	LD	B,H
	LD	C,L
	LD	A,B
	OR	C
	JR	Z,.setw			; empty region, just reset offsets
	IFDEF ESP_TCP_MUX
	LD	HL,(DEFER_BASE)
	ELSE
	LD	HL,DEFER_BUF
	ENDIF
	LD	DE,(DEFER_R)
	ADD	HL,DE			; src = base+R
	IFDEF ESP_TCP_MUX
	LD	DE,(DEFER_BASE)
	ELSE
	LD	DE,DEFER_BUF		; dst = DEFER_BUF
	ENDIF
	LDIR				; forward copy, dst<src -> safe
.setw
	LD	HL,(DEFER_W)
	LD	DE,(DEFER_R)
	OR	A
	SBC	HL,DE
	LD	(DEFER_W),HL		; W -= R
	LD	HL,0
	LD	(DEFER_R),HL		; R = 0
	RET

; Store one frame of DE payload bytes read from the UART into the defer buffer.
; Compacts first. On overflow the payload is drained and discarded and
; DEFER_LOST is set. On a UART timeout the bytes that did arrive are committed
; as a shorter frame (nothing is queued when none arrived), DEFER_NEED holds
; the unread tail and CF=1 is returned - DEFER_LOST is NOT set: the caller
; decides whether it can resume that tail (see the ESP_TCP_RX_DEFER note).
; In: DE=len. Out: CF=0 ok / CF=1 UART timeout. Clobbers A,BC,DE,HL.
DEFER_STORE_FRAME
	LD	A,D
	OR	E
	RET	Z			; zero-length frame: nothing to store, CF=0
	CALL	DEFER_COMPACT
	PUSH	DE
	LD	HL,TCP_RX_DEFER_SIZE
	LD	BC,(DEFER_W)
	OR	A
	SBC	HL,BC			; HL = free bytes at end
	POP	DE
	PUSH	DE
	INC	DE
	INC	DE			; DE = len+2 (header+payload)
	OR	A
	SBC	HL,DE			; CF=1 if free < len+2
	POP	DE			; DE = len
	JR	C,.overflow
	IFDEF ESP_TCP_MUX
	LD	HL,(DEFER_BASE)
	ELSE
	LD	HL,DEFER_BUF
	ENDIF
	LD	BC,(DEFER_W)
	ADD	HL,BC			; HL = &base[W] (header)
	LD	(DEFER_FHDR),HL
	LD	(HL),E			; length lo
	INC	HL
	LD	(HL),D			; length hi
	INC	HL
	LD	(DEFER_WPTR),HL		; payload write pointer
	LD	(DEFER_NEED),DE		; bytes still to read
.loop
	LD	HL,(DEFER_NEED)
	LD	A,H
	OR	L
	JR	Z,.done
	IFDEF ESP_TCP_MUX
	CALL	MUX_READ_BYTE
	ELSE
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	ENDIF
	JR	C,.timeout
	LD	HL,(DEFER_WPTR)
	LD	(HL),A
	INC	HL
	LD	(DEFER_WPTR),HL
	LD	HL,(DEFER_NEED)
	DEC	HL
	LD	(DEFER_NEED),HL
	JR	.loop
.done
	LD	HL,(DEFER_WPTR)
	IFDEF ESP_TCP_MUX
	LD	DE,(DEFER_BASE)
	ELSE
	LD	DE,DEFER_BUF
	ENDIF
	OR	A
	SBC	HL,DE
	LD	(DEFER_W),HL		; W = WPTR - base
	XOR	A			; CF=0
	RET
.timeout
	LD	HL,(DEFER_WPTR)
	LD	DE,(DEFER_FHDR)
	OR	A
	SBC	HL,DE
	DEC	HL
	DEC	HL			; HL = actual bytes captured
	LD	A,H
	OR	L
	JR	Z,.timeout_empty	; DEFER_W untouched: no empty record queued
	EX	DE,HL
	LD	HL,(DEFER_FHDR)
	LD	(HL),E			; patch header length lo
	INC	HL
	LD	(HL),D			; patch header length hi
	LD	HL,(DEFER_WPTR)
	IFDEF ESP_TCP_MUX
	LD	DE,(DEFER_BASE)
	ELSE
	LD	DE,DEFER_BUF
	ENDIF
	OR	A
	SBC	HL,DE
	LD	(DEFER_W),HL		; commit the partial frame
.timeout_empty
	SCF
	RET
.overflow
	LD	A,1
	LD	(DEFER_LOST),A
	LD	(DEFER_NEED),DE		; drain and discard len bytes
.ovf_loop
	LD	HL,(DEFER_NEED)
	LD	A,H
	OR	L
	JR	Z,.ovf_done
	IFDEF ESP_TCP_MUX
	CALL	MUX_READ_BYTE
	ELSE
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	ENDIF
	JR	C,.ovf_timeout
	LD	HL,(DEFER_NEED)
	DEC	HL
	LD	(DEFER_NEED),HL
	JR	.ovf_loop
.ovf_done
	XOR	A			; CF=0
	RET
.ovf_timeout
	SCF				; timeout while discarding
	RET

	IFNDEF ESP_TCP_MUX
; Capture a +IPD frame whose "+IPD," prefix was already consumed, parsing the
; "<len>[,ip,port]:" header exactly like SKIP_IPD_FRAME, then storing the
; payload. Called from the SEND-side prompt/SEND-OK waits.
; Out: CF=0 ok / CF=1 A=RES_RS_TIMEOUT. Preserves BC,DE,HL (like SKIP_IPD_FRAME).
CAPTURE_IPD_FRAME
	PUSH	BC,DE,HL
	LD	HL,0			; HL = running length accumulator
	LD	(IPD_REMOTE_LEN),HL
	XOR	A
	LD	(IPD_HAVE_REMOTE_LEN),A
.len_loop
	; READ_BYTE_TIMEOUT clobbers HL (LD HL,REG_RBR), so save the accumulator
	; across the call. Flags/A/C from the read survive POP HL.
	PUSH	HL
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	POP	HL
	JR	C,.fail
	CP	':'
	JR	Z,.len_done
	CP	','
	JR	Z,.next_field
	CP	'0'
	JR	C,.remote_info
	CP	'9'+1
	JR	NC,.remote_info
	SUB	'0'
	LD	E,A
	LD	D,0
	LD	B,H
	LD	C,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,BC
	ADD	HL,HL
	ADD	HL,DE
	JR	.len_loop
.next_field
	LD	(IPD_REMOTE_LEN),HL
	LD	A,1
	LD	(IPD_HAVE_REMOTE_LEN),A
	LD	HL,0
	JR	.len_loop
.remote_info
	LD	A,(IPD_HAVE_REMOTE_LEN)
	AND	A
	JR	Z,.fail
.skip_remote
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.fail
	CP	':'
	JR	NZ,.skip_remote
	LD	HL,(IPD_REMOTE_LEN)
.len_done
	EX	DE,HL			; DE = payload length
	CALL	DEFER_STORE_FRAME
	JR	C,.store_fail
	POP	HL,DE,BC
	XOR	A
	RET
.store_fail
	; The header is gone and this path does not keep the unread tail live,
	; so the rest of the frame really is a gap.
	LD	A,1
	LD	(DEFER_LOST),A
.fail
	POP	HL,DE,BC
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; If the app left a +IPD payload unread (PAYLOAD_LEFT!=0) when it starts a SEND,
; pull those bytes into the defer buffer as one frame so the CIPSEND handshake
; is not corrupted by them (this replaces the old UART_EMPTY_RS FIFO flush,
; which would have thrown the same bytes away). PAYLOAD_LEFT is cleared only
; after the whole tail was captured; on timeout it keeps the exact unread count
; so a later receive/capture continues inside the same binary frame.
CAPTURE_PENDING_PAYLOAD
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	RET	Z			; nothing pending
	PUSH	BC,DE,HL
	LD	DE,(PAYLOAD_LEFT)
	CALL	DEFER_STORE_FRAME
	JR	C,.partial
	LD	HL,0
	LD	(PAYLOAD_LEFT),HL
	POP	HL,DE,BC
	XOR	A
	RET
.partial
	LD	HL,(DEFER_NEED)
	LD	(PAYLOAD_LEFT),HL
	POP	HL,DE,BC
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
	ENDIF

; Copy min(DEFER_FRAME_LEFT, RECV_REMAIN) bytes from the current defer read
; point into the caller buffer, updating all cursors. Pure memory move.
DEFER_EMIT
	LD	HL,(DEFER_FRAME_LEFT)
	LD	DE,(RECV_REMAIN)
	OR	A
	SBC	HL,DE			; frame - remain
	JR	C,.use_frame		; frame < remain -> n=frame
	LD	BC,(RECV_REMAIN)
	JR	.have_n
.use_frame
	LD	BC,(DEFER_FRAME_LEFT)
.have_n
	LD	A,B
	OR	C
	RET	Z			; n==0
	IFDEF ESP_TCP_MUX
	LD	HL,(DEFER_BASE)
	ELSE
	LD	HL,DEFER_BUF
	ENDIF
	LD	DE,(DEFER_R)
	ADD	HL,DE			; src = base+R
	LD	DE,(RECV_PTR)		; dst
	PUSH	BC
	LDIR
	LD	(RECV_PTR),DE		; dst advanced by n
	POP	BC
	LD	HL,(DEFER_R)
	ADD	HL,BC
	LD	(DEFER_R),HL		; R += n
	LD	HL,(DEFER_FRAME_LEFT)
	OR	A
	SBC	HL,BC
	LD	(DEFER_FRAME_LEFT),HL	; frame -= n
	LD	HL,(RECV_REMAIN)
	OR	A
	SBC	HL,BC
	LD	(RECV_REMAIN),HL	; remain -= n
	LD	HL,(RECV_STORED)
	ADD	HL,BC
	LD	(RECV_STORED),HL	; stored += n
	RET

; Deliver buffered defer bytes into the caller's RECV buffer (RECV_PTR /
; RECV_REMAIN / RECV_STORED already latched by RECEIVE). Greedy fill mirroring
; the live back-to-back path: finish a partial frame, then whole frames while
; space remains; a frame larger than the space is delivered partially with the
; tail kept in DEFER_FRAME_LEFT. Out: A=0, CF=0, BC=stored.
RECEIVE_FROM_DEFER
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JR	Z,.frames
	CALL	DEFER_EMIT
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.return		; buffer filled mid-frame
.frames
	LD	HL,(RECV_REMAIN)
	LD	A,H
	OR	L
	JR	Z,.return		; caller buffer full
	LD	HL,(DEFER_R)
	LD	DE,(DEFER_W)
	OR	A
	SBC	HL,DE			; R-W; CF=1 while R<W (frames remain)
	JR	NC,.return		; R>=W: empty
	IFDEF ESP_TCP_MUX
	LD	HL,(DEFER_BASE)
	ELSE
	LD	HL,DEFER_BUF
	ENDIF
	LD	DE,(DEFER_R)
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = next frame length
	LD	(DEFER_FRAME_LEFT),DE
	LD	HL,(DEFER_R)
	INC	HL
	INC	HL
	LD	(DEFER_R),HL		; step past 2-byte header
	CALL	DEFER_EMIT
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JR	Z,.frames		; frame fully emitted: next frame
.return
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.keep		; mid-frame: keep cursors
	LD	HL,(DEFER_R)
	LD	DE,(DEFER_W)
	OR	A
	SBC	HL,DE
	JR	C,.keep			; R<W: frames still queued
	LD	HL,0
	LD	(DEFER_R),HL
	LD	(DEFER_W),HL		; fully drained: reset to front
.keep
	LD	BC,(RECV_STORED)
	XOR	A
	RET
	ENDIF

	IFDEF ESP_TCP_MUX
; ======================================================
; Two-channel (AT+CIPMUX=1) receive demultiplexer.
;
; ESP-AT reports link-scoped events once CIPMUX=1 is active:
;     +IPD,<link>,<len>:<payload>      data for one link
;     <link>,CLOSED                    that link's peer closed
;     <link>,CONNECT / <link>,SEND OK  command chatter
; A caller reads one channel at a time, but the UART carries both. A frame that
; belongs to the channel not being read is copied into that channel's own
; receive-defer window and handed over on the next read of that channel, so
; stream order per channel is preserved and nothing is lost while, say, an FTP
; control reply arrives in the middle of a data transfer.
;
; The byte reader is indirect (MUX_READ_VEC) because the same parsing code runs
; from two contexts: the CIPSEND handshake, where no ISA window is held, and
; RECEIVE_MUX, which keeps the window open for the whole burst. It is also the
; seam the host-side harness uses to feed scripted bytes.
; ======================================================

; Append the current link id to the command being built at HL, leaving HL on the
; new terminator exactly like APPEND_STR.
APPEND_LINK_ID
	LD	A,(LINK_ID)
	ADD	A,'0'
	LD	(HL),A
	INC	HL
	LD	(HL),0
	RET

; Select the reader used by the parsing/stashing helpers.
MUX_USE_SEND_READER
	LD	HL,MUX_SEND_READER
	LD	(MUX_READ_VEC),HL
	RET

; Select the fast reader while the caller holds the ISA window open. Both the
; response line and a possible immediate +IPD burst are drained without two
; ISA bank switches per byte.
MUX_USE_SEND_OPEN_READER
	LD	HL,MUX_SEND_OPEN_READER
	LD	(MUX_READ_VEC),HL
	RET

MUX_USE_RECV_READER
	LD	HL,READ_BYTE_RECV_TIMEOUT_OPEN
	LD	(MUX_READ_VEC),HL
	RET

; Keep the ISA window open for a complete command-response wait. This removes
; two bank switches per response byte and lets CONNECT lower RTS before the
; immediately following +IPD burst overruns the 16550 FIFO.
MUX_WAIT_BEGIN
	CALL	ISA.ISA_OPEN
	LD	A,1
	LD	(MUX_WINDOW_OPEN),A
	JP	MUX_USE_SEND_OPEN_READER

MUX_WAIT_END
	PUSH	AF
	XOR	A
	LD	(MUX_WINDOW_OPEN),A
	CALL	ISA.ISA_CLOSE
	CALL	MUX_USE_SEND_READER
	POP	AF
	RET

MUX_WAIT_PROMPT
	CALL	MUX_WAIT_BEGIN
	CALL	WAIT_PROMPT
	JP	MUX_WAIT_END

MUX_WAIT_SEND_OK
	CALL	MUX_WAIT_BEGIN
	CALL	WAIT_SEND_OK
	JP	MUX_WAIT_END

MUX_SEND_READER
	LD	BC,TCP_DEFAULT_TIMEOUT
	JP	READ_BYTE_TIMEOUT

MUX_SEND_OPEN_READER
	LD	BC,TCP_DEFAULT_TIMEOUT
	JP	READ_BYTE_TIMEOUT_OPEN

; Read one byte through the selected reader. Out: CF=0/A=byte, CF=1 on timeout.
; Does not preserve HL (READ_BYTE_TIMEOUT clobbers it); callers save it.
MUX_READ_BYTE
	LD	HL,(MUX_READ_VEC)
	JP	(HL)

; Read a decimal field. Out: CF=0, HL=value, MUX_DELIM=terminating character.
;      CF=1/A=RES_RS_TIMEOUT on UART timeout.
MUX_READ_DEC
	LD	HL,0
.LOOP
	PUSH	HL
	CALL	MUX_READ_BYTE
	POP	HL
	RET	C
	LD	(MUX_DELIM),A
	CP	'0'
	JR	C,.DONE
	CP	'9'+1
	JR	NC,.DONE
	SUB	'0'
	LD	E,A
	LD	D,0
	LD	B,H
	LD	C,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,BC
	ADD	HL,HL
	ADD	HL,DE			; HL = HL*10 + digit
	JR	.LOOP
.DONE
	XOR	A
	RET

; Parse "<link>,<len>:" (or "<link>,<len>,<ip>,<port>:" if CIPDINFO=1 was left
; on) after the "+IPD," prefix has been consumed.
; Out: CF=0, MUX_FRAME_LINK = owning CHANNEL (already mapped through
; MAP_LINK_TO_CH; 0xFF if the link belongs to neither channel) / MUX_FRAME_LEN
; set. CF=1/A=result code on error.
MUX_PARSE_IPD_HDR
	CALL	MUX_READ_DEC
	RET	C
	LD	A,H
	AND	A
	JR	NZ,.BAD
	LD	A,L
	CP	TCP_MUX_MAX_LINK+1
	JR	NC,.BAD
	CALL	MAP_LINK_TO_CH
	LD	(MUX_FRAME_LINK),A
	LD	A,(MUX_DELIM)
	CP	','
	JR	NZ,.BAD
	CALL	MUX_READ_DEC
	RET	C
	LD	(MUX_FRAME_LEN),HL
	LD	A,(MUX_DELIM)
	CP	':'
	JR	Z,.OK
	CP	','
	JR	NZ,.BAD
.SKIP_REMOTE
	CALL	MUX_READ_BYTE
	RET	C
	CP	':'
	JR	NZ,.SKIP_REMOTE
.OK
	XOR	A
	RET
.BAD
	LD	A,RES_ERROR
	SCF
	RET

; ------------------------------------------------------
; Per-channel receive-defer windows.
; The working cursors (DEFER_W/DEFER_R/DEFER_FRAME_LEFT/DEFER_LOST) always hold
; the selected channel's context; switching swaps them with the saved copy and
; repoints DEFER_BASE at that channel's buffer, so every proven defer routine
; keeps working unchanged on whichever channel is selected.
; ------------------------------------------------------
; In: A = channel. Preserves nothing.
DEFER_SELECT
	LD	HL,DEFER_CUR_CH
	CP	(HL)
	RET	Z
	PUSH	AF
	LD	A,(DEFER_CUR_CH)
	CALL	MUX_CTX_ADDR
	EX	DE,HL			; DE = &ctx[current]
	LD	HL,DEFER_W
	LD	BC,DEFER_CTX_SIZE
	LDIR				; save working set
	POP	AF
	LD	(DEFER_CUR_CH),A
	CALL	MUX_CTX_ADDR		; HL = &ctx[new]
	LD	DE,DEFER_W
	LD	BC,DEFER_CTX_SIZE
	LDIR				; load working set
	JP	MUX_SET_BASE

; In: A = channel. Out: HL = &DEFER_CTX[channel].
MUX_CTX_ADDR
	LD	L,A
	LD	H,0
	LD	D,H
	LD	E,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	ADD	HL,DE
	ADD	HL,DE			; HL = channel*7
	LD	DE,DEFER_CTX
	ADD	HL,DE
	RET

; Point DEFER_BASE at the selected channel's buffer (two channels by design).
MUX_SET_BASE
	LD	A,(DEFER_CUR_CH)
	LD	HL,DEFER_BUF0
	AND	A
	JR	Z,.SET
	LD	DE,TCP_RX_DEFER_SIZE
	ADD	HL,DE
.SET
	LD	(DEFER_BASE),HL
	RET

; Clear one channel's window (a fresh link must not replay old peer data).
; In: A = channel.
RX_DEFER_RESET_CH
	CALL	DEFER_SELECT
	JP	RX_DEFER_RESET

; Clear every channel's window plus the shared live-frame state. Called when the
; session is (re)initialised.
RX_DEFER_RESET_ALL
	XOR	A
	LD	(DEFER_CUR_CH),A
	CALL	MUX_SET_BASE
	CALL	RX_DEFER_RESET		; working set = channel 0
	LD	HL,DEFER_CTX
	LD	DE,DEFER_CTX+1
	LD	BC,TCP_MUX_CHANNELS*DEFER_CTX_SIZE-1
	LD	(HL),0
	LDIR
	LD	HL,0
	LD	(PAYLOAD_LEFT),HL
	XOR	A
	LD	(MUX_CLOSED_MASK),A
	LD	A,0xFF
	LD	(MUX_PAYLOAD_LINK),A
	RET

; ------------------------------------------------------
; LISTEN link<->channel mapping (UNET_CAP_LISTEN). Every wire-level "link"
; parsed off the ESP is translated to a "channel" through here before it
; reaches channel-space code (RECEIVE_MUX, MUX_LATCH_CLOSED, ...): normally
; link==channel (the identity the rest of this file assumed before LISTEN
; existed), but an accepted inbound connection can land on any free firmware
; link id, so MUX_LINK_MAP records the actual mapping once one is chosen.
; ------------------------------------------------------
; In: A = channel (0..TCP_MUX_CHANNELS-1). Out: HL = &MUX_LINK_MAP[channel].
MUX_LINK_MAP_ADDR
	LD	HL,MUX_LINK_MAP
	LD	D,0
	LD	E,A
	ADD	HL,DE
	RET

; In: A = firmware link id. Out: A = channel owning it, or 0xFF if none does.
; A link present in MUX_LINK_MAP always resolves to its owner. A link absent
; from the map falls back to identity (link==channel) when the link itself is
; a valid channel index - the common case, since MUX_ALLOC_LINK keeps that
; identity whenever it is free - and to 0xFF otherwise (a genuinely foreign
; link, or a channel-range id some OTHER channel does not currently hold).
MAP_LINK_TO_CH
	PUSH	BC,DE,HL
	LD	E,A			; E = link to find
	LD	HL,MUX_LINK_MAP
	LD	D,0			; D = channel index while scanning
.scan
	LD	A,D
	CP	TCP_MUX_CHANNELS
	JR	NC,.fallback
	LD	A,(HL)
	CP	E
	JR	Z,.found
	INC	HL
	INC	D
	JR	.scan
.found
	LD	A,D
	POP	HL,DE,BC
	RET
.fallback
	LD	A,E
	CP	TCP_MUX_CHANNELS
	JR	NC,.none
	; Identity is only trustworthy while channel E itself is unmapped: if
	; channel E is bound to a DIFFERENT link (its inbound accept landed on a
	; foreign id), a stray wire id E must not resolve to that live channel.
	CALL	MUX_LINK_MAP_ADDR	; A==E on entry; E itself survives the call
	LD	A,(HL)
	CP	0xFF
	JR	NZ,.none
	LD	A,E
	POP	HL,DE,BC
	RET				; A = E: identity, unclaimed by any channel
.none
	LD	A,0xFF
	POP	HL,DE,BC
	RET

; Choose the firmware link id for a channel about to CIPSTART, preferring
; identity (link==channel) and falling back to the first id 0..TCP_MUX_MAX_LINK
; not already claimed by MUX_LINK_MAP (an accepted inbound connection may be
; squatting on this channel's identity slot). Writes both MUX_LINK_MAP[channel]
; and TCP.LINK_ID.
; In: A = channel about to open (currently closed).
MUX_ALLOC_LINK
	PUSH	BC,DE,HL
	; C, not D, holds "channel" here: MUX_LINK_MAP_ADDR clobbers D/E (it uses
	; them as the 16-bit offset for ADD HL,DE), so D cannot survive a call to
	; it. .claimed below preserves the whole BC pair around its own DJNZ use
	; of B, so C survives every call in this routine.
	LD	C,A			; C = channel
	; Release whatever this channel held before opening (a stale identity
	; left over from its own last open/close), so re-opening the same channel
	; still prefers identity instead of tripping over its own old entry.
	CALL	MUX_LINK_MAP_ADDR
	LD	(HL),0xFF
	LD	E,C			; E = candidate link, starts at identity
	CALL	.claimed
	JR	NC,.have		; identity is free
	XOR	A
.try
	LD	E,A
	CALL	.claimed
	JR	NC,.have
	INC	A
	CP	TCP_MUX_MAX_LINK+1
	JR	C,.try
	; Exhausted 0..TCP_MUX_MAX_LINK (should not happen: CIPSERVERMAXCONN=1
	; plus our own channel count bound the concurrent link count well under
	; that range) - fall back to identity rather than leaving LINK_ID stale.
	LD	E,C
.have
	LD	B,E			; B = chosen link: MUX_LINK_MAP_ADDR is about
					; to clobber E (only visible off-identity,
					; where E differs from the channel in C)
	LD	A,C
	CALL	MUX_LINK_MAP_ADDR
	LD	(HL),B
	LD	A,B
	LD	(LINK_ID),A
	POP	HL,DE,BC
	RET
; In: E = candidate link. Out: CF=1 if some channel's map entry already
; equals E. Preserves BC (incl. the caller's C = channel), D/E.
.claimed
	PUSH	AF,BC,DE
	; A link whose CIPCLOSE went unconfirmed may still be open on the ESP:
	; CIPSTART on it would fail with ALREADY CONNECTED, so skip it too.
	LD	A,E
	CALL	MUX_LINK_BIT
	LD	B,A
	LD	A,(MUX_STALE_LINKS)
	AND	B
	JR	NZ,.yes
	LD	HL,MUX_LINK_MAP
	LD	B,TCP_MUX_CHANNELS
.cloop
	LD	A,(HL)
	CP	E
	JR	Z,.yes
	INC	HL
	DJNZ	.cloop
	POP	DE,BC,AF
	OR	A			; CF=0
	RET
.yes
	POP	DE,BC,AF
	SCF
	RET

; Remember a link whose AT+CIPCLOSE was not confirmed: the channel is released
; locally, but the ESP may still hold the link open. MUX_ALLOC_LINK avoids it
; until a CIPCLOSE=5 sweep (NETDONE, NETINIT, or the next open while no
; channel is up) clears MUX_STALE_LINKS, or an inbound CONNECT lands on it.
; In: A = firmware link id. Preserves every register.
MUX_MARK_STALE_LINK
	PUSH	AF,BC
	CALL	MUX_LINK_BIT
	LD	B,A
	LD	A,(MUX_STALE_LINKS)
	OR	B
	LD	(MUX_STALE_LINKS),A
	POP	BC,AF
	RET

; The ESP proved link A is free again (it announced "<link>,CONNECT" on it).
; In: A = firmware link id. Preserves every register.
MUX_CLEAR_STALE_LINK
	PUSH	AF,BC
	CALL	MUX_LINK_BIT
	CPL
	LD	B,A
	LD	A,(MUX_STALE_LINKS)
	AND	B
	LD	(MUX_STALE_LINKS),A
	POP	BC,AF
	RET

; In: A = channel (already validated open). Out: TCP.LINK_ID = the channel's
; mapped link; CF=1/A=RES_ERROR if the channel has no mapped link (should not
; happen for a channel MUX_ALLOC_LINK/MUX_TRY_ACCEPT actually opened, but an
; AT+CIPCLOSE/CIPSEND must never fire with a stale/garbage link digit).
SET_LINK_FROM_MAP
	CALL	MUX_LINK_MAP_ADDR
	LD	A,(HL)
	CP	0xFF
	JR	Z,.none
	LD	(LINK_ID),A
	XOR	A
	RET
.none
	LD	A,RES_ERROR
	SCF
	RET

; Claim a spontaneous "<link>,CONNECT" for the armed listening channel.
; Silently ignored (not an error) when disarmed, the link looks wrong (no
; digit prefix, or out of the firmware's id range), the link is already
; claimed by some channel's map entry (a stray repeat, or a foreign link that
; happens to share a digit), or this listening channel already has an
; accepted connection (CIPSERVERMAXCONN=1 keeps this a defensive check, not
; the primary limit).
; In: A = link id claiming CONNECT (0xFF if no digit prefix was seen).
MUX_TRY_ACCEPT
	PUSH	AF,BC,HL
	CP	0xFF
	JR	Z,.done
	CP	TCP_MUX_MAX_LINK+1
	JR	NC,.done
	LD	C,A			; C = candidate link
	LD	A,(MUX_LISTEN_CH)
	CP	0xFF
	JR	Z,.done
	LD	B,A			; B = listening channel
	CALL	MUX_LINK_MAP_ADDR
	LD	A,(HL)
	CP	0xFF
	JR	NZ,.done		; already has an accepted connection
	LD	HL,MUX_LINK_MAP
	LD	A,(HL)
	CP	C
	JR	Z,.done
	INC	HL
	LD	A,(HL)
	CP	C
	JR	Z,.done
	LD	A,B
	CALL	MUX_LINK_MAP_ADDR
	LD	(HL),C
	; The firmware only hands out a free id: an unconfirmed close of this
	; link (if any) evidently went through after all.
	LD	A,C
	CALL	MUX_CLEAR_STALE_LINK
	; A fresh accepted connection must not replay a previous one's stale
	; peer-close latch or buffered payload (LISTEN can re-arm the same
	; channel many times).
	LD	A,B
	CALL	MUX_CLEAR_CLOSED
	LD	A,B
	CALL	RX_DEFER_RESET_CH
.done
	POP	HL,BC,AF
	RET

; ------------------------------------------------------
; Peer-close bookkeeping. A "<link>,CLOSED" can be seen while reading the other
; channel or in the middle of a send, so it is latched per link and consumed
; later by the channel it belongs to.
; ------------------------------------------------------
; In: A = link. Out: A = 1<<link.
MUX_LINK_BIT
	PUSH	BC
	LD	B,A
	LD	A,1
	INC	B
.SHIFT
	DEC	B
	JR	Z,.DONE
	ADD	A,A
	JR	.SHIFT
.DONE
	POP	BC
	RET

; In: A = link.
MUX_LATCH_CLOSED
	CP	TCP_MUX_CHANNELS
	RET	NC
	CALL	MUX_LINK_BIT
	LD	HL,MUX_CLOSED_MASK
	OR	(HL)
	LD	(HL),A
	RET

; In: A = channel.
MUX_CLEAR_CLOSED
	CP	TCP_MUX_CHANNELS
	RET	NC
	CALL	MUX_LINK_BIT
	CPL
	LD	HL,MUX_CLOSED_MASK
	AND	(HL)
	LD	(HL),A
	RET

; In: A = channel. Out: CF=1 when a peer close is latched for it.
MUX_IS_CLOSED
	CALL	MUX_LINK_BIT
	LD	HL,MUX_CLOSED_MASK
	AND	(HL)
	RET	Z			; CF=0: not closed
	SCF
	RET

; In: A = channel. Out: CF=1 when undelivered received data is buffered for it.
; May change the selected channel (harmless: contexts are complete).
MUX_HAS_PENDING
	PUSH	BC
	LD	C,A
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	Z,.STASH
	LD	A,(MUX_PAYLOAD_LINK)
	CP	C
	JR	Z,.YES
.STASH
	LD	A,C
	CALL	DEFER_SELECT
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.YES
	LD	HL,(DEFER_R)
	LD	DE,(DEFER_W)
	OR	A
	SBC	HL,DE			; CF=1 while R<W (frames queued)
	POP	BC
	RET
.YES
	POP	BC
	SCF
	RET

; ------------------------------------------------------
; Stash helpers. Bytes are read from the UART through the selected reader, so
; the payload is consumed either way; only its destination differs.
; ------------------------------------------------------
; Stash the payload of the frame just parsed by MUX_PARSE_IPD_HDR. It becomes
; the live payload first, so a mid-frame timeout leaves its owner and exact
; unread tail behind (like any other partial +IPD) instead of an untracked
; binary tail the next scan would mistake for text.
MUX_STASH_FRAME
	LD	A,(MUX_FRAME_LINK)
	LD	(MUX_PAYLOAD_LINK),A
	LD	HL,(MUX_FRAME_LEN)
	LD	(PAYLOAD_LEFT),HL
	; fall through
; Stash the unread tail of the live payload. Forget it only after the complete
; tail was consumed; otherwise preserve the exact remainder so no later AT
; command can be injected into binary +IPD data. The stored prefix is a
; pause, not a gap: DEFER_LOST stays clear.
MUX_STASH_PARTIAL
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	RET	Z
	LD	A,(MUX_PAYLOAD_LINK)
	CALL	MUX_STASH_LEN
	JR	C,.PARTIAL
	LD	HL,0
	LD	(PAYLOAD_LEFT),HL
	XOR	A
	RET
.PARTIAL
	LD	HL,(DEFER_NEED)
	LD	(PAYLOAD_LEFT),HL
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; In: A = owner channel, HL = payload length. Restores the previously selected
; channel before returning. Out: CF=0 ok, CF=1 on UART timeout.
MUX_STASH_LEN
	LD	B,A			; B = owner channel
	LD	A,(DEFER_CUR_CH)
	LD	C,A			; C = channel to restore afterwards
	PUSH	BC
	PUSH	HL			; DEFER_SELECT clobbers HL: keep the length
	LD	A,B
	CP	TCP_MUX_CHANNELS
	JR	NC,.DISCARD		; link outside our channel set: drop it
	CALL	DEFER_SELECT
	POP	DE			; DE = payload length
	CALL	DEFER_STORE_FRAME
.RESTORE
	POP	BC
	PUSH	AF
	LD	A,C
	CALL	DEFER_SELECT
	POP	AF
	RET
.DISCARD
	; Unknown link: consume the payload so the stream stays framed.
	POP	HL
.DLOOP
	LD	A,H
	OR	L
	JR	Z,.DDONE
	PUSH	HL
	CALL	MUX_READ_BYTE
	POP	HL
	JR	NC,.DGOT
	LD	(DEFER_NEED),HL		; expose the unread tail to the caller
	JR	.RESTORE
.DGOT
	DEC	HL
	JR	.DLOOP
.DDONE
	XOR	A
	JR	.RESTORE

; Capture a "+IPD," frame that raced the CIPSEND/CIPSTART handshake (prefix
; already consumed by WAIT_PROMPT / WAIT_SEND_OK). Reuse the command wait's
; open ISA window, or open one for a legacy direct caller, for the complete
; header+payload burst. The old per-byte open/close reader could not sustain
; 115200 baud and truncated an early frame before the application's first RECV.
; Out: CF=0 ok / CF=1 A=RES_RS_TIMEOUT. Preserves BC,DE,HL.
MUX_CAPTURE_IPD_FRAME
	PUSH	BC,DE,HL
	LD	A,(MUX_WINDOW_OPEN)
	AND	A
	JR	NZ,.ALREADY_OPEN
	CALL	ISA.ISA_OPEN
	CALL	MUX_USE_SEND_OPEN_READER
.ALREADY_OPEN
	CALL	MUX_PARSE_IPD_HDR
	JR	C,.PARSE_FAIL
	CALL	MUX_STASH_FRAME		; a timeout leaves the exact live tail behind
	JR	C,.PARSE_FAIL
	CALL	.CLOSE_READER
	POP	HL,DE,BC
	XOR	A
	RET
.PARSE_FAIL
	CALL	.CLOSE_READER
	POP	HL,DE,BC
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
.CLOSE_READER
	PUSH	AF
	LD	A,(MUX_WINDOW_OPEN)
	AND	A
	JR	NZ,.CLOSE_DONE
	CALL	ISA.ISA_CLOSE
	CALL	MUX_USE_SEND_READER
.CLOSE_DONE
	POP	AF
	RET

; Rescue a payload the app left unread when it starts a SEND, into the window of
; the channel that owns it.
MUX_CAPTURE_PENDING_PAYLOAD
	CALL	MUX_RESUME_CONNECT_RX
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	RET	Z
	PUSH	BC,DE,HL
	CALL	ISA.ISA_OPEN
	CALL	MUX_USE_SEND_OPEN_READER
	CALL	MUX_STASH_PARTIAL
	PUSH	AF
	CALL	ISA.ISA_CLOSE
	CALL	MUX_USE_SEND_READER
	POP	AF
	POP	HL,DE,BC
	RET

; Resume the internal post-CONNECT pause exactly once. This pause is distinct
; from the public RXPAUSE option: top-level DLL guards already reject network
; operations while the consumer's explicit pause is active.
MUX_RESUME_CONNECT_RX
	LD	A,(MUX_CONNECT_PAUSED)
	AND	A
	RET	Z
	XOR	A
	LD	(MUX_CONNECT_PAUSED),A
	JP	WIFI.UART_RX_RESUME

; Variant for RECEIVE_MUX after it has opened ISA window 3. The helper raises
; RTS and returns directly into the live drain path, with no nested bank switch.
MUX_RESUME_CONNECT_RX_OPEN
	LD	A,(MUX_CONNECT_PAUSED)
	AND	A
	RET	Z
	XOR	A
	LD	(MUX_CONNECT_PAUSED),A
	JP	WIFI.UART_RX_RESUME_OPEN

; ------------------------------------------------------
; Split a response line into an optional "<link>," prefix and the rest.
; Out: MUX_LINE_PTR = text to match, MUX_LINE_LINK = link id (0xFF if absent).
; ------------------------------------------------------
MUX_LINE_STRIP
	LD	HL,LINE_BUFFER
	LD	(MUX_LINE_PTR),HL
	LD	A,0xFF
	LD	(MUX_LINE_LINK),A
	LD	A,(LINE_BUFFER)
	CP	'0'
	RET	C
	CP	'9'+1
	RET	NC
	LD	HL,LINE_BUFFER+1
	LD	A,(HL)
	CP	','
	RET	NZ
	INC	HL
	LD	(MUX_LINE_PTR),HL
	LD	A,(LINE_BUFFER)
	SUB	'0'
	LD	(MUX_LINE_LINK),A
	RET

; ------------------------------------------------------
; Scan the UART stream for "+IPD,", "<link>,CLOSED", or - only while a channel
; is listening (UNET_CAP_LISTEN) - a spontaneous "<link>,CONNECT".
; Out: CF=0 on a +IPD header (prefix consumed).
;      CF=1/A=RES_NOT_CONN on a close notification, MUX_CLOSED_LINK = link id
;      (0xFF when the stream carried no "<digit>," prefix).
;      CF=1/A=RES_CONN_EVT on an inbound CONNECT, MUX_CONNECT_LINK = link id.
;      CF=1/A=RES_RS_TIMEOUT on timeout.
; ------------------------------------------------------
WAIT_IPD_HEADER_MUX
	LD	IX,IPD_PREFIX
	LD	IY,CLOSED_PREFIX
	LD	HL,MSG_CONNECT_LN
	LD	(MUX_CONN_PTR),HL
	LD	A,0xFF
	LD	(MUX_CAND),A
	XOR	A
	LD	(MUX_B1),A
	LD	(MUX_B2),A
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JP	C,.TIMEOUT
	LD	E,A
	; "CLOSED"/"CONNECT" both start only at a 'C', so the link id, if any, is
	; the digit two bytes back. Compute that into the PENDING slot from the
	; pre-shift history, then shift; a later fresh-start match commits it into
	; MUX_CAND. Splitting compute (here, unconditional on every 'C') from
	; commit (only at a confirmed match start) matters because "CONNECT" has
	; a SECOND 'C' at position 5 ("conNECt") that must not recompute the
	; candidate mid-match and clobber the one captured at the real start.
	CP	'C'
	CALL	Z,MUX_SNAP_PENDING
	CALL	MUX_SHIFT_BYTES
	LD	A,(IX+0)
	CP	E
	JR	NZ,.RESET
	INC	IX
	LD	A,(IX+0)
	AND	A
	JR	Z,.OK
	JR	.CHECK_CLOSED
.RESET
	LD	IX,IPD_PREFIX
	LD	A,E
	CP	'+'
	JR	NZ,.CHECK_CLOSED
	INC	IX
	JR	.CHECK_CLOSED
.CHECK_CLOSED
	LD	A,(IY+0)
	CP	E
	JR	NZ,.CLOSED_RESET
	; "CLOSED" has exactly one 'C', at position 0, so A==E=='C' here can only
	; mean CLOSED itself is starting fresh - but this same byte can also be
	; CONNECT's own internal 'C' (position 5, "conNECt") while a CONNECT match
	; is genuinely in progress; MAYBE_COMMIT_CLOSED suppresses the commit then.
	CP	'C'
	CALL	Z,MAYBE_COMMIT_CLOSED
	INC	IY
	LD	A,(IY+0)
	AND	A
	JR	Z,.CLOSED
	JR	.CHECK_CONNECT
.CLOSED_RESET
	LD	IY,CLOSED_PREFIX
	LD	A,E
	CP	'C'
	JR	NZ,.CHECK_CONNECT
	CALL	MAYBE_COMMIT_CLOSED
	INC	IY
	; fall through: CLOSED and CONNECT share their first letter, so both
	; matchers must see this byte.
.CHECK_CONNECT
	; Disarmed is the overwhelmingly common case (every byte outside a
	; LISTEN session): one flag test and back to .NEXT.
	LD	A,(MUX_LISTEN_CH)
	CP	0xFF
	JR	Z,.NEXT
	LD	HL,(MUX_CONN_PTR)
	LD	A,(HL)
	CP	E
	JR	NZ,.CONN_RESET
	; Unlike CLOSED, "CONNECT" has a SECOND 'C' at position 5 ("conNECt"), so
	; "byte == 'C'" alone cannot tell a fresh start from mid-match progress:
	; compare the pointer itself against the string's own first byte.
	LD	A,H
	CP	HIGH MSG_CONNECT_LN
	JR	NZ,.CONN_ADVANCE
	LD	A,L
	CP	LOW MSG_CONNECT_LN
	JR	NZ,.CONN_ADVANCE
	CALL	MUX_COMMIT_CAND
.CONN_ADVANCE
	INC	HL
	LD	(MUX_CONN_PTR),HL
	LD	A,(HL)
	AND	A
	JR	Z,.CONNECT_HIT
	JR	.NEXT
.CONN_RESET
	LD	HL,MSG_CONNECT_LN
	LD	A,E
	CP	'C'
	JR	NZ,.CONN_STORE
	CALL	MUX_COMMIT_CAND
	INC	HL
.CONN_STORE
	LD	(MUX_CONN_PTR),HL
	JP	.NEXT
.CONNECT_HIT
	LD	A,(MUX_CAND)
	LD	(MUX_CONNECT_LINK),A
	LD	A,RES_CONN_EVT
	SCF
	RET
.OK
	XOR	A
	RET
.CLOSED
	LD	A,(MUX_CAND)
	LD	(MUX_CLOSED_LINK),A
	LD	A,RES_NOT_CONN
	SCF
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; Compute the digit two bytes back from the 'C' just read (pre-shift history)
; into MUX_PENDING_CAND. Called unconditionally on every 'C', including
; "CONNECT"'s internal one at position 5 - MUX_COMMIT_CAND is what actually
; publishes a value to MUX_CAND, only at a confirmed match start, so an
; internal 'C' recomputing PENDING here is harmless: nothing has read it yet.
; Preserve E, IX and IY: this runs inside the scan loop.
MUX_SNAP_PENDING
	LD	A,(MUX_B2)
	CP	','
	JR	NZ,.NONE
	LD	A,(MUX_B1)
	CP	'0'
	JR	C,.NONE
	CP	'9'+1
	JR	NC,.NONE
	SUB	'0'
	LD	(MUX_PENDING_CAND),A
	RET
.NONE
	LD	A,0xFF
	LD	(MUX_PENDING_CAND),A
	RET

; Publish the last computed PENDING candidate as MUX_CAND. Called only where
; a match is confirmed to be starting fresh at position 0.
MUX_COMMIT_CAND
	LD	A,(MUX_PENDING_CAND)
	LD	(MUX_CAND),A
	RET

; CLOSED's own fresh-start detection ("IY at position 0 and this byte is 'C'")
; cannot by itself tell a real "<link>,CLOSED" start from CONNECT's internal
; 'C' at position 5, because IY keeps returning to position 0 on every byte
; that fails to continue "CLOSED" (which every byte of "CONNECT" does). Only
; commit when CONNECT is not genuinely mid-match, i.e. MUX_CONN_PTR is still
; sitting at its own start.
MAYBE_COMMIT_CLOSED
	LD	HL,(MUX_CONN_PTR)
	LD	A,H
	CP	HIGH MSG_CONNECT_LN
	RET	NZ
	LD	A,L
	CP	LOW MSG_CONNECT_LN
	RET	NZ
	JP	MUX_COMMIT_CAND

MUX_SHIFT_BYTES
	LD	A,(MUX_B2)
	LD	(MUX_B1),A
	LD	A,E
	LD	(MUX_B2),A
	RET

; ------------------------------------------------------
; Receive from one channel.
; In: A - channel, HL - destination, BC - max bytes, DE - timeout ms.
; Out: CF=0/A=0/BC=stored bytes. BC=0 means "nothing for this channel yet":
;        either the timeout expired or a frame for the other channel was
;        stashed, which returns immediately so the caller can switch channels
;        instead of blocking behind the other channel's stream.
;      CF=1/A=RES_NOT_CONN once this channel's peer closed and everything it
;        had already received has been delivered.
;      CF=1/A=result code on timeout with nothing buffered, or protocol error.
; ------------------------------------------------------
RECEIVE_MUX
	LD	(RECV_CH),A
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	(RECV_FULL_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL

	; Stashed data predates anything still on the wire: replay it first.
	LD	A,(RECV_CH)
	CALL	DEFER_SELECT
	LD	HL,(DEFER_FRAME_LEFT)
	LD	A,H
	OR	L
	JP	NZ,RECEIVE_FROM_DEFER
	LD	HL,(DEFER_R)
	LD	DE,(DEFER_W)
	OR	A
	SBC	HL,DE			; R-W; CF=1 while R<W (frames queued)
	JP	C,RECEIVE_FROM_DEFER

	; A close seen earlier is reported only now that the stash is empty.
	LD	A,(RECV_CH)
	CALL	MUX_IS_CLOSED
	JR	NC,.LIVE
	LD	A,RES_NOT_CONN
	SCF
	RET
.LIVE
	; While a send transaction is suspended the UART stream belongs to it:
	; scanning live here would consume its '>' / SEND OK. Only already
	; buffered data was served above; report idle immediately.
	LD	A,(ASYNC_PEND)
	AND	A
	JR	Z,.LIVE_OPEN
	LD	BC,0
	XOR	A
	RET
.LIVE_OPEN
	CALL	ISA.ISA_OPEN
	CALL	WIFI.UART_SET_DATA_RX_MODE_OPEN
	CALL	MUX_RESUME_CONNECT_RX_OPEN
	CALL	MUX_USE_RECV_READER
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	Z,.SCAN
	LD	A,(MUX_PAYLOAD_LINK)
	LD	HL,RECV_CH
	CP	(HL)
	JP	Z,.CONTINUE_PAYLOAD
	CALL	MUX_STASH_PARTIAL	; belongs to the other channel
	JP	C,.FAIL_STORED
.SCAN
	CALL	WAIT_IPD_HEADER_MUX
	JR	C,.SCAN_FAIL
	CALL	MUX_PARSE_IPD_HDR
	JP	C,.FAIL_STORED
	LD	A,(MUX_FRAME_LINK)
	LD	HL,RECV_CH
	CP	(HL)
	JR	Z,.OWN_FRAME
	CALL	MUX_STASH_FRAME
	JP	C,.FAIL_STORED
	JP	.RETURN_STORED		; hand control back; caller switches channel
.OWN_FRAME
	LD	HL,(MUX_FRAME_LEN)
	LD	(PAYLOAD_LEFT),HL
	LD	A,(MUX_FRAME_LINK)
	LD	(MUX_PAYLOAD_LINK),A
.CONTINUE_PAYLOAD
	CALL	READ_PAYLOAD
	JP	C,.FAIL_STORED
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.RETURN_STORED	; caller buffer filled mid-frame
	CALL	CAN_READ_ANOTHER_ACTIVE_IPD
	JR	C,.RETURN_STORED
	; Peek for a back-to-back frame with a short timeout, exactly like the
	; single-connection path: at line rate the next frame is already coming.
	LD	HL,TCP_CONT_TIMEOUT
	LD	(RECV_TIMEOUT),HL
	CALL	WAIT_IPD_HEADER_MUX
	PUSH	AF
	LD	HL,(RECV_FULL_TIMEOUT)
	LD	(RECV_TIMEOUT),HL
	POP	AF
	JR	C,.SCAN_FAIL
	CALL	MUX_PARSE_IPD_HDR
	JR	C,.FAIL_STORED
	LD	A,(MUX_FRAME_LINK)
	LD	HL,RECV_CH
	CP	(HL)
	JR	Z,.OWN_FRAME
	CALL	MUX_STASH_FRAME
	JR	C,.FAIL_STORED
	JR	.RETURN_STORED
.SCAN_FAIL
	PUSH	AF
	CP	RES_NOT_CONN
	JR	Z,.SCAN_FAIL_CLOSED
	CP	RES_CONN_EVT
	JR	Z,.SCAN_FAIL_CONNECT
	POP	AF
	JR	.FAIL_STORED
.SCAN_FAIL_CONNECT
	POP	AF
	LD	A,(MUX_CONNECT_LINK)
	CALL	MUX_TRY_ACCEPT
	JP	.SCAN			; resume scanning; RECV_TIMEOUT already restored
.SCAN_FAIL_CLOSED
	POP	AF
	; fall through
.CLOSED_EVENT
	LD	A,(MUX_CLOSED_LINK)
	CP	0xFF
	JR	NZ,.HAVE_LINK
	LD	A,(RECV_CH)		; unlabelled CLOSED: assume it is ours
	LD	(MUX_CLOSED_LINK),A
	JR	.LATCH
.HAVE_LINK
	CALL	MAP_LINK_TO_CH		; wire-level link -> channel-space, so the
	LD	(MUX_CLOSED_LINK),A	; RECV_CH compare below matches correctly
.LATCH
	CALL	MUX_LATCH_CLOSED
	LD	A,(MUX_CLOSED_LINK)
	LD	HL,RECV_CH
	CP	(HL)
	JR	Z,.OWN_CLOSED
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	NZ,.RETURN_STORED
	JP	.SCAN			; other channel closed: keep looking
.OWN_CLOSED
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	NZ,.RETURN_STORED	; data first, RES_NOT_CONN next call
	CALL	ISA.ISA_CLOSE
	LD	A,RES_NOT_CONN
	SCF
	RET
.RETURN_STORED
	CALL	ISA.ISA_CLOSE
	LD	BC,(RECV_STORED)
	XOR	A
	RET
.FAIL_STORED
	PUSH	AF
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	Z,.FAIL_PROPAGATE
	POP	AF
	JR	.RETURN_STORED
.FAIL_PROPAGATE
	POP	AF
	PUSH	AF
	CALL	ISA.ISA_CLOSE
	POP	AF
	RET
	ENDIF

	IFNDEF ESP_TCP_MUX
; ------------------------------------------------------
; Read one CR/LF-terminated line into LINE_BUFFER.
; ------------------------------------------------------
READ_LINE
	LD	IX,LINE_BUFFER
	LD	A,TCP_LINE_SIZE-1
	LD	(LINE_REMAIN),A
.NEXT
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.TIMEOUT
	CP	13
	JR	Z,.NEXT
	CP	10
	JR	Z,.END
	LD	A,(LINE_REMAIN)
	AND	A
	JR	Z,.NEXT
	LD	(IX+0),C
	INC	IX
	DEC	A
	LD	(LINE_REMAIN),A
	JR	.NEXT
.END
	LD	(IX+0),0
	LD	A,(LINE_BUFFER)
	AND	A
	JR	Z,READ_LINE
	XOR	A
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; ------------------------------------------------------
; Scan UART stream for '+IPD,' or connection close notification.
; ------------------------------------------------------
WAIT_IPD_HEADER
	LD	IX,IPD_PREFIX
	LD	IY,CLOSED_PREFIX
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	LD	E,A
	LD	A,(IX+0)
	CP	E
	JR	NZ,.RESET
	INC	IX
	LD	A,(IX+0)
	AND	A
	JR	Z,.OK
	JR	.CHECK_CLOSED
.RESET
	LD	IX,IPD_PREFIX
	LD	A,E
	CP	'+'
	JR	NZ,.CHECK_CLOSED
	INC	IX
	JR	.CHECK_CLOSED
.CHECK_CLOSED
	LD	A,(IY+0)
	CP	E
	JR	NZ,.CLOSED_RESET
	INC	IY
	LD	A,(IY+0)
	AND	A
	JR	Z,.CLOSED
	JR	.NEXT
.CLOSED_RESET
	LD	IY,CLOSED_PREFIX
	LD	A,E
	CP	'C'
	JR	NZ,.NEXT
	INC	IY
	JR	.NEXT
.OK
	XOR	A
	RET
.CLOSED
	LD	A,RES_NOT_CONN
	SCF
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; ------------------------------------------------------
; Read decimal +IPD payload length until ':'.
; ------------------------------------------------------
READ_IPD_LEN
	LD	HL,0
	LD	(IPD_REMOTE_LEN),HL
	XOR	A
	LD	(IPD_HAVE_REMOTE_LEN),A
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	CP	':'
	JR	Z,.DONE
	CP	','
	JR	Z,.NEXT_FIELD
	CP	'0'
	JR	C,.REMOTE_INFO
	CP	'9'+1
	JR	NC,.REMOTE_INFO
	SUB	'0'
	LD	E,A
	LD	D,0
	LD	B,H
	LD	C,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,BC
	ADD	HL,HL
	ADD	HL,DE
	JR	.NEXT
.NEXT_FIELD
	LD	(IPD_REMOTE_LEN),HL
	LD	A,1
	LD	(IPD_HAVE_REMOTE_LEN),A
	LD	HL,0
	JR	.NEXT
.REMOTE_INFO
	LD	A,(IPD_HAVE_REMOTE_LEN)
	AND	A
	JR	Z,.ERROR_BAD_CHAR
.SKIP_REMOTE_INFO
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	CP	':'
	JR	NZ,.SKIP_REMOTE_INFO
	LD	HL,(IPD_REMOTE_LEN)
.DONE
	LD	(PAYLOAD_LEFT),HL
	LD	(LAST_IPD_LEN),HL
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_RECORD_IPD
	ENDIF
	XOR	A
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
.ERROR
	XOR	A
	LD	(IPD_BAD_CHAR),A
	LD	A,RES_ERROR
	SCF
	RET
.ERROR_BAD_CHAR
	LD	(IPD_BAD_CHAR),A
	LD	A,RES_ERROR
	SCF
	RET
	ENDIF

; ------------------------------------------------------
; Consume payload bytes and store up to RECV_REMAIN bytes.
; If caller buffer fills before +IPD payload ends, leave PAYLOAD_LEFT non-zero.
; The next RECEIVE call will continue the same payload before scanning for a
; new +IPD header.
; ------------------------------------------------------
READ_PAYLOAD
	; Keep the four per-payload values in registers. The old loop loaded and
	; stored PAYLOAD_LEFT, RECV_REMAIN, RECV_PTR and RECV_STORED for every byte,
	; in addition to the byte-reader's register save/restore. At 230400 baud that
	; bookkeeping, not the UART or TCP stream, was the measured bottleneck.
	PUSH	IY
	LD	HL,(PAYLOAD_LEFT)
	LD	BC,(RECV_REMAIN)
	LD	DE,(RECV_PTR)
	LD	IY,0			; bytes consumed by this invocation
	LD	A,H
	OR	L
	JR	Z,.DONE
	LD	A,B
	OR	C
	JR	Z,.DONE

.LOOP
	IFDEF ESP_TCP_TEST_READER
	; Scripted host-side byte source. Preserve BC because its C return alias is
	; part of the legacy reader contract, while the fast loop keeps capacity in
	; BC across bytes.
	PUSH	BC
	CALL	@TEST_READ_BYTE
	POP	BC
	JR	C,.TIMEOUT
	ELSE
	; ISA is already open. Poll LSR and read RBR directly on the byte-ready hot
	; path; only an empty FIFO falls back to the full timeout/cancel reader.
	LD	A,(REG_LSR)
	LD	(LAST_LSR),A
	AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	CALL	NZ,ACCUM_PAYLOAD_LSR_ERROR
	IFDEF ISA_RX_GUARD
	JR	C,.TIMEOUT		; corrupt +IPD length can never be satisfied
	ENDIF
	LD	A,(LAST_LSR)
	AND	LSR_DR
	JR	Z,.WAIT_BYTE
	LD	A,(REG_RBR)
	JR	.BYTE_READY
.WAIT_BYTE
	PUSH	BC
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	POP	BC
	JR	C,.TIMEOUT
	ENDIF
.BYTE_READY
	LD	(DE),A
	INC	DE
	DEC	HL
	DEC	BC
	INC	IY
	LD	A,H
	OR	L
	JR	Z,.DONE
	LD	A,B
	OR	C
	JR	NZ,.LOOP
.DONE
	CALL	.COMMIT_STATE
	POP	IY
	LD	BC,(RECV_STORED)
	XOR	A
	RET
.TIMEOUT
	CALL	.COMMIT_STATE
	POP	IY
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	Z,.TIMEOUT_EMPTY
	LD	B,H
	LD	C,L
	XOR	A
	RET
.TIMEOUT_EMPTY
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; Commit the register-cached payload state and fold this invocation's byte
; count into the RECEIVE-wide total. Preserves the caller's saved IY on stack.
.COMMIT_STATE
	IFNDEF ESP_TCP_TEST_READER
	; Errors are accumulated as soon as seen; fold in the final ordinary status
	; once per payload run so diagnostics retain their historical full LSR mask
	; without a memory OR on every byte.
	LD	A,(LAST_LSR)
	PUSH	HL
	LD	HL,LSR_ACCUM
	OR	(HL)
	LD	(HL),A
	POP	HL
	ENDIF
	LD	(PAYLOAD_LEFT),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_PTR),DE
	PUSH	IY
	POP	DE
	LD	HL,(RECV_STORED)
	ADD	HL,DE
	LD	(RECV_STORED),HL
	RET

	IFNDEF ESP_TCP_TEST_READER
; Rare path: reading LSR clears its sticky error bits, so retain them before
; either consuming RBR or entering the slow timeout reader. In: A=error mask.
ACCUM_PAYLOAD_LSR_ERROR
	PUSH	HL
	LD	HL,LSR_ACCUM
	OR	(HL)
	LD	(HL),A
	POP	HL
	IFDEF ISA_RX_GUARD
	LD	A,(ISA.RX_CRITICAL)
	RRA				; CF = guard (0/1); legacy only latches
	ENDIF
	RET
	ENDIF

; ------------------------------------------------------
; Read one UART byte with caller-provided timeout in BC.
; Out: CF=0, A=byte, C=byte. CF=1 on timeout.
; ------------------------------------------------------
READ_BYTE_TIMEOUT
	IFDEF ESP_TCP_FAST_COMMAND_RX
	IFNDEF ESP_AT_FORCE_221
	IFNDEF ESP_AT_FORCE_222
	LD	A,(WCOMMON.UART_ESP_PROFILE)
	CP	UART_RX_PROFILE_222
	JR	NZ,.LEGACY
	ENDIF
	; FTP's CIPSEND prompt can follow queued AT text at 230400 baud. The
	; legacy UART_WAIT_RS sleeps 1 ms after an empty sample (23 incoming bytes,
	; versus a 16-byte FIFO) and discards read-to-clear LSR errors. Use the same
	; busy-poll/error-latching reader as payload receive. Map only for this call:
	; WAIT_PROMPT's IPD skipper also calls here and must not nest ISA windows.
	CALL	ISA.ISA_OPEN
	CALL	READ_BYTE_TIMEOUT_OPEN
	JP	ISA.ISA_CLOSE
	ENDIF
.LEGACY
	ENDIF
	CALL	WIFI.UART_WAIT_RS
	RET	C
	LD	HL,REG_RBR
	CALL	WIFI.UART_READ
	LD	C,A
	RET

	IFDEF ESP_TCP_MUX
; Reset parser/transaction state before a new command or SEND. Receive bytes
; are deliberately not traced here: verbose first/tail capture was a debugging
; aid and consumed scarce DLL image space without affecting recovery.
SEND_STATE_RESET
	XOR	A
	LD	(SEND_PHASE),A
	LD	(WSO_FLAGS),A
	; A fresh transaction must never inherit a stale suspension.
	LD	(ASYNC_PEND),A
	LD	(PROMPT_RESUME),A
	LD	(WSO_RESUME),A
	RET
	ENDIF

; Dead code with no caller left in either build (single-conn RECEIVE used it;
; RECEIVE_MUX reads through READ_BYTE_RECV_TIMEOUT_OPEN instead). Kept behind
; the same gate as its former only caller rather than deleted outright, so a
; future single-connection addition can still find it here.
	IFNDEF ESP_TCP_MUX
READ_BYTE_RECV_TIMEOUT
	LD	BC,(RECV_TIMEOUT)
	JP	READ_BYTE_TIMEOUT
	ENDIF

; Read one UART byte while the ISA window is open, with a caller-supplied
; millisecond timeout in BC.
;
; The hot path is a busy-poll on LSR.DR with NO per-byte delay: at 115200 baud a
; byte arrives every ~87 us and each FIFO burst is drained back-to-back while
; DR stays set, so the old "DELAY_1MS on every empty poll" (which throttled the
; link to ~1 KB/s and kept the ESP permanently backpressured) is gone. Once the
; bounded spin finds the UART idle, use the same UTIL.DELAY_1MS pacing contract
; as UNETRTL. RTS stays low while the ISA window is closed for that delay, so a
; 230400-baud peer cannot overflow the 16550 FIFO. BC is decremented before a
; delay, exactly like UNETRTL's TCP receive loop: a one-tick poll probes and
; returns without an added sleep.
; Exception: guarded FTP 2.2.2 budgets continuous polling at 21 MHz instead
; of delay ticks, keeping RTS stable between periodic keyboard/IRQ checks.
; Out: CF=0, A=byte, C=byte. CF=1 on timeout/cancel.
READ_BYTE_TIMEOUT_OPEN
	IFDEF ESP_TCP_TEST_READER
	; Host-side harnesses replace the LSR/RBR poll with a scripted byte source;
	; no shipped build defines this.
	JP	@TEST_READ_BYTE
	ENDIF
	PUSH	BC,DE,HL
	LD	A,1
	LD	(RBT_CANCEL_TICK),A
	; The first empty probe bridges a UART FIFO burst. Unguarded idle probes
	; then use one LSR sample per RTL-compatible tick; guarded FTP keeps polling.
.PROBE
	LD	DE,RX_SPIN_BUDGET
	LD	A,B
	OR	C
	JR	NZ,.SPIN
	LD	DE,1
.SPIN
	LD	HL,REG_LSR
	LD	A,(HL)
	LD	(LAST_LSR),A
	PUSH	AF
	LD	HL,LSR_ACCUM
	OR	(HL)
	LD	(HL),A
	IFDEF ISA_RX_GUARD
	; A lost byte invalidates the advertised +IPD length. Return to FTP's
	; UART-error handler now, not after a full per-byte timeout. Test the
	; accumulated status too, since reading LSR clears its sticky error bits.
	AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	JR	Z,.STATUS_OK
	LD	A,(ISA.RX_CRITICAL)
	OR	A
	JR	Z,.STATUS_OK
	POP	AF
	JR	.TIMEOUT
.STATUS_OK
	ENDIF
	POP	AF
	AND	LSR_DR
	JR	NZ,.OK
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.SPIN
	LD	A,B
	OR	C
	JR	Z,.TIMEOUT
	; Account before sleeping, as UNETRTL does. A public IY=1 poll therefore
	; returns after its probe without paying an extra one-millisecond delay.
	DEC	BC
	LD	A,B
	OR	C
	JR	Z,.TIMEOUT
	IFDEF ESP_TCP_TEST_DELAY_TICK
	CALL	@TEST_DELAY_TICK
	ELSE
	IFDEF ISA_RX_GUARD
	LD	A,(ISA.RX_CRITICAL)
	OR	A
	JR	Z,.LEGACY_IDLE
	; While actively draining, keep RTS stable and poll throughout the tick.
	; Previously each idle tick resumed RTS for just one LSR sample, often
	; stopping the ESP again before even one 230400-baud byte could arrive.
	; Only pause for the periodic DSS keyboard/IRQ service, never per tick.
	LD	HL,RBT_CANCEL_TICK
	DEC	(HL)
	JR	NZ,.GUARD_PROBE
	LD	(HL),200
	CALL	WIFI.UART_RX_PAUSE_OPEN
	CALL	@WCOMMON.CHECK_CANCEL_IN_ISA
	JR	C,.CANCEL
	CALL	WIFI.UART_RX_RESUME_OPEN
.GUARD_PROBE
	LD	DE,RX_GUARD_SPIN_BUDGET
	JP	.SPIN
.LEGACY_IDLE
	ENDIF
	CALL	WIFI.UART_RX_PAUSE_OPEN
	; DSS keyboard scans are not part of the delay calibration. Keep them
	; periodic, as in the original reader, rather than paying for 1000 scans
	; in a 1000-tick timeout. Check once immediately, then every 200 ticks.
	LD	HL,RBT_CANCEL_TICK
	DEC	(HL)
	JR	NZ,.SKIP_CANCEL
	LD	(HL),200
	CALL	@WCOMMON.CHECK_CANCEL_IN_ISA
	JR	C,.CANCEL
.SKIP_CANCEL
	CALL	ISA.ISA_CLOSE
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_RECORD_WAIT_TICK
	ENDIF
	CALL	UTIL.DELAY_1MS
	CALL	ISA.ISA_OPEN
	CALL	WIFI.UART_RX_RESUME_OPEN
	ENDIF
	; Do not repeat RX_SPIN_BUDGET for every nominal millisecond: that was the
	; source of the fivefold timeout. Resume with one status sample; a received
	; byte returns immediately, otherwise the next RTL tick starts.
	LD	DE,1
	IFDEF ISA_RX_GUARD
	JP	.SPIN
	ELSE
	JR	.SPIN
	ENDIF
.TIMEOUT
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_END_WAIT_RUN
	ENDIF
	SCF
	POP	HL,DE,BC
	RET
.OK
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_END_WAIT_RUN
	ENDIF
	LD	HL,REG_RBR
	LD	A,(HL)			; A = received byte
	POP	HL,DE,BC
	LD	C,A
	AND	A			; CF=0 (success); A unchanged
	RET
.CANCEL
	; User cancel: return as if timeout; WCOMMON.CANCELLED flag is set.
	; The cancel check returns with ISA open; undo our pause on this exit too.
	CALL	WIFI.UART_RX_RESUME_OPEN
	IFDEF ESP_TCP_DIAGNOSTICS
	CALL	DIAG_END_WAIT_RUN
	ENDIF
	SCF
	POP	HL,DE,BC
	RET

READ_BYTE_RECV_TIMEOUT_OPEN
	LD	BC,(RECV_TIMEOUT)
	JP	READ_BYTE_TIMEOUT_OPEN

	IFDEF ESP_TCP_DIAGNOSTICS
; ------------------------------------------------------
; Optional low-overhead receive telemetry. DLSPEED enables this; normal TCP
; clients do not carry the counters or the extra calls. No counter is touched
; on the byte-ready hot path. DIAG_RECORD_WAIT_TICK runs only when the existing
; receive loop is already about to pay a 1 ms delay.
; ------------------------------------------------------
DIAG_RESET
	PUSH	AF,BC,DE,HL
	LD	HL,DIAG_BASE
	LD	DE,DIAG_BASE+1
	LD	BC,DIAG_END-DIAG_BASE-1
	XOR	A
	LD	(HL),A
	LDIR
	POP	HL,DE,BC,AF
	RET

DIAG_RECORD_RECEIVE_CALL
	PUSH	AF,HL
	LD	HL,DIAG_RECEIVE_CALLS
	CALL	DIAG_INC32
	POP	HL,AF
	RET

; In: BC = successfully returned RECEIVE block size.
DIAG_RECORD_RECV_BLOCK
	PUSH	AF,BC,DE,HL
	LD	HL,(DIAG_RECV_BLOCKS)
	LD	A,H
	OR	L
	LD	HL,(DIAG_RECV_BLOCKS+2)
	OR	H
	OR	L
	JR	NZ,.HAVE_BLOCK
	LD	(DIAG_RECV_MIN),BC
	LD	(DIAG_RECV_MAX),BC
	JR	.BLOCK_COUNT
.HAVE_BLOCK
	LD	HL,(DIAG_RECV_MIN)
	OR	A
	SBC	HL,BC
	JR	C,.BLOCK_MAX
	JR	Z,.BLOCK_MAX
	LD	(DIAG_RECV_MIN),BC
.BLOCK_MAX
	LD	HL,(DIAG_RECV_MAX)
	OR	A
	SBC	HL,BC
	JR	NC,.BLOCK_COUNT
	LD	(DIAG_RECV_MAX),BC
.BLOCK_COUNT
	LD	HL,DIAG_RECV_BLOCKS
	CALL	DIAG_INC32
	POP	HL,DE,BC,AF
	RET

; In: HL = parsed +IPD payload length. Preserves all registers and flags.
DIAG_RECORD_IPD
	PUSH	AF,BC,DE,HL
	LD	B,H
	LD	C,L
	LD	HL,(DIAG_IPD_FRAMES)
	LD	A,H
	OR	L
	LD	HL,(DIAG_IPD_FRAMES+2)
	OR	H
	OR	L
	JR	NZ,.HAVE_IPD
	LD	(DIAG_IPD_MIN),BC
	LD	(DIAG_IPD_MAX),BC
	JR	.IPD_TOTAL
.HAVE_IPD
	LD	HL,(DIAG_IPD_MIN)
	OR	A
	SBC	HL,BC
	JR	C,.IPD_MAX
	JR	Z,.IPD_MAX
	LD	(DIAG_IPD_MIN),BC
.IPD_MAX
	LD	HL,(DIAG_IPD_MAX)
	OR	A
	SBC	HL,BC
	JR	NC,.IPD_TOTAL
	LD	(DIAG_IPD_MAX),BC
.IPD_TOTAL
	LD	HL,(DIAG_IPD_BYTES)
	ADD	HL,BC
	LD	(DIAG_IPD_BYTES),HL
	LD	HL,(DIAG_IPD_BYTES+2)
	LD	DE,0
	ADC	HL,DE
	LD	(DIAG_IPD_BYTES+2),HL
	LD	HL,DIAG_IPD_FRAMES
	CALL	DIAG_INC32
	POP	HL,DE,BC,AF
	RET

; Mark the short look-ahead performed after a complete active +IPD frame.
DIAG_BEGIN_CONTINUATION
	PUSH	AF,HL
	LD	A,1
	LD	(DIAG_CONT_ACTIVE),A
	LD	HL,DIAG_CONT_PROBES
	CALL	DIAG_INC32
	POP	HL,AF
	RET

; Preserves the carry/result returned by WAIT_IPD_HEADER.
DIAG_END_CONTINUATION
	PUSH	AF
	XOR	A
	LD	(DIAG_CONT_ACTIVE),A
	POP	AF
	RET

DIAG_RECORD_CONTINUATION_MISS
	PUSH	AF,HL
	LD	HL,DIAG_CONT_MISSES
	CALL	DIAG_INC32
	POP	HL,AF
	RET

DIAG_RECORD_WAIT_TICK
	PUSH	AF,HL
	LD	HL,DIAG_WAIT_TICKS
	CALL	DIAG_INC32
	; The receive budgets used by this package fit in 16 bits. Saturate rather
	; than wrap so a future maximum-budget timeout remains unambiguous.
	LD	HL,(DIAG_WAIT_RUN)
	LD	A,H
	CP	0xFF
	JR	NZ,.INC_RUN
	LD	A,L
	CP	0xFF
	JR	Z,.RUN_READY
.INC_RUN
	INC	HL
	LD	(DIAG_WAIT_RUN),HL
.RUN_READY
	LD	A,(DIAG_CONT_ACTIVE)
	OR	A
	JR	Z,.DONE
	LD	HL,DIAG_CONT_WAIT_TICKS
	CALL	DIAG_INC32
.DONE
	POP	HL,AF
	RET

; Finish one continuous no-data interval. Called only by the slow byte reader,
; never by the FIFO-ready payload hot path. Preserves registers and flags.
DIAG_END_WAIT_RUN
	PUSH	AF,BC,DE,HL
	LD	BC,(DIAG_WAIT_RUN)
	LD	HL,(DIAG_WAIT_MAX)
	OR	A
	SBC	HL,BC
	JR	NC,.RESET
	LD	(DIAG_WAIT_MAX),BC
.RESET
	LD	HL,0
	LD	(DIAG_WAIT_RUN),HL
	POP	HL,DE,BC,AF
	RET

; Increment little-endian 32-bit integer at HL. Internal: trashes A,HL.
DIAG_INC32
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET
	ENDIF


; ------------------------------------------------------
; Append ASCIIZ from DE to destination at HL.
; Out: HL points to destination end.
; ------------------------------------------------------
APPEND_STR
	LD	A,(DE)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	APPEND_STR

APPEND_IX_STR
	LD	A,(IX+0)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	IX
	JR	APPEND_IX_STR

	IFNDEF ESP_TCP_MUX
CMD_CIPSTART_PREFIX
	DB	"AT+CIPSTART=",34,"TCP",34,",",34,0
CMD_CIPSTART_MIDDLE
	DB	34,",",0
	ENDIF
CMD_CIPSEND_PREFIX
	DB	"AT+CIPSEND=",0
	IFNDEF ESP_TCP_MUX
CMD_CIPCLOSE
	DB	"AT+CIPCLOSE",13,10,0
	ENDIF
CMD_CRLF
	DB	13,10,0
	IFDEF ESP_TCP_MUX
CMD_COMMA
	DB	",",0
MSG_READY
	DB	"ready",0
MSG_CONNECT_LN
	DB	"CONNECT",0
MSG_ALREADY_CONNECTED
	DB	"ALREADY CONNECTED",0
MSG_BUSY_PFX
	DB	"busy",0
	ENDIF

IPD_PREFIX
	DB	"+IPD,",0
CLOSED_PREFIX
	DB	"CLOSED",0
MSG_SEND_OK
	DB	"SEND OK",0
MSG_OK
	DB	"OK",0
MSG_ERROR
	DB	"ERROR",0
MSG_FAIL
	DB	"FAIL",0

	IFNDEF ESP_TCP_MUX
PTR_HOST	DW 0
PTR_PORT	DW 0
	ENDIF
SEND_PTR	DW 0
SEND_LEN	DW 0
RECV_PTR	DW 0
RECV_REMAIN	DW 0
RECV_TIMEOUT	DW 0
RECV_FULL_TIMEOUT DW 0
RECV_STORED	DW 0
PAYLOAD_LEFT	DW 0
	IFNDEF ESP_TCP_MUX
LAST_IPD_LEN	DW 0
IPD_REMOTE_LEN	DW 0
IPD_HAVE_REMOTE_LEN DB 0
IPD_BAD_CHAR	DB 0
	ENDIF
LAST_LSR	DB 0
LSR_ACCUM	DB 0

; Idle-tick countdown, not an interrupt or frame counter.
RBT_CANCEL_TICK	DB 0

	IFDEF ESP_TCP_DIAGNOSTICS
; DLSPEED-only receive telemetry. Kept in the compact loaded image: these are
; small initialized scalars, not transfer buffers.
DIAG_BASE
DIAG_RECEIVE_CALLS	DS 4,0
DIAG_RECV_BLOCKS	DS 4,0
DIAG_RECV_MIN		DW 0
DIAG_RECV_MAX		DW 0
DIAG_IPD_FRAMES		DS 4,0
DIAG_IPD_BYTES		DS 4,0
DIAG_IPD_MIN		DW 0
DIAG_IPD_MAX		DW 0
DIAG_WAIT_TICKS		DS 4,0
DIAG_WAIT_RUN		DW 0
DIAG_WAIT_MAX		DW 0
DIAG_CONT_PROBES	DS 4,0
DIAG_CONT_MISSES	DS 4,0
DIAG_CONT_WAIT_TICKS	DS 4,0
DIAG_CONT_ACTIVE	DB 0
DIAG_END
	ENDIF

LINE_REMAIN	DB 0

	IFNDEF ESP_TCP_MUX
; TX_CMD_BUSY_RETRY state
BUSY_CMD	DW 0
BUSY_TIMEOUT	DW 0
BUSY_LEFT	DB 0
	ENDIF

; Pointer into IPD_PREFIX while WAIT_SEND_OK is incrementally checking
; whether the line being accumulated starts with "+IPD,". Set to zero
; once detection has given up for the current line.
IPD_STATE_PTR	DW 0

	IFDEF ESP_TCP_RX_DEFER
; Receive-defer window state (see the ESP_TCP_RX_DEFER note near the top).
; DEFER_W/DEFER_R are byte offsets into DEFER_BUF; the buffered region holds a
; sequence of {2-byte LE length, payload} frames. DEFER_FRAME_LEFT is the
; not-yet-delivered tail of the frame a RECEIVE was in the middle of returning.
; DEFER_LOST is sticky: a captured frame was dropped on overflow (or, single-
; link SEND-side only, truncated with its tail untracked), so the peer stream
; has a gap. A mux-side timeout keeps the tail live and does not set it.
; DEFER_W..DEFER_LOST must stay contiguous and in this order: ESP_TCP_MUX swaps
; the whole block in and out of the per-channel contexts with one LDIR.
DEFER_W		DW 0
DEFER_R		DW 0
DEFER_FRAME_LEFT	DW 0
DEFER_LOST	DB 0
; Scratch used only inside a single capture; not state between calls.
DEFER_FHDR	DW 0	; address of the length header of the frame being written
DEFER_WPTR	DW 0	; running payload write pointer
DEFER_NEED	DW 0	; payload bytes still to read
	ENDIF

	IFDEF ESP_TCP_MUX
DEFER_CTX_SIZE	EQU 7		; DEFER_W, DEFER_R, DEFER_FRAME_LEFT, DEFER_LOST
	ASSERT DEFER_LOST - DEFER_W + 1 == DEFER_CTX_SIZE
DEFER_BASE	DW 0		; buffer of the selected channel
DEFER_CUR_CH	DB 0		; channel whose context is loaded in the working set
DEFER_CTX	DS TCP_MUX_CHANNELS*DEFER_CTX_SIZE,0
RECV_CH		DB 0		; channel the current RECEIVE_MUX serves
MUX_READ_VEC	DW 0		; selected byte reader (send window vs open window)
MUX_DELIM	DB 0		; character that terminated the last decimal field
MUX_FRAME_LINK	DB 0		; link id of the +IPD header just parsed
MUX_FRAME_LEN	DW 0		; payload length of that header
MUX_PAYLOAD_LINK DB 0xFF	; owner of the live, partially read payload
MUX_CLOSED_LINK	DB 0xFF		; link id from the last CLOSED notification
MUX_CLOSED_MASK	DB 0		; latched peer closes, one bit per channel
MUX_CAND	DB 0xFF		; link digit committed at the last confirmed match start
MUX_PENDING_CAND DB 0xFF	; MUX_SNAP_PENDING's scratch; see MUX_COMMIT_CAND
MUX_B1		DB 0		; two-byte history feeding MUX_SNAP_PENDING
MUX_B2		DB 0
MUX_LINE_PTR	DW 0		; response line with any "<link>," prefix removed
MUX_LINE_LINK	DB 0xFF		; link id of that prefix (0xFF when absent)
MUX_ACCEPT_OK	DB 0		; WAIT_SEND_OK also accepts a bare OK (CIPCLOSE)
MUX_ACCEPT_CONNECT DB 0		; CIPSTART terminates on its own <id>,CONNECT
MUX_ACCEPT_CLOSED DB 0		; CIPCLOSE terminates on its own <id>,CLOSED
MUX_CONNECT_PAUSED DB 0		; internal RTS pause between CONNECT and first I/O
MUX_WINDOW_OPEN DB 0		; command wait currently owns an open ISA window
LINK_ID		DB 0		; link id used by the command builders
WSO_TIMEOUT	DW TCP_DEFAULT_TIMEOUT	; per-byte timeout of WAIT_SEND_OK/WAIT_PROMPT
WSO_FLAGS	DB 0		; bit0 SEND OK, bit1 ready, bit2 busy, bit3 target CONNECT,
				; bit4 ALREADY CONNECTED
SEND_PHASE	DB 0		; 0 = before payload, 1 = payload handed to the ESP
; Async (suspendable) send state - see SEND_BUFFER_RESUME.
ASYNC_MODE	DB 0		; 1: silence suspends the send instead of failing it
ASYNC_PEND	DB 0		; 0 idle / 1 awaiting '>' / 2 awaiting SEND OK
PROMPT_RESUME	DB 0		; WAIT_PROMPT must restore PROMPT_STATE on entry
PROMPT_STATE	DW 0		; saved "+IPD," prefix-match pointer
WSO_RESUME	DB 0		; WAIT_SEND_OK must resume its partial line
; LISTEN state (UNET_CAP_LISTEN). A firmware link id is not the same number
; space as our channel index once an inbound connection can land on any free
; id 0..TCP_MUX_MAX_LINK; MUX_LINK_MAP is the one place that reconciles them.
MUX_LINK_MAP	DS TCP_MUX_CHANNELS,0xFF	; channel -> firmware link id
MUX_LISTEN_CH	DB 0xFF		; channel currently armed to accept, 0xFF = none
MUX_STALE_LINKS	DB 0		; bit n: link n closed locally, CIPCLOSE unconfirmed
MUX_CONNECT_LINK DB 0xFF	; link id from the last scanner CONNECT match
MUX_CONN_PTR	DW 0		; WAIT_IPD_HEADER_MUX's "CONNECT" match cursor
	ENDIF

	IFNDEF	ESP_TCP_BSS_BASE_OVERRIDE
ESP_TCP_BSS_BASE	EQU WIFI.RS_BUFF + RS_BUFF_SIZE
	ENDIF

TCP_BSS_BASE	EQU ESP_TCP_BSS_BASE
CMD_BUFFER	EQU TCP_BSS_BASE
NUM_BUFFER	EQU CMD_BUFFER + TCP_CMD_SIZE
LINE_BUFFER	EQU NUM_BUFFER + 8
DEBUG_BUFFER	EQU LINE_BUFFER + TCP_LINE_SIZE
	IFDEF ESP_TCP_MUX
; One receive-defer window per channel, so data stashed for the channel that is
; not being read cannot be crowded out by the busy channel.
DEFER_BUF0	EQU DEBUG_BUFFER + TCP_DEBUG_SIZE
DEFER_BUF1	EQU DEFER_BUF0 + TCP_RX_DEFER_SIZE
TCP_BSS_END	EQU DEFER_BUF0 + TCP_MUX_CHANNELS*TCP_RX_DEFER_SIZE
	ELSE
	IFDEF ESP_TCP_RX_DEFER
DEFER_BUF	EQU DEBUG_BUFFER + TCP_DEBUG_SIZE
TCP_BSS_END	EQU DEFER_BUF + TCP_RX_DEFER_SIZE
	ELSE
TCP_BSS_END	EQU DEBUG_BUFFER + TCP_DEBUG_SIZE
	ENDIF
	ENDIF

	ENDMODULE

	ENDIF
