; ======================================================
; ESP-AT multi-connection TCP helpers for Sprinter ESP Network Kit
; Include after esp_tcp.asm only in tools that require AT+CIPMUX=1.
; Single-connection tools should not include this file.
; ======================================================

	IFNDEF	_ESP_TCP_MULTI
	DEFINE	_ESP_TCP_MULTI

	MODULE TCP

; ------------------------------------------------------
; Open a TCP connection in ESP-AT multi-connection mode.
; In: A - link id, HL - host ASCIIZ, DE - port ASCIIZ.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; Caller must enable AT+CIPMUX=1 before using this routine.
; ------------------------------------------------------
OPEN_LINK
	LD	(LINK_ID),A
	LD	(PTR_HOST),HL
	LD	(PTR_PORT),DE
	LD	HL,0
	LD	(PAYLOAD_LEFT),HL
	XOR	A
	LD	(LSR_ACCUM),A
	IFNDEF	ESP_AT_FORCE_221
	LD	(MULTI_PENDING_RESULT),A
	ENDIF

	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSTART_LINK_PREFIX
	CALL	APPEND_STR
	LD	A,(LINK_ID)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_CIPSTART_LINK_MIDDLE
	CALL	APPEND_STR
	LD	IX,(PTR_HOST)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CIPSTART_MIDDLE
	CALL	APPEND_STR
	LD	IX,(PTR_PORT)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CRLF
	CALL	APPEND_STR

	; Retry while the ESP still answers "busy p..." right after NETUP's join;
	; see TCP.TX_CMD_BUSY_RETRY in esp_tcp.asm.
	LD	HL,CMD_BUFFER
	LD	BC,TCP_OPEN_TIMEOUT
	JP	TX_CMD_BUSY_RETRY

; ------------------------------------------------------
; Close a TCP link in ESP-AT multi-connection mode.
; In: A - link id.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
CLOSE_LINK
	LD	(LINK_ID),A
	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPCLOSE_LINK_PREFIX
	CALL	APPEND_STR
	LD	A,(LINK_ID)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_CRLF
	CALL	APPEND_STR
	LD	HL,CMD_BUFFER
	LD	DE,WIFI.RS_BUFF
	LD	BC,TCP_DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z
	SCF
	RET

; ------------------------------------------------------
; Send a raw TCP payload through a multi-connection link.
; In: A - link id, HL - payload, BC - payload length.
; Out: CF=0/A=0 on success, CF=1/A=result code on failure.
; ------------------------------------------------------
SEND_BUFFER_LINK
	CALL	START_SEND_BUFFER_LINK
	RET	C
	JP	WAIT_SEND_OK_LINK

; ------------------------------------------------------
; Send a raw TCP payload through a multi-connection link and return
; immediately after UART transmit.
; In: A - link id, HL - payload, BC - payload length.
; Out: CF=0/A=0 after bytes were accepted by the UART.
;      CF=1/A=result code on prompt/tx timeout.
; ------------------------------------------------------
SEND_BUFFER_LINK_NO_WAIT
	CALL	START_SEND_BUFFER_LINK
	RET

START_SEND_BUFFER_LINK
	LD	(LINK_ID),A
	LD	(SEND_PTR),HL
	LD	(SEND_LEN),BC

	LD	H,B
	LD	L,C
	LD	DE,NUM_BUFFER
	CALL	UTIL.UTOA

	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSEND_LINK_PREFIX
	CALL	APPEND_STR
	LD	A,(LINK_ID)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_COMMA
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
; Receive one +IPD payload block in multi-connection mode.
; In: HL - destination buffer, BC - max stored bytes, DE - timeout ms.
; Out: CF=0/A=0/BC=stored bytes on success.
;      LAST_IPD_LINK contains the ESP-AT link id.
;      CF=1/A=result code on timeout or protocol error.
; Notes:
; - Caller must enable AT+CIPMUX=1.
; - This consumes the next link-aware +IPD block from any link. The caller
;   dispatches by LAST_IPD_LINK.
; ------------------------------------------------------
RECEIVE_ANY_LINK
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	CALL	MULTI_DIAG_RESET
	ENDIF
	; Reassert the profile-specific streaming trigger without flushing bytes
	; that may already have followed the command response.
	CALL	WIFI.UART_SET_DATA_RX_MODE
	; Passive receive is retained for an explicitly forced 2.2.2 diagnostic
	; image. The universal executable uses the field-proven active path for
	; both profiles until the control-channel passive parser is hardware-tested.
	IFDEF	ESP_AT_FORCE_222
	LD	A,(PASSIVE_RECEIVE_ENABLED)
	AND	A
	JP	NZ,RECEIVE_ANY_LINK_PASSIVE
	ENDIF
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL

	CALL	ISA.ISA_OPEN
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.CONTINUE_PAYLOAD
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,1
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	WAIT_IPD_HEADER_MULTI
	JR	C,.DONE
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,2
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	READ_IPD_LINK_LEN
	JR	C,.DONE
.CONTINUE_PAYLOAD
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,3
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	READ_PAYLOAD
.DONE
	CALL	ISA.ISA_CLOSE
	RET
	; (No ENDIF here: the active body is shared by the 2.2.1 and universal
	; branches after the optional passive jump above.)

	IFNDEF	ESP_AT_FORCE_221
; ------------------------------------------------------
; Receive a burst of consecutive +IPD payloads without closing the ISA window.
; In/out contract is identical to RECEIVE_ANY_LINK.
;
; This is deliberately absent from forced ESP-AT 2.2.1 builds: their proven
; one-frame receive path remains unchanged. Universal callers select this entry
	; only when NET_ESP_FW says 2.2.2. The active path lowers RTS while ISA is
	; still mapped; the caller retains its idempotent pause guard before any
	; DSS/file/console work.
;
; Only frames from the first observed link are coalesced. If a frame for the
; other FTP link is encountered, its header is retained in PAYLOAD_LEFT and its
; body is delivered by the next receive call. A CLOSED result seen after stored
; data is similarly deferred so byte delivery remains ordered before close.
; ------------------------------------------------------
RECEIVE_ANY_LINK_BURST
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	CALL	MULTI_DIAG_RESET
	ENDIF
	IFDEF	ESP_AT_FORCE_222
	LD	A,(PASSIVE_RECEIVE_ENABLED)
	AND	A
	JR	Z,.ACTIVE_RECEIVE
	; Passive mode issues AT+CIPRECVDATA outside a held ISA window and retains
	; the established caller-resume contract.
	CALL	WIFI.UART_RX_RESUME
	JP	RECEIVE_ANY_LINK_PASSIVE
.ACTIVE_RECEIVE
	ENDIF
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	(RECV_FULL_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL

	; A close/protocol result detected only after a prior burst had already
	; produced bytes is reported on the following call, never before those bytes.
	LD	A,(MULTI_PENDING_RESULT)
	AND	A
	JR	Z,.NO_PENDING_RESULT
	LD	E,A
	XOR	A
	LD	(MULTI_PENDING_RESULT),A
	CALL	WIFI.UART_RX_PAUSE
	LD	A,E
	LD	BC,0
	SCF
	RET
.NO_PENDING_RESULT

	; Eliminate the resume-to-drain race: map ISA and select the non-flushing
	; streaming trigger first, then raise RTS in-place and read immediately.
	CALL	ISA.ISA_OPEN
	CALL	WIFI.UART_SET_DATA_RX_MODE_OPEN
	CALL	WIFI.UART_RX_RESUME_OPEN
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.CONTINUE_PENDING_PAYLOAD
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,1
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	WAIT_IPD_HEADER_MULTI
	JR	C,.DONE
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,2
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	READ_IPD_LINK_LEN
	JR	C,.DONE
	LD	A,(LAST_IPD_LINK)
	LD	(MULTI_BURST_LINK),A
	JR	.READ_CURRENT_PAYLOAD

.CONTINUE_PENDING_PAYLOAD
	; A different-link header may have been parsed by the preceding burst while
	; its payload was intentionally left unread. Restore its owner before return.
	LD	A,(PAYLOAD_LINK)
	LD	(LAST_IPD_LINK),A
	LD	(MULTI_BURST_LINK),A

.READ_CURRENT_PAYLOAD
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,3
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	READ_PAYLOAD
	JR	C,.DONE
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.DONE
	; Leave enough buffer for the next maximum active +IPD. If less remains,
	; return under the existing outer RTS guard rather than consume/discard data.
	CALL	CAN_READ_ANOTHER_ACTIVE_IPD
	JR	C,.RETURN_STORED_OK

	; Probe only briefly for a back-to-back frame. Unlike the former FTP-side
	; loop, this keeps ISA mapped and drains every arriving byte while RTS is high.
	LD	HL,TCP_CONT_TIMEOUT
	LD	(RECV_TIMEOUT),HL
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,1
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	WAIT_IPD_HEADER_MULTI
	PUSH	AF
	LD	HL,(RECV_FULL_TIMEOUT)
	LD	(RECV_TIMEOUT),HL
	POP	AF
	JR	C,.CONTINUATION_ERROR
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	A,2
	LD	(MULTI_DIAG_PHASE),A
	ENDIF
	CALL	READ_IPD_LINK_LEN
	JR	C,.CONTINUATION_ERROR
	LD	A,(LAST_IPD_LINK)
	LD	E,A
	LD	A,(MULTI_BURST_LINK)
	CP	E
	JR	Z,.READ_CURRENT_PAYLOAD
	; The other link's header is complete and PAYLOAD_LEFT owns its body. Report
	; the accumulated link now; CONTINUE_PENDING_PAYLOAD restores the other link.
	LD	(LAST_IPD_LINK),A
	JR	.RETURN_STORED_OK

.CONTINUATION_ERROR
	; If this burst has not produced bytes, preserve the original error. Once it
	; has produced bytes, deliver them first. Timeout merely ends this burst;
	; CLOSED/protocol errors are latched for the next call.
	PUSH	AF
	LD	HL,(RECV_STORED)
	LD	A,H
	OR	L
	JR	Z,.NO_STORED_ERROR
	POP	AF
	CP	RES_RS_TIMEOUT
	JR	Z,.RETURN_STORED_OK
	LD	(MULTI_PENDING_RESULT),A
	JR	.RETURN_STORED_OK
.NO_STORED_ERROR
	POP	AF
	JR	.DONE

.RETURN_STORED_OK
	LD	BC,(RECV_STORED)
	XOR	A
.DONE
	; Close the only overrun window left by the FTP-side accumulator: throttle
	; ESP while MCR and UART registers are still mapped, then unmap ISA. The
	; outer FTP guard repeats the pause harmlessly before slow work.
	PUSH	AF
	CALL	WIFI.UART_RX_PAUSE_OPEN
	POP	AF
	CALL	ISA.ISA_CLOSE
	RET
	ENDIF

	; ------------------------------------------------------
	; ESP-AT 2.2.2 passive receive backend.
	;
	; AT+CIPRECVMODE=1 makes +IPD report only the amount buffered by ESP.
	; Read the advertised bytes with AT+CIPRECVDATA instead of accepting a
	; full TCP burst straight into the 16550.  The ESP receive buffer then
	; provides TCP backpressure while DSS is writing/printing a previous block.
	; This code is selected only for a 2.2.2 profile.
	; ------------------------------------------------------
; ESP-AT does not report the next passive +IPD until the data announced by the
; previous one has been read. Its documented socket buffer is 5760 bytes, and
; FTP's WIN2 receive area is larger, so fetch the complete notification rather
; than leaving a partial record that would stall the transfer.
PASSIVE_READ_MAX	EQU 5760

RECEIVE_ANY_LINK_PASSIVE
	LD	(RECV_PTR),HL
	LD	(RECV_REMAIN),BC
	LD	(RECV_TIMEOUT),DE
	LD	HL,0
	LD	(RECV_STORED),HL
	LD	(PAYLOAD_LEFT),HL

	CALL	ISA.ISA_OPEN
	CALL	WAIT_PASSIVE_IPD_OR_CLOSE
	JR	C,.FAIL_OPEN
	CALL	READ_PASSIVE_IPD_LINK_LEN
	JR	C,.FAIL_OPEN
	CALL	CHOOSE_PASSIVE_READ_LEN
	JR	C,.FAIL_OPEN
	CALL	ISA.ISA_CLOSE

	CALL	BUILD_PASSIVE_READ_COMMAND
	LD	HL,CMD_BUFFER
	CALL	WIFI.UART_TX_STRING
	JR	C,.TX_TIMEOUT

	CALL	ISA.ISA_OPEN
	CALL	WAIT_PASSIVE_DATA_HEADER
	JR	C,.FAIL_OPEN
	CALL	READ_PASSIVE_DATA_LEN
	JR	C,.FAIL_OPEN
	CALL	READ_PAYLOAD
	JR	C,.FAIL_OPEN
	; A partial CIPRECVDATA payload is a protocol error.  In particular, do
	; not return partial bytes as a good FTP block and risk writing corruption.
	LD	HL,(PAYLOAD_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.PROTOCOL_OPEN
	CALL	WAIT_PASSIVE_RESULT_OPEN
	JR	C,.FAIL_OPEN
	CALL	ISA.ISA_CLOSE
	LD	BC,(RECV_STORED)
	XOR	A
	RET

.PROTOCOL_OPEN
	LD	A,RES_ERROR
	SCF
.FAIL_OPEN
	PUSH	AF
	CALL	ISA.ISA_CLOSE
	POP	AF
	SCF
	RET
.TX_TIMEOUT
	LD	A,RES_TX_TIMEOUT
	SCF
	RET

; Parse the passive notification, which has no ':' or inline data:
;     +IPD,<link>,<buffered-length>\r\n
READ_PASSIVE_IPD_LINK_LEN
	CALL	READ_DEC_FIELD
	RET	C
	; Accept any ESP-AT multi-connection link id (0..4). Rejecting non-zero
	; ids here broke passive receive on the FTP data link, which always runs
	; on link 1 while the control link keeps link 0.
	LD	A,H
	AND	A
	JR	NZ,.ERROR
	LD	A,L
	CP	5
	JR	NC,.ERROR
	LD	(LAST_IPD_LINK),A
	LD	(PAYLOAD_LINK),A
	LD	A,(IPD_DELIM)
	CP	','
	JR	NZ,.ERROR
	CALL	READ_DEC_FIELD
	RET	C
	LD	(LAST_IPD_LEN),HL
	LD	A,(IPD_DELIM)
	CP	13
	JR	NZ,.ERROR
	; CR is already the complete passive +IPD delimiter. Do not block for LF:
	; ESP-AT variants may emit it separately, and WAIT_PASSIVE_DATA_HEADER will
	; harmlessly skip it while looking for the next response prefix.
	XOR	A
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET

; Request no more than the caller can store and no more than a modest command
; chunk. IPD_REMOTE_LEN retains that request until the reply header validates
; its actual payload length.
CHOOSE_PASSIVE_READ_LEN
	LD	HL,(LAST_IPD_LEN)
	LD	DE,(RECV_REMAIN)
	OR	A
	SBC	HL,DE
	JR	NC,.REMAIN_SMALLER
	LD	HL,(LAST_IPD_LEN)
	JR	.LIMIT
.REMAIN_SMALLER
	LD	H,D
	LD	L,E
.LIMIT
	LD	DE,PASSIVE_READ_MAX
	OR	A
	SBC	HL,DE
	JR	NC,.MAX
	ADD	HL,DE
	JR	.HAVE_LEN
.MAX
	LD	H,D
	LD	L,E
.HAVE_LEN
	LD	A,H
	OR	L
	JR	Z,.ERROR
	LD	(IPD_REMOTE_LEN),HL
	XOR	A
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET

BUILD_PASSIVE_READ_COMMAND
	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPRECVDATA_PREFIX
	CALL	APPEND_STR
	LD	A,(LAST_IPD_LINK)
	CALL	APPEND_LINK_ID
	LD	DE,CMD_COMMA
	CALL	APPEND_STR
	LD	HL,(IPD_REMOTE_LEN)
	LD	DE,NUM_BUFFER
	CALL	UTIL.UTOA
	LD	DE,NUM_BUFFER
	CALL	APPEND_STR
	LD	DE,CMD_CRLF
	JP	APPEND_STR

WAIT_PASSIVE_DATA_HEADER
	LD	IX,PASSIVE_DATA_PREFIX
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
	RET	Z
	JR	.NEXT
.RESET
	LD	IX,PASSIVE_DATA_PREFIX
	LD	A,E
	CP	'+'
	JR	NZ,.NEXT
	INC	IX
	JR	.NEXT
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; Header format is "+CIPRECVDATA:<actual-length>,<raw-data>". Reject a
; response longer than requested: otherwise it could overwrite RECV_BUFFER.
READ_PASSIVE_DATA_LEN
	CALL	READ_DEC_FIELD
	RET	C
	LD	A,(IPD_DELIM)
	CP	','
	JR	NZ,.ERROR
	LD	(LAST_IPD_LEN),HL
	LD	DE,(IPD_REMOTE_LEN)
	OR	A
	SBC	HL,DE
	JR	C,.GOOD
	LD	A,H
	OR	L
	JR	NZ,.ERROR
.GOOD
	LD	HL,(LAST_IPD_LEN)
	LD	(PAYLOAD_LEFT),HL
	XOR	A
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET

; CIPRECVDATA ends with CRLF and a final OK. Read it while ISA remains open so
; READ_BYTE_RECV_TIMEOUT_OPEN accumulates OE/PE/FE exactly like payload bytes.
; Keep the response boundary strict: swallowing an unexpected +IPD here would
; lose the next TCP block.
WAIT_PASSIVE_RESULT_OPEN
	LD	IX,LINE_BUFFER
	LD	A,TCP_LINE_SIZE-1
	LD	(LINE_REMAIN),A
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
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
	JR	Z,WAIT_PASSIVE_RESULT_OPEN
	LD	HL,MSG_OK
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	RET	NC
	LD	HL,MSG_ERROR
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.ERROR
	LD	HL,MSG_FAIL
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.FAIL
	LD	A,RES_ERROR
	SCF
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

; In passive mode no payload follows the +IPD notification; ESP keeps it in
; its TCP buffer until CIPRECVDATA fetches it. Therefore a CLOSED notification
; is an unambiguous end of the current receive cycle and must not turn into a
; full FTP_DATA_TIMEOUT pause. Active +IPD retains its separate parser because
; it may still have queued payload frames after CLOSED.
WAIT_PASSIVE_IPD_OR_CLOSE
	LD	IX,IPD_PREFIX
	LD	IY,CLOSED_PREFIX
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	LD	E,A
	LD	A,(IX+0)
	CP	E
	JR	NZ,.IPD_RESET
	INC	IX
	LD	A,(IX+0)
	AND	A
	JR	Z,.OK
	JR	.CLOSED_CHECK
.IPD_RESET
	LD	IX,IPD_PREFIX
	LD	A,E
	CP	'+'
	JR	NZ,.CLOSED_CHECK
	INC	IX
.CLOSED_CHECK
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
; Wait until ESP reports SEND OK in multi-connection mode.
; Link-id responses may include text around SEND OK/FAIL.
; ------------------------------------------------------
WAIT_SEND_OK_LINK
	CALL	READ_LINE
	RET	C
	LD	HL,MSG_SEND_OK
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.OK
	LD	HL,LINE_BUFFER
	LD	DE,MSG_SEND_OK
	CALL	LINE_CONTAINS
	JR	NC,.OK
	LD	HL,MSG_OK
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,WAIT_SEND_OK_LINK
	LD	HL,MSG_ERROR
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.ERROR
	LD	HL,MSG_FAIL
	LD	DE,LINE_BUFFER
	CALL	UTIL.STRCMP
	JR	NC,.FAIL
	LD	HL,LINE_BUFFER
	LD	DE,MSG_FAIL
	CALL	LINE_CONTAINS
	JR	NC,.FAIL
	JR	WAIT_SEND_OK_LINK
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

; ------------------------------------------------------
; Wait for '+IPD,' in ESP-AT multi-connection mode, or a CLOSED indication.
; ESP writes UART messages in order, so an explicit CLOSED after the last +IPD
; is the data-transfer terminator. Returning RES_NOT_CONN avoids the previous
; full FTP_DATA_TIMEOUT pause at the end of every directory listing.
; ------------------------------------------------------
WAIT_IPD_HEADER_MULTI
	LD	IX,IPD_PREFIX
	LD	IY,CLOSED_PREFIX
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	(MULTI_DIAG_LAST_BYTE),A
	PUSH	HL
	LD	HL,(MULTI_DIAG_SCAN_BYTES)
	INC	HL
	LD	(MULTI_DIAG_SCAN_BYTES),HL
	POP	HL
	ENDIF
	LD	E,A
	LD	A,(IX+0)
	CP	E
	JR	NZ,.RESET
	INC	IX
	LD	A,(IX+0)
	AND	A
	JR	Z,.OK
	JR	.CLOSED_CHECK
.RESET
	LD	IX,IPD_PREFIX
	LD	A,E
	CP	'+'
	JR	NZ,.CLOSED_CHECK
	INC	IX
.CLOSED_CHECK
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
; Read decimal multi-connection +IPD link id and payload length until ':'.
; Expected ESP-AT forms with CIPDINFO=0:
;   +IPD,<link>,<len>:<data>
; With CIPDINFO=1, extra remote info after <len> is skipped:
;   +IPD,<link>,<len>,<ip>,<port>:<data>
; ------------------------------------------------------
READ_IPD_LINK_LEN
	CALL	READ_DEC_FIELD
	JR	C,.ERROR
	LD	A,L
	LD	(LAST_IPD_LINK),A
	LD	(PAYLOAD_LINK),A
	LD	A,(IPD_DELIM)
	CP	','
	JR	NZ,.ERROR
	CALL	READ_DEC_FIELD
	JR	C,.ERROR
	LD	(PAYLOAD_LEFT),HL
	LD	(LAST_IPD_LEN),HL
	LD	A,(IPD_DELIM)
	CP	':'
	JR	Z,.OK
	CP	','
	JR	NZ,.ERROR
.SKIP_REMOTE_INFO
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	CP	':'
	JR	NZ,.SKIP_REMOTE_INFO
.OK
	XOR	A
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
.ERROR
	LD	A,RES_ERROR
	SCF
	RET

; ------------------------------------------------------
; Read decimal field until ',', ':' or CR. CR is used by ESP-AT passive
; receive notifications (+IPD,<link>,<pending>\r\n); active +IPD callers
; still validate ':' themselves.
; Out: HL=value, IPD_DELIM=delimiter.
; ------------------------------------------------------
READ_DEC_FIELD
	LD	HL,0
.NEXT
	CALL	READ_BYTE_RECV_TIMEOUT_OPEN
	JR	C,.TIMEOUT
	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
	LD	(MULTI_DIAG_LAST_BYTE),A
	PUSH	HL
	LD	HL,(MULTI_DIAG_SCAN_BYTES)
	INC	HL
	LD	(MULTI_DIAG_SCAN_BYTES),HL
	POP	HL
	ENDIF
	CP	','
	JR	Z,.DELIM
	CP	':'
	JR	Z,.DELIM
	CP	13
	JR	Z,.DELIM
	CP	'0'
	JR	C,.ERROR
	CP	'9'+1
	JR	NC,.ERROR
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
.DELIM
	LD	(IPD_DELIM),A
	XOR	A
	RET
.TIMEOUT
	LD	A,RES_RS_TIMEOUT
	SCF
	RET
.ERROR
	LD	(IPD_BAD_CHAR),A
	LD	A,RES_ERROR
	SCF
	RET

; Append one ESP-AT link id digit to command buffer.
; In: A - link id, HL - destination end.
APPEND_LINK_ID
	ADD	A,'0'
	LD	(HL),A
	INC	HL
	XOR	A
	LD	(HL),A
	RET

; Enable or disable the runtime passive backend. The firmware profile says
; whether passive receive is supported; this latch says that FTP successfully
; configured it for the *current* session.
; In: A=0 active, A!=0 passive.
SET_PASSIVE_RECEIVE
	LD	(PASSIVE_RECEIVE_ENABLED),A
	RET

; Return CF=0 when ASCIIZ string at HL contains ASCIIZ substring at DE.
LINE_CONTAINS
	LD	A,(HL)
	AND	A
	JR	Z,.NO
	PUSH	HL
	PUSH	DE
.CMP
	LD	A,(DE)
	AND	A
	JR	Z,.FOUND
	LD	C,A
	LD	A,(HL)
	AND	A
	JR	Z,.RESTORE_NO
	CP	C
	JR	NZ,.RESTORE_NEXT
	INC	HL
	INC	DE
	JR	.CMP
.FOUND
	POP	DE
	POP	HL
	AND	A
	RET
.RESTORE_NEXT
	POP	DE
	POP	HL
	INC	HL
	JR	LINE_CONTAINS
.RESTORE_NO
	POP	DE
	POP	HL
.NO
	SCF
	RET

CMD_CIPSTART_LINK_PREFIX
	DB	"AT+CIPSTART=",0
CMD_CIPSTART_LINK_MIDDLE
	DB	",",34,"TCP",34,",",34,0
CMD_CIPSEND_LINK_PREFIX
	DB	"AT+CIPSEND=",0
CMD_CIPCLOSE_LINK_PREFIX
	DB	"AT+CIPCLOSE=",0
CMD_COMMA
	DB	",",0
CMD_CIPRECVDATA_PREFIX
	DB	"AT+CIPRECVDATA=",0
PASSIVE_DATA_PREFIX
	DB	"+CIPRECVDATA:",0

LINK_ID		DB 0
LAST_IPD_LINK	DB 0
PAYLOAD_LINK	DB 0
IPD_DELIM	DB 0
PASSIVE_RECEIVE_ENABLED DB 0
	IFNDEF	ESP_AT_FORCE_221
; State used only by RECEIVE_ANY_LINK_BURST. A parsed different-link payload or
; terminal result survives one return so the public receive ordering is exact.
MULTI_BURST_LINK DB 0xFF
MULTI_PENDING_RESULT DB 0
	ENDIF

	IFDEF	ESP_TCP_MULTI_DIAGNOSTICS
; FTP-only post-mortem state. No payload-byte instrumentation is used: the
; counters cover only the short +IPD header path and cannot throttle a transfer.
MULTI_DIAG_PHASE	DB 0		; 1=prefix scan, 2=link/length, 3=payload
MULTI_DIAG_SCAN_BYTES	DW 0
MULTI_DIAG_LAST_BYTE	DB 0

MULTI_DIAG_RESET
	XOR	A
	LD	(MULTI_DIAG_PHASE),A
	LD	(MULTI_DIAG_SCAN_BYTES),A
	LD	(MULTI_DIAG_SCAN_BYTES+1),A
	LD	(MULTI_DIAG_LAST_BYTE),A
	RET
	ENDIF

	ENDMODULE

	ENDIF
