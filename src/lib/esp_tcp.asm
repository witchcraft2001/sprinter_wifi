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
TCP_ACTIVE_IPD_MAX	EQU 1500
; Busy-poll iterations spent waiting for the next UART byte before falling back
; to a 1 ms timeout tick. Sized to comfortably bridge the gap between FIFO
; bursts at 115200 baud across the Sprinter clock range; tune up if downloads
; still see per-burst stalls, down if a stalled link should time out sooner.
RX_SPIN_BUDGET		EQU 200
; Short timeout for peeking whether another back-to-back +IPD frame is coming
; within one RECEIVE call. Bounds the end-of-stream wait on an idle keep-alive
; socket without giving up on a still-active burst. This wait is paid once per
; filled receive buffer when no next +IPD is ready; 800 ms dominated 115200
; downloads. FTP uses the same burst strategy with 120 ms.
TCP_CONT_TIMEOUT	EQU 120

	MODULE TCP

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

; ------------------------------------------------------
; Send a raw TCP payload.
; In: HL - payload, BC - payload length.
; Out: CF=0/A=0 on success, CF=1/A=result code on failure.
; ------------------------------------------------------
SEND_BUFFER
	CALL	START_SEND_BUFFER
	RET	C
	JP	WAIT_SEND_OK

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
SEND_BUFFER_NO_WAIT
	CALL	START_SEND_BUFFER
	RET

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
	LD	DE,NUM_BUFFER
	CALL	APPEND_STR
	LD	DE,CMD_CRLF
	CALL	APPEND_STR

	CALL	WIFI.UART_EMPTY_RS
	LD	HL,CMD_BUFFER
	CALL	WIFI.UART_TX_STRING
	JR	C,.TX_TIMEOUT

	CALL	WAIT_PROMPT
	RET	C

	LD	HL,(SEND_PTR)
	LD	BC,(SEND_LEN)
	CALL	WIFI.UART_TX_BUFFER
	JR	C,.TX_TIMEOUT

	XOR	A
	RET

.TX_TIMEOUT
	LD	A,RES_TX_TIMEOUT
	SCF
	RET

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
	; Reassert the profile-specific streaming trigger without flushing queued
	; +IPD bytes. The 2.2.1 routine is a no-op and retains its proven trigger 8.
	CALL	WIFI.UART_SET_DATA_RX_MODE
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	(RECV_FULL_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL

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
	CALL	WAIT_IPD_HEADER
	LD	HL,(RECV_FULL_TIMEOUT)
	LD	(RECV_TIMEOUT),HL
	JR	NC,.NEXT_ACTIVE
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
.NEXT
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.TIMEOUT_POP
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
	CALL	SKIP_IPD_FRAME
	JR	C,.TIMEOUT_POP
	LD	IX,IPD_PREFIX
	JR	.NEXT
.OK_POP
	POP	IX
	XOR	A
	RET
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
.RESTART
	LD	IX,LINE_BUFFER
	LD	A,TCP_LINE_SIZE-1
	LD	(LINE_REMAIN),A
	LD	HL,IPD_PREFIX
	LD	(IPD_STATE_PTR),HL
.NEXT_BYTE
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	READ_BYTE_TIMEOUT
	JR	C,.TIMEOUT
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
	CALL	SKIP_IPD_FRAME
	JR	C,.TIMEOUT
	JR	.RESTART
.END_LINE
	LD	(IX+0),0
	LD	A,(LINE_BUFFER)
	AND	A
	JR	Z,.RESTART
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
	JR	.RESTART
.OK
	XOR	A
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET
.FAIL
	LD	A,RES_FAIL
	SCF
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

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

; ------------------------------------------------------
; Consume payload bytes and store up to RECV_REMAIN bytes.
; If caller buffer fills before +IPD payload ends, leave PAYLOAD_LEFT non-zero.
; The next RECEIVE call will continue the same payload before scanning for a
; new +IPD header.
; ------------------------------------------------------
READ_PAYLOAD
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	Z,.DONE

	LD	HL,(RECV_REMAIN)
	LD	A,H
	OR	L
	JR	Z,.DONE

	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	LD	E,A

	LD	HL,(PAYLOAD_LEFT)
	DEC	HL
	LD	(PAYLOAD_LEFT),HL

	LD	HL,(RECV_REMAIN)
	DEC	HL
	LD	(RECV_REMAIN),HL

	LD	HL,(RECV_PTR)
	LD	(HL),E
	INC	HL
	LD	(RECV_PTR),HL

	LD	HL,(RECV_STORED)
	INC	HL
	LD	(RECV_STORED),HL
	JR	READ_PAYLOAD
.DONE
	LD	BC,(RECV_STORED)
	XOR	A
	RET
.TIMEOUT
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

; ------------------------------------------------------
; Read one UART byte with caller-provided timeout in BC.
; Out: CF=0, A=byte, C=byte. CF=1 on timeout.
; ------------------------------------------------------
READ_BYTE_TIMEOUT
	CALL	WIFI.UART_WAIT_RS
	RET	C
	LD	HL,REG_RBR
	CALL	WIFI.UART_READ
	LD	C,A
	RET

READ_BYTE_RECV_TIMEOUT
	LD	BC,(RECV_TIMEOUT)
	JP	READ_BYTE_TIMEOUT

; Read one UART byte while the ISA window is open, with a caller-supplied
; millisecond timeout in BC.
;
; The hot path is a busy-poll on LSR.DR with NO per-byte delay: at 115200 baud a
; byte arrives every ~87 us and each FIFO burst is drained back-to-back while
; DR stays set, so the old "DELAY_1MS on every empty poll" (which throttled the
; link to ~1 KB/s and kept the ESP permanently backpressured) is gone. Only when
; the spin budget is exhausted without a byte do we fall back to a 1 ms tick that
; advances the timeout and the periodic cancel poll, so a genuinely stalled link
; still times out.
; Out: CF=0, A=byte, C=byte. CF=1 on timeout/cancel.
READ_BYTE_TIMEOUT_OPEN
	PUSH	BC,DE,HL
	LD	HL,200
	LD	(RBT_CANCEL_TICK),HL
.MS_TICK
	LD	DE,RX_SPIN_BUDGET
.SPIN
	LD	HL,REG_LSR
	LD	A,(HL)
	LD	(LAST_LSR),A
	PUSH	AF
	LD	HL,LSR_ACCUM
	OR	(HL)
	LD	(HL),A
	POP	AF
	AND	LSR_DR
	JR	NZ,.OK
	DEC	DE
	LD	A,D
	OR	E
	JR	NZ,.SPIN
	; Spin window elapsed with no byte: advance the ms timeout / cancel poll.
	CALL	UTIL.DELAY_1MS
	LD	HL,(RBT_CANCEL_TICK)
	DEC	HL
	LD	(RBT_CANCEL_TICK),HL
	LD	A,H
	OR	L
	JR	NZ,.SKIP_CANCEL
	LD	HL,200
	LD	(RBT_CANCEL_TICK),HL
	CALL	@WCOMMON.CHECK_CANCEL_IN_ISA
	JR	C,.CANCEL
.SKIP_CANCEL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.MS_TICK
	SCF
	POP	HL,DE,BC
	RET
.OK
	LD	HL,REG_RBR
	LD	A,(HL)			; A = received byte
	POP	HL,DE,BC
	LD	C,A
	AND	A			; CF=0 (success); A unchanged
	RET
.CANCEL
	; User cancel: return as if timeout; WCOMMON.CANCELLED flag is set.
	SCF
	POP	HL,DE,BC
	RET

READ_BYTE_RECV_TIMEOUT_OPEN
	LD	BC,(RECV_TIMEOUT)
	JP	READ_BYTE_TIMEOUT_OPEN


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

CMD_CIPSTART_PREFIX
	DB	"AT+CIPSTART=",34,"TCP",34,",",34,0
CMD_CIPSTART_MIDDLE
	DB	34,",",0
CMD_CIPSEND_PREFIX
	DB	"AT+CIPSEND=",0
CMD_CIPCLOSE
	DB	"AT+CIPCLOSE",13,10,0
CMD_CRLF
	DB	13,10,0

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

PTR_HOST	DW 0
PTR_PORT	DW 0
SEND_PTR	DW 0
SEND_LEN	DW 0
RECV_PTR	DW 0
RECV_REMAIN	DW 0
RECV_TIMEOUT	DW 0
RECV_FULL_TIMEOUT DW 0
RECV_STORED	DW 0
PAYLOAD_LEFT	DW 0
LAST_IPD_LEN	DW 0
IPD_REMOTE_LEN	DW 0
IPD_HAVE_REMOTE_LEN DB 0
IPD_BAD_CHAR	DB 0
LAST_LSR	DB 0
LSR_ACCUM	DB 0

; Periodic cancel-poll counter for byte read loop
RBT_CANCEL_TICK	DW 0

LINE_REMAIN	DB 0

; TX_CMD_BUSY_RETRY state
BUSY_CMD	DW 0
BUSY_TIMEOUT	DW 0
BUSY_LEFT	DB 0

; Pointer into IPD_PREFIX while WAIT_SEND_OK is incrementally checking
; whether the line being accumulated starts with "+IPD,". Set to zero
; once detection has given up for the current line.
IPD_STATE_PTR	DW 0

	IFNDEF	ESP_TCP_BSS_BASE_OVERRIDE
ESP_TCP_BSS_BASE	EQU WIFI.RS_BUFF + RS_BUFF_SIZE
	ENDIF

TCP_BSS_BASE	EQU ESP_TCP_BSS_BASE
CMD_BUFFER	EQU TCP_BSS_BASE
NUM_BUFFER	EQU CMD_BUFFER + TCP_CMD_SIZE
LINE_BUFFER	EQU NUM_BUFFER + 8
DEBUG_BUFFER	EQU LINE_BUFFER + TCP_LINE_SIZE
TCP_BSS_END	EQU DEBUG_BUFFER + TCP_DEBUG_SIZE

	ENDMODULE

	ENDIF
