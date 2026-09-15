; Host-side regression harness for the UNETESP multi-connection command
; builders. It assembles the REAL DLL source and calls UNET.MUX_OPEN /
; UNET.CLOSE_CHANNEL with the transmit step stubbed out, then checks the exact
; AT command left in TCP.CMD_BUFFER. A malformed AT+CIPSTART is invisible in a
; build log and shows up on hardware only as "connect failed", so the byte-level
; check belongs here. Run through tools/test-mux-cmd.sh.

	DEVICE NOSLOT64K

	INCLUDE "unetesp.asm"

TEST_RESULT	EQU 0xC000
TEST_MARKER	EQU 0xC001	; 0xA5 once the vector chain has actually run

; The driver follows the DLL image directly: sjasmplus --raw does not pad up to
; an ORG, so a gap here would shift the driver in the loaded file. Keep the
; base above the DLL's end; the guard below fails the build when the image
; grows past it (a truncated DS would silently overlap the driver instead).
DRIVER_BASE	EQU 0x4000
	ASSERT $ <= DRIVER_BASE
	DS DRIVER_BASE - $, 0
	ORG DRIVER_BASE

TEST_START
	LD	SP,0x7FF0
	XOR	A
	LD	(TEST_RESULT),A
	LD	(TEST_MARKER),A

	; Stub the steps that would talk to the UART with "XOR A / RET", i.e. a
	; successful transfer: the builders and the call flow are the subject
	; here, the transport is not. TCP.TX_CMD_BUSY_RETRY is single-connection-only
	; and gated out of the ESP_TCP_MUX build this harness assembles (MUX_OPEN
	; goes through MUX_TX_COMMAND instead), so there is nothing to stub here.
	; Unlike the other transport stubs, record UART_TX_STRING's input pointer.
	; MUX_TX_COMMAND performs parser setup before transmit, so a test that only
	; inspects CMD_BUFFER misses a clobbered HL and a command sent from 0x0000.
	LD	HL,WIFI.UART_TX_STRING
	LD	DE,UART_TX_SPY
	CALL	STUB_JP
	LD	HL,TCP.MUX_WAIT_SEND_OK
	CALL	STUB_OK
	LD	HL,TCP.MUX_CAPTURE_PENDING_PAYLOAD
	CALL	STUB_OK
	LD	HL,TCP.SEND_BUFFER
	LD	DE,FAKE_SEND_BUFFER
	CALL	STUB_JP
	CALL	TCP.RX_DEFER_RESET_ALL

	; Caller buffers must sit outside the DLL's own window; this image is
	; loaded at 0x0000, so stage the arguments in window 2.
	LD	HL,HOST_SRC
	LD	DE,HOST_STR
	LD	BC,HOST_SRC_END - HOST_SRC
	LDIR

; ------------------------------------------------------------------
; Vector 1: TCP open on channel 0.
; ------------------------------------------------------------------
	LD	A,1
	LD	(STAGE),A
	LD	A,0
	CALL	SET_CHANNEL
	LD	HL,HOST_STR
	LD	(UNET.ARG_DE),HL
	LD	HL,PORT_STR
	LD	(UNET.ARG_IX),HL
	XOR	A
	LD	(UNET.OPEN_MODE),A	; TCP
	CALL	UNET.MUX_OPEN
	LD	DE,EXP_TCP0
	CALL	CHECK_CMD

; ------------------------------------------------------------------
; Vector 2: TCP open on channel 1 (the passive-FTP data link).
; ------------------------------------------------------------------
	LD	A,2
	LD	(STAGE),A
	LD	A,1
	CALL	SET_CHANNEL
	LD	HL,HOST_STR
	LD	(UNET.ARG_DE),HL
	LD	HL,PORT2_STR
	LD	(UNET.ARG_IX),HL
	XOR	A
	LD	(UNET.OPEN_MODE),A
	CALL	UNET.MUX_OPEN
	LD	DE,EXP_TCP1
	CALL	CHECK_CMD

; ------------------------------------------------------------------
; Vector 3: UDP open with the per-channel default local port.
; ------------------------------------------------------------------
	LD	A,3
	LD	(STAGE),A
	LD	A,1
	CALL	SET_CHANNEL
	LD	HL,HOST_STR
	LD	(UNET.ARG_DE),HL
	LD	HL,PORT_STR
	LD	(UNET.ARG_IX),HL
	LD	A,1			; UDP, default local port
	LD	(UNET.OPEN_MODE),A
	CALL	UNET.MUX_OPEN
	LD	DE,EXP_UDP1
	CALL	CHECK_CMD

; ------------------------------------------------------------------
; Vector 4: UDP open with an explicit local port.
; ------------------------------------------------------------------
	LD	A,4
	LD	(STAGE),A
	LD	A,0
	CALL	SET_CHANNEL
	LD	HL,HOST_STR
	LD	(UNET.ARG_DE),HL
	LD	HL,PORT_STR
	LD	(UNET.ARG_IX),HL
	LD	HL,LPORT_STR
	LD	(UNET.ARG_IY),HL
	LD	A,2			; UDP, explicit local port
	LD	(UNET.OPEN_MODE),A
	CALL	UNET.MUX_OPEN
	LD	DE,EXP_UDP0
	CALL	CHECK_CMD

; ------------------------------------------------------------------
; Vector 5: per-channel close.
; ------------------------------------------------------------------
	LD	A,5
	LD	(STAGE),A
	LD	A,1
	CALL	SET_CHANNEL
	LD	A,1
	LD	(UNET.CH_STATE+1),A	; pretend channel 1 is open
	CALL	UNET.CLOSE_CHANNEL
	LD	DE,EXP_CLOSE1
	CALL	CHECK_CMD

; ------------------------------------------------------------------
; Vector 6: the public CONNECT entry accepts both channels, opens each
; independently, and rejects anything else.
; ------------------------------------------------------------------
	LD	A,6
	LD	(STAGE),A
	LD	A,1
	LD	(UNET.INITED),A
	LD	(UNET.MUX_ACTIVE),A
	XOR	A
	LD	(UNET.CH_STATE),A
	LD	(UNET.CH_STATE+1),A

	XOR	A			; channel 0
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	CALL	UNET.F_CONNECT
	AND	A
	JP	NZ,FAILED		; must be NERR_OK
	LD	A,(UNET.CH_STATE)
	CP	1			; TCP open
	JP	NZ,FAILED

	LD	A,1			; channel 1, while channel 0 stays open
	LD	DE,HOST_STR
	LD	IX,PORT2_STR
	CALL	UNET.F_CONNECT
	AND	A
	JP	NZ,FAILED
	LD	A,(UNET.CH_STATE+1)
	CP	1
	JP	NZ,FAILED

	LD	A,2			; out of range
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	CALL	UNET.F_CONNECT
	CP	NERR_PARAM
	JP	NZ,FAILED

	LD	A,0			; already open
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	CALL	UNET.F_CONNECT
	CP	NERR_STATE
	JP	NZ,FAILED

; ------------------------------------------------------------------
; Vector 7: STATUS reports each channel separately, and closing one
; leaves the other connected.
; ------------------------------------------------------------------
	LD	A,7
	LD	(STAGE),A
	LD	A,1
	CALL	UNET.F_STATUS
	LD	A,E
	AND	UNET_ST_CONN
	JP	Z,FAILED
	LD	A,1
	CALL	UNET.F_CLOSE
	AND	A
	JP	NZ,FAILED
	LD	A,1
	CALL	UNET.F_STATUS
	LD	A,E
	AND	UNET_ST_CONN
	JP	NZ,FAILED		; channel 1 is closed now
	XOR	A
	CALL	UNET.F_STATUS
	LD	A,E
	AND	UNET_ST_CONN
	JP	Z,FAILED		; channel 0 must be untouched

; ------------------------------------------------------------------
; Vector 8: an async SEND owns the UART parser. CLOSE on either channel must
; return BUSY without advancing/forgetting that SEND or closing local state.
; ------------------------------------------------------------------
	LD	A,8
	LD	(STAGE),A
	LD	A,0
	LD	(UNET.PEND_CH),A
	LD	A,1
	LD	(UNET.CH_STATE+1),A
	LD	A,1
	CALL	UNET.F_CLOSE
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	A,(UNET.PEND_CH)
	AND	A
	JP	NZ,FAILED		; transaction is still owned by channel 0
	LD	A,(UNET.CH_STATE+1)
	CP	1
	JP	NZ,FAILED		; CLOSE never reached the UART/local teardown
	LD	A,0xFF
	LD	(UNET.PEND_CH),A

; ------------------------------------------------------------------
; Vector 9: compact SEND diagnostics retain the transport reason and last
; complete response line without the removed byte-trace telemetry.
; ------------------------------------------------------------------
	LD	A,9
	LD	(STAGE),A
	LD	A,4
	LD	(UNET.SEND_RES),A
	LD	HL,LAST_LINE
	LD	DE,TCP.LINE_BUFFER
	LD	BC,LAST_LINE_LEN
	LDIR
	CALL	UNET.NOTE_SEND_FAILURE
	LD	HL,WIFI.RS_BUFF
	LD	DE,EXP_LASTERR
	CALL	CHECK_ASCIIZ

; ------------------------------------------------------------------
; Vector 10: a silent CONNECT must replace any partial/binary parser residue
; with a bounded textual LASTERR diagnostic.
; ------------------------------------------------------------------
	LD	A,10
	LD	(STAGE),A
	LD	A,RES_RS_TIMEOUT
	LD	(UNET.BUSY_LAST),A
	LD	HL,BINARY_LASTERR
	LD	DE,WIFI.RS_BUFF
	LD	BC,BINARY_LASTERR_LEN
	LDIR
	CALL	UNET.NOTE_CONNECT_FAILURE
	LD	HL,WIFI.RS_BUFF
	LD	DE,EXP_CONNECT_TIMEOUT
	CALL	CHECK_ASCIIZ

; A real ESP error remains more useful than the timeout fallback.
	LD	A,11
	LD	(STAGE),A
	LD	A,RES_ERROR
	LD	(UNET.BUSY_LAST),A
	LD	HL,LAST_ERROR
	LD	DE,WIFI.RS_BUFF
	LD	BC,LAST_ERROR_LEN
	LDIR
	CALL	UNET.NOTE_CONNECT_FAILURE
	LD	HL,WIFI.RS_BUFF
	LD	DE,LAST_ERROR
	CALL	CHECK_ASCIIZ

; ------------------------------------------------------------------
; Vector 12: LASTERR is live while healthy, then freezes the response at a
; SEND failure and survives a successful RECV that drains queued peer data.
; The fake transport completes one 2048-byte CIPSEND, then captures an HTTP
; response plus CLOSED while the next chunk is awaiting SEND OK.
; ------------------------------------------------------------------
	LD	A,12
	LD	(STAGE),A
	XOR	A
	LD	(UNET.LASTERR_FROZEN),A
	LD	HL,LIVE_STAGE_1
	LD	DE,WIFI.RS_BUFF
	LD	BC,LIVE_STAGE_1_LEN
	LDIR
	LD	DE,LASTERR_DEST
	LD	IX,32
	CALL	UNET.API_LASTERR
	AND	A
	JP	NZ,FAILED
	LD	HL,LASTERR_DEST
	LD	DE,LIVE_STAGE_1
	CALL	CHECK_ASCIIZ
	LD	A,121
	LD	(STAGE),A
	LD	HL,LIVE_STAGE_2
	LD	DE,WIFI.RS_BUFF
	LD	BC,LIVE_STAGE_2_LEN
	LDIR
	LD	DE,LASTERR_DEST
	LD	IX,32
	CALL	UNET.API_LASTERR
	AND	A
	JP	NZ,FAILED
	LD	HL,LASTERR_DEST
	LD	DE,LIVE_STAGE_2
	CALL	CHECK_ASCIIZ
	LD	A,122
	LD	(STAGE),A

	; A non-SEND failure also freezes LASTERR; successful calls leave it alone,
	; then the later SEND failure becomes the new snapshot.
	LD	HL,SETOPT_FAILURE
	LD	DE,WIFI.RS_BUFF
	LD	BC,SETOPT_FAILURE_LEN
	LDIR
	LD	A,0xFF			; unsupported option id -> NERR_PARAM
	LD	DE,0
	CALL	UNET.API_SETOPT
	CP	NERR_PARAM
	JP	NZ,FAILED
	LD	HL,LIVE_AFTER_SETOPT
	LD	DE,WIFI.RS_BUFF
	LD	BC,LIVE_AFTER_SETOPT_LEN
	LDIR
	CALL	UNET.API_GETCAPS
	AND	A
	JP	NZ,FAILED
	LD	DE,LASTERR_DEST
	LD	IX,32
	CALL	UNET.API_LASTERR
	AND	A
	JP	NZ,FAILED
	LD	HL,LASTERR_DEST
	LD	DE,SETOPT_FAILURE
	CALL	CHECK_ASCIIZ

	XOR	A
	LD	(UNET.CH_STATE+1),A
	LD	A,1
	LD	(UNET.CH_STATE),A
	LD	(UNET.MUX_ACTIVE),A
	LD	A,0
	CALL	TCP.MUX_CLEAR_CLOSED
	CALL	TCP.RX_DEFER_RESET_CH
	LD	HL,TCP.MUX_LINK_MAP
	LD	(HL),0
	XOR	A
	LD	(FAKE_SEND_CALLS),A
	LD	HL,ESP_CLOSED_LINE
	LD	DE,TCP.LINE_BUFFER
	LD	BC,ESP_CLOSED_LINE_LEN
	LDIR
	LD	A,0
	LD	DE,SEND_BUFFER
	LD	IX,2050
	CALL	UNET.API_SEND
	CP	NERR_CLOSED
	JP	NZ,FAILED
	LD	HL,2048
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,FAILED		; only the complete SEND OK block is confirmed
	LD	A,123
	LD	(STAGE),A

	XOR	A
	CALL	UNET.API_STATUS
	AND	A
	JP	NZ,FAILED
	LD	A,E
	AND	UNET_ST_CONN | UNET_ST_RXPEND
	CP	UNET_ST_CONN | UNET_ST_RXPEND
	JP	NZ,FAILED
	LD	A,124
	LD	(STAGE),A

	XOR	A
	LD	DE,RECV_BUFFER
	LD	IX,64
	LD	IY,1
	CALL	UNET.API_RECV
	AND	A
	JP	NZ,FAILED
	LD	HL,HTTP_RESPONSE
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,FAILED
	LD	HL,RECV_BUFFER
	LD	DE,HTTP_TEXT
	CALL	CHECK_ASCIIZ_PREFIX
	LD	A,125
	LD	(STAGE),A

	; The error snapshot must survive the successful RECV above and this
	; successful GETCAPS call, even though WIFI.RS_BUFF is changed in between.
	LD	HL,LIVE_AFTER_SEND
	LD	DE,WIFI.RS_BUFF
	LD	BC,LIVE_AFTER_SEND_LEN
	LDIR
	CALL	UNET.API_GETCAPS
	AND	A
	JP	NZ,FAILED
	LD	A,126
	LD	(STAGE),A
	LD	DE,LASTERR_DEST
	LD	IX,32
	CALL	UNET.API_LASTERR
	AND	A
	JP	NZ,FAILED
	LD	A,127
	LD	(STAGE),A
	LD	HL,LASTERR_DEST
	LD	DE,EXP_SEND_LASTERR
	CALL	CHECK_ASCIIZ
	LD	A,128
	LD	(STAGE),A

	XOR	A
	LD	DE,RECV_BUFFER
	LD	IX,64
	LD	IY,1
	CALL	UNET.API_RECV
	CP	NERR_CLOSED
	JP	NZ,FAILED
	LD	A,D
	OR	E
	JP	NZ,FAILED
	LD	A,(UNET.CH_STATE)
	AND	A
	JP	NZ,FAILED
	XOR	A
	CALL	UNET.API_CLOSE
	AND	A
	JP	NZ,FAILED		; CLOSE after RECV->CLOSED is idempotent
	XOR	A
	CALL	UNET.API_STATUS
	AND	A
	JP	NZ,FAILED
	LD	A,E
	AND	UNET_ST_CONN | UNET_ST_RXPEND
	JP	NZ,FAILED		; no connected state or queued bytes remain
	LD	A,129
	LD	(STAGE),A

; ------------------------------------------------------------------
; Vector 13: if the peer's CLOSED is parsed after the full current chunk has
; returned SEND OK, that SEND still succeeds. The next RECV drains data and
; reports the close in the ordinary order.
; ------------------------------------------------------------------
	LD	A,13
	LD	(STAGE),A
	LD	A,1
	LD	(UNET.CH_STATE),A
	XOR	A
	CALL	TCP.MUX_CLEAR_CLOSED
	CALL	TCP.RX_DEFER_RESET_CH
	LD	HL,TCP.MUX_LINK_MAP
	LD	(HL),0
	LD	A,1
	LD	(FAKE_SEND_FULL_ACK),A
	LD	A,0
	LD	DE,SEND_BUFFER
	LD	IX,HTTP_TEXT_LEN
	CALL	UNET.API_SEND
	AND	A
	JP	NZ,FAILED
	LD	A,131
	LD	(STAGE),A
	LD	HL,HTTP_TEXT_LEN
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,FAILED		; SEND OK confirms the entire final chunk
	LD	A,132
	LD	(STAGE),A
	XOR	A
	CALL	UNET.API_STATUS
	AND	A
	JP	NZ,FAILED
	LD	A,E
	AND	UNET_ST_CONN | UNET_ST_RXPEND
	CP	UNET_ST_CONN | UNET_ST_RXPEND
	JP	NZ,FAILED
	LD	DE,LASTERR_DEST
	LD	IX,64
	CALL	UNET.API_LASTERR
	AND	A
	JP	NZ,FAILED
	LD	HL,LASTERR_DEST
	LD	DE,EXP_CLOSED_RECV_LASTERR
	CALL	CHECK_ASCIIZ		; successful SEND did not replace the snapshot
	LD	A,133
	LD	(STAGE),A

	XOR	A
	LD	DE,RECV_BUFFER
	LD	IX,64
	LD	IY,1
	CALL	UNET.API_RECV
	AND	A
	JP	NZ,FAILED
	LD	HL,HTTP_TEXT_LEN
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,FAILED
	LD	HL,RECV_BUFFER
	LD	DE,HTTP_TEXT
	CALL	CHECK_ASCIIZ_PREFIX
	LD	A,134
	LD	(STAGE),A
	XOR	A
	LD	DE,RECV_BUFFER
	LD	IX,64
	LD	IY,1
	CALL	UNET.API_RECV
	CP	NERR_CLOSED
	JP	NZ,FAILED
	LD	A,D
	OR	E
	JP	NZ,FAILED
	XOR	A
	CALL	UNET.API_CLOSE
	AND	A
	JP	NZ,FAILED		; idempotent after close was observed
	LD	A,135
	LD	(STAGE),A

; ------------------------------------------------------------------
; Vector 14: the real CLOSE_CHANNEL always releases the channel and reports
; what the peer can be known to have learned (UNET CLOSE contract). Every
; unconfirmed close marks its firmware link stale, and MUX_ALLOC_LINK must not
; hand that link to the next CIPSTART.
; ------------------------------------------------------------------
	LD	A,14
	LD	(STAGE),A
	LD	HL,TCP.MUX_WAIT_SEND_OK
	LD	DE,FAKE_WAIT
	CALL	STUB_JP
	LD	HL,TCP.MUX_CAPTURE_PENDING_PAYLOAD
	LD	DE,FAKE_CAPTURE
	CALL	STUB_JP
	XOR	A
	LD	(UNET.CH_STATE),A
	LD	A,0xFF
	LD	(TCP.MUX_LISTEN_CH),A
	LD	(TCP.MUX_LINK_MAP),A

	; 14.1: CIPCLOSE went out, the ESP stayed silent -> NERR_TIMEOUT.
	LD	A,141
	LD	(STAGE),A
	LD	A,RES_RS_TIMEOUT
	LD	B,1			; link 1
	CALL	CLOSE_CH1_WITH
	CP	NERR_TIMEOUT
	JP	NZ,FAILED
	LD	DE,EXP_CLOSE1
	CALL	CHECK_CMD		; the command really was transmitted
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	; The stale link 1 is skipped: channel 1 reopens on link 0, not identity.
	LD	A,1
	CALL	TCP.MUX_ALLOC_LINK
	LD	A,(TCP.LINK_ID)
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_LINK_MAP+1)
	AND	A
	JP	NZ,FAILED
	; Two stale links (0,1) and channel 0 unmapped: the next free id is 2.
	LD	A,0x03
	LD	(TCP.MUX_STALE_LINKS),A
	LD	A,1
	CALL	TCP.MUX_ALLOC_LINK
	LD	A,(TCP.LINK_ID)
	CP	2
	JP	NZ,FAILED

	; 14.2: CLOSE on an already closed channel is idempotent: 0, no UART.
	LD	A,142
	LD	(STAGE),A
	XOR	A
	LD	(UNET.CH_STATE+1),A
	LD	HL,0
	LD	(UART_CALL_PTR),HL
	LD	A,1
	CALL	SET_CHANNEL
	CALL	UNET.CLOSE_CHANNEL
	JP	C,FAILED
	AND	A
	JP	NZ,FAILED
	LD	HL,(UART_CALL_PTR)
	LD	A,H
	OR	L
	JP	NZ,FAILED

	; 14.3: "busy p..." rejected CIPCLOSE -> NERR_BUSY, channel still released,
	; stale bit taken from the mapped link (3), not from the channel number.
	LD	A,143
	LD	(STAGE),A
	LD	A,RES_BUSY
	LD	B,3
	CALL	CLOSE_CH1_WITH
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x08
	JP	NZ,FAILED

	; 14.4: the user cancelled the wait -> NERR_CANCEL, cancel flag consumed.
	LD	A,144
	LD	(STAGE),A
	LD	A,1
	LD	(WCOMMON.CANCELLED),A
	LD	A,RES_RS_TIMEOUT
	LD	B,4
	CALL	CLOSE_CH1_WITH
	CP	NERR_CANCEL
	JP	NZ,FAILED
	LD	A,(WCOMMON.CANCELLED)
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x10
	JP	NZ,FAILED

	; 14.5: the command never left the 16550 -> NERR_HW.
	LD	A,145
	LD	(STAGE),A
	LD	A,1
	LD	(FAKE_TX_FAIL),A
	XOR	A
	LD	B,1
	CALL	CLOSE_CH1_WITH
	CP	NERR_HW
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	XOR	A
	LD	(FAKE_TX_FAIL),A

	; 14.6: an explicit ERROR is an answer (the link is already gone) -> 0,
	; nothing stale.
	LD	A,146
	LD	(STAGE),A
	LD	A,RES_ERROR
	LD	B,1
	CALL	CLOSE_CH1_WITH
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	AND	A
	JP	NZ,FAILED

	; 14.7: a partial +IPD payload still on the wire: no AT text may be sent,
	; the channel is released anyway and reports NERR_BUSY.
	LD	A,147
	LD	(STAGE),A
	LD	A,1
	LD	(FAKE_CAPTURE_FAIL),A
	LD	HL,0
	LD	(UART_CALL_PTR),HL
	XOR	A
	LD	B,1
	CALL	CLOSE_CH1_WITH
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	HL,(UART_CALL_PTR)
	LD	A,H
	OR	L
	JP	NZ,FAILED		; CIPCLOSE was not transmitted
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	XOR	A
	LD	(FAKE_CAPTURE_FAIL),A
	LD	(TCP.MUX_STALE_LINKS),A

; ------------------------------------------------------------------
; Vector 15: CLOSE_LINK closes both channels in order 0,1 whatever the first
; one returned, reports the second channel's status when non-zero, else the
; first one's, and restores ARG_CH. CLOSE_CHANNEL is mocked from here on.
; ------------------------------------------------------------------
	LD	A,15
	LD	(STAGE),A
	LD	HL,UNET.CLOSE_CHANNEL
	LD	DE,MOCK_CLOSE
	CALL	STUB_JP
	LD	HL,CLOSE_LINK_CASES
	LD	B,CLOSE_LINK_CASE_COUNT
	LD	C,151
.close_link_case
	PUSH	BC
	LD	A,C
	LD	(STAGE),A
	CALL	CLOSE_LINK_CASE
	POP	BC
	INC	C
	DJNZ	.close_link_case

; ------------------------------------------------------------------
; Vector 16: NETDONE returns the close status and still completes the
; teardown: the stale-link sweep precedes CIPMUX=0, a forced listener is
; dropped, and a non-zero status freezes LASTERR through API_RETURN.
; ------------------------------------------------------------------
	LD	A,16
	LD	(STAGE),A
	LD	HL,WIFI.UART_TX_CMD
	LD	DE,UART_CMD_SPY
	CALL	STUB_JP
	LD	A,1
	LD	(UNET.INITED),A
	XOR	A
	LD	(UNET.RX_PAUSED),A
	LD	(UNET.CH_STATE),A
	LD	(UNET.CH_STATE+1),A
	LD	(TCP.MUX_STALE_LINKS),A
	LD	HL,0
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	A,0xFF
	LD	(UNET.PEND_CH),A
	LD	(TCP.MUX_LISTEN_CH),A

	; 16.1: the SNC report case - first close BUSY, second OK. The old code
	; returned the saved ARG_CH (0) here, i.e. a false success.
	LD	A,161
	LD	(STAGE),A
	LD	DE,NERR_BUSY		; D = ch1 status, E = ch0 status
	CALL	NETDONE_WITH
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPMUX0
	CALL	CHECK_LOG1
	LD	A,(UNET.MUX_ACTIVE)
	AND	A
	JP	NZ,FAILED

	; 16.2: both closes OK with ARG_CH=1 - the old code reported NERR_HW.
	LD	A,162
	LD	(STAGE),A
	LD	A,1
	LD	(UNET.ARG_CH),A
	LD	DE,0
	CALL	NETDONE_WITH
	AND	A
	JP	NZ,FAILED
	LD	A,(UNET.ARG_CH)
	CP	1
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPMUX0
	CALL	CHECK_LOG1

	; 16.3: an unconfirmed close left link 1 stale: CIPCLOSE=5 first, then
	; CIPMUX=0; the failing channel's status is still returned.
	LD	A,163
	LD	(STAGE),A
	LD	A,0x02
	LD	(TCP.MUX_STALE_LINKS),A
	LD	DE,NERR_TIMEOUT << 8
	CALL	NETDONE_WITH
	CP	NERR_TIMEOUT
	JP	NZ,FAILED
	LD	HL,(CMD_LOG_PTR)
	LD	DE,CMD_LOG+4
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED
	LD	HL,(CMD_LOG)
	LD	DE,UNET.CMD_CIPCLOSE_ALL
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED
	LD	HL,CMD_LOG+2
	LD	DE,UNET.CMD_CIPMUX0
	CALL	CHECK_LOG_AT
	LD	A,(TCP.MUX_STALE_LINKS)
	AND	A
	JP	NZ,FAILED

	; 16.4: an unread +IPD tail that an earlier CLOSE could not rescue is
	; retried by NETDONE itself. While it cannot be read: no AT text at all,
	; CIPMUX stays armed and NETDONE says NERR_BUSY even though both channels
	; are already closed (a repeated NETDONE must not claim success).
	LD	A,164
	LD	(STAGE),A
	LD	A,1
	LD	(FAKE_CAPTURE_FAIL),A
	LD	DE,0
	CALL	NETDONE_WITH
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	HL,(CMD_LOG_PTR)
	LD	DE,CMD_LOG
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED
	LD	A,(UNET.MUX_ACTIVE)
	AND	A
	JP	Z,FAILED
	; Once the tail is rescued the same NETDONE completes normally.
	XOR	A
	LD	(FAKE_CAPTURE_FAIL),A
	LD	DE,0
	CALL	NETDONE_WITH
	AND	A
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPMUX0
	CALL	CHECK_LOG1

	; 16.7: a sweep the ESP does not answer keeps the stale mask (the ids
	; must stay off-limits) and reports NERR_BUSY; an ERROR answer (nothing
	; was open) counts as done.
	LD	A,167
	LD	(STAGE),A
	LD	A,0x02
	LD	(TCP.MUX_STALE_LINKS),A
	LD	A,RES_RS_TIMEOUT
	LD	(FAKE_CMD_RES),A
	LD	DE,0
	CALL	NETDONE_WITH
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPCLOSE_ALL
	CALL	CHECK_LOG1		; and no CIPMUX=0 after it
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	LD	A,(UNET.MUX_ACTIVE)
	AND	A
	JP	Z,FAILED
	LD	A,RES_ERROR
	LD	(FAKE_CMD_RES),A
	LD	DE,0
	CALL	NETDONE_WITH
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	AND	A
	JP	NZ,FAILED
	LD	HL,CMD_LOG+2
	LD	DE,UNET.CMD_CIPMUX0
	CALL	CHECK_LOG_AT
	XOR	A
	LD	(FAKE_CMD_RES),A

	; 16.5: an armed listener is forced down before CIPMUX=0.
	LD	A,165
	LD	(STAGE),A
	XOR	A
	LD	(TCP.MUX_LISTEN_CH),A
	LD	A,3
	LD	(UNET.CH_STATE),A
	LD	DE,0
	CALL	NETDONE_WITH
	AND	A
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPSERVER_OFF
	CALL	CHECK_LOG_AT
	LD	HL,CMD_LOG+2
	LD	DE,UNET.CMD_CIPMUX0
	CALL	CHECK_LOG_AT
	LD	A,(UNET.CH_STATE)
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_LISTEN_CH)
	CP	0xFF
	JP	NZ,FAILED

	; 16.6: through the public entry a failing NETDONE freezes LASTERR.
	LD	A,166
	LD	(STAGE),A
	XOR	A
	LD	(UNET.LASTERR_FROZEN),A
	LD	A,1
	LD	(UNET.MUX_ACTIVE),A
	LD	HL,MOCK_LOG
	LD	(MOCK_LOG_PTR),HL
	LD	HL,CMD_LOG
	LD	(CMD_LOG_PTR),HL
	LD	HL,NERR_CANCEL
	LD	(MOCK_STATUS),HL
	CALL	UNET.API_NETDONE
	JP	C,FAILED
	CP	NERR_CANCEL
	JP	NZ,FAILED
	LD	A,(UNET.LASTERR_FROZEN)
	AND	A
	JP	Z,FAILED

; ------------------------------------------------------------------
; Vector 17: a leaked link is swept by the next open while nothing is up
; (CIPCLOSE=5 before CIPMUX=1), never while a channel is live, and the
; allocator steers around it until then.
; ------------------------------------------------------------------
	LD	A,17
	LD	(STAGE),A
	LD	A,0x02
	LD	(TCP.MUX_STALE_LINKS),A
	XOR	A
	LD	(UNET.MUX_ACTIVE),A
	; The ESP stays silent on the sweep: CONNECT is refused as busy, the
	; channel stays closed and the stale id is still remembered.
	LD	A,RES_RS_TIMEOUT
	LD	(FAKE_CMD_RES),A
	LD	HL,CMD_LOG
	LD	(CMD_LOG_PTR),HL
	XOR	A
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	CALL	UNET.F_CONNECT
	CP	NERR_BUSY
	JP	NZ,FAILED
	LD	A,(UNET.CH_STATE)
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPCLOSE_ALL
	CALL	CHECK_LOG1
	XOR	A
	LD	(FAKE_CMD_RES),A
	LD	HL,CMD_LOG
	LD	(CMD_LOG_PTR),HL
	XOR	A
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	CALL	UNET.F_CONNECT
	AND	A
	JP	NZ,FAILED
	LD	A,171
	LD	(STAGE),A
	LD	HL,(CMD_LOG_PTR)
	LD	DE,CMD_LOG+4
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED
	LD	HL,CMD_LOG
	LD	DE,UNET.CMD_CIPCLOSE_ALL
	CALL	CHECK_LOG_AT
	LD	HL,CMD_LOG+2
	LD	DE,UNET.CMD_CIPMUX1
	CALL	CHECK_LOG_AT
	LD	A,(TCP.MUX_STALE_LINKS)
	AND	A
	JP	NZ,FAILED
	LD	DE,EXP_TCP0
	CALL	CHECK_CMD		; swept first, so identity link 0 was free
	LD	A,172
	LD	(STAGE),A
	; Channel 0 is live now: a stale link 1 is neither swept nor handed to
	; channel 1, which opens on the next free id instead.
	LD	A,0x02
	LD	(TCP.MUX_STALE_LINKS),A
	LD	HL,CMD_LOG
	LD	(CMD_LOG_PTR),HL
	LD	A,1
	LD	DE,HOST_STR
	LD	IX,PORT2_STR
	CALL	UNET.F_CONNECT
	AND	A
	JP	NZ,FAILED
	LD	HL,(CMD_LOG_PTR)
	LD	DE,CMD_LOG
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED		; no AT command besides CIPSTART
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	LD	DE,EXP_TCP1_LINK2
	CALL	CHECK_CMD
	XOR	A
	LD	(UNET.CH_STATE),A
	LD	(UNET.CH_STATE+1),A
	LD	(TCP.MUX_STALE_LINKS),A
	LD	HL,TCP.MUX_LINK_MAP
	LD	(HL),0xFF
	INC	HL
	LD	(HL),0xFF

; ------------------------------------------------------------------
; Vector 18: an inbound CONNECT landing on a stale link proves the firmware
; freed it - the accept clears its stale bit and nothing else.
; ------------------------------------------------------------------
	LD	A,18
	LD	(STAGE),A
	LD	A,0x0A			; links 1 and 3 stale
	LD	(TCP.MUX_STALE_LINKS),A
	LD	A,1
	LD	(TCP.MUX_LISTEN_CH),A
	LD	A,3
	CALL	TCP.MUX_TRY_ACCEPT
	LD	A,(TCP.MUX_LINK_MAP+1)
	CP	3
	JP	NZ,FAILED
	LD	A,(TCP.MUX_STALE_LINKS)
	CP	0x02
	JP	NZ,FAILED
	LD	A,0xFF
	LD	(TCP.MUX_LISTEN_CH),A

	JP	PASSED

; In: A = fake MUX_WAIT_SEND_OK result (0 = OK), B = firmware link mapped to
; channel 1. Opens channel 1 on that link and runs the real CLOSE_CHANNEL.
; Out: A = close status; fails the test on CF=1 or when channel 1 or its map
; entry was not released.
CLOSE_CH1_WITH
	LD	(FAKE_WAIT_RES),A
	LD	A,B
	LD	(TCP.MUX_LINK_MAP+1),A
	XOR	A
	LD	(TCP.MUX_STALE_LINKS),A
	LD	A,1
	LD	(UNET.CH_STATE+1),A
	CALL	SET_CHANNEL
	CALL	UNET.CLOSE_CHANNEL
	JP	C,FAILED
	LD	B,A
	LD	A,(UNET.CH_STATE+1)
	AND	A
	JP	NZ,FAILED
	LD	A,(TCP.MUX_LINK_MAP+1)
	CP	0xFF
	JP	NZ,FAILED
	XOR	A
	LD	(FAKE_WAIT_RES),A
	LD	A,B
	RET

; In: HL = case {ch0 status, ch1 status, expected}. Runs it with ARG_CH=0
; and again with ARG_CH=1. Out: HL = next case.
CLOSE_LINK_CASE
	LD	A,(HL)
	LD	(MOCK_STATUS),A
	INC	HL
	LD	A,(HL)
	LD	(MOCK_STATUS+1),A
	INC	HL
	LD	A,(HL)
	LD	(MOCK_EXPECT),A
	INC	HL
	PUSH	HL
	XOR	A
	CALL	.one
	LD	A,1
	CALL	.one
	POP	HL
	RET
.one
	LD	(UNET.ARG_CH),A
	LD	(MOCK_ARG),A
	LD	HL,MOCK_LOG
	LD	(MOCK_LOG_PTR),HL
	CALL	UNET.CLOSE_LINK
	JP	C,FAILED
	LD	B,A
	LD	A,(MOCK_EXPECT)
	CP	B
	JP	NZ,FAILED
	LD	A,(MOCK_ARG)
	LD	B,A
	LD	A,(UNET.ARG_CH)
	CP	B
	JP	NZ,FAILED		; ARG_CH restored
	LD	HL,(MOCK_LOG_PTR)
	LD	DE,MOCK_LOG+2
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED		; exactly two closes
	LD	A,(MOCK_LOG)
	AND	A
	JP	NZ,FAILED
	LD	A,(MOCK_LOG+1)
	CP	1
	JP	NZ,FAILED		; channel 0 first, then channel 1
	RET

; In: E = channel 0 close status, D = channel 1 close status. Clears both
; logs, re-arms CIPMUX and calls F_NETDONE. Out: A = NETDONE result (CF=1
; fails the test).
NETDONE_WITH
	LD	(MOCK_STATUS),DE
	LD	HL,MOCK_LOG
	LD	(MOCK_LOG_PTR),HL
	LD	HL,CMD_LOG
	LD	(CMD_LOG_PTR),HL
	LD	A,1
	LD	(UNET.MUX_ACTIVE),A
	CALL	UNET.F_NETDONE
	JP	C,FAILED
	RET

; In: HL = log, DE = the only command expected in it.
CHECK_LOG1
	PUSH	HL
	LD	HL,(CMD_LOG_PTR)
	PUSH	DE
	LD	DE,CMD_LOG+2
	OR	A
	SBC	HL,DE
	POP	DE
	POP	HL
	JP	NZ,FAILED
; In: HL = log slot, DE = command expected there.
CHECK_LOG_AT
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED
	RET

; CLOSE_CHANNEL mock: log the channel, return MOCK_STATUS[channel], clobber BC
; like the real routine may.
MOCK_CLOSE
	LD	A,(UNET.ARG_CH)
	LD	HL,(MOCK_LOG_PTR)
	LD	(HL),A
	INC	HL
	LD	(MOCK_LOG_PTR),HL
	LD	HL,MOCK_STATUS
	LD	C,A
	LD	B,0
	ADD	HL,BC
	LD	A,(HL)
	LD	BC,0xA55A
	OR	A
	RET

; WIFI.UART_TX_CMD spy for SEND_AT_BUSY: log the command pointer, answer with
; FAKE_CMD_RES (0 = OK) under the RES_*/CF contract, with an empty response
; line so SEND_AT_BUSY never mistakes it for "busy" and retries.
UART_CMD_SPY
	PUSH	DE
	EX	DE,HL
	LD	HL,(CMD_LOG_PTR)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	(CMD_LOG_PTR),HL
	EX	DE,HL
	POP	DE
	XOR	A
	LD	(WIFI.RS_BUFF),A
	LD	A,(FAKE_CMD_RES)
	AND	A
	RET	Z
	SCF
	RET

FAKE_WAIT
	LD	A,(FAKE_WAIT_RES)
	AND	A
	RET	Z
	SCF
	RET

FAKE_CAPTURE
	LD	A,(FAKE_CAPTURE_FAIL)
	AND	A
	RET	Z
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

; Fake one SEND OK, then capture one frame and latch an orderly peer close.
; The payload is queued in the real per-channel defer window; the failure path
; must leave it intact for the real RECEIVE_MUX / F_RECV code below.
FAKE_SEND_BUFFER
	LD	A,(FAKE_SEND_FULL_ACK)
	AND	A
	JR	NZ,.full_ack
	LD	A,(FAKE_SEND_CALLS)
	AND	A
	JR	NZ,.close_now
	INC	A
	LD	(FAKE_SEND_CALLS),A
	XOR	A
	RET
.close_now
	CALL	FAKE_QUEUE_CLOSE
	LD	A,RES_FAIL
	SCF
	RET
.full_ack
	CALL	FAKE_QUEUE_CLOSE
	XOR	A
	RET

FAKE_QUEUE_CLOSE
	LD	A,(UNET.ARG_CH)
	CALL	TCP.RX_DEFER_RESET_CH
	LD	A,(UNET.ARG_CH)
	CALL	TCP.DEFER_SELECT
	LD	HL,(TCP.DEFER_BASE)
	LD	A,HTTP_RESPONSE & 0xFF
	LD	(HL),A
	INC	HL
	XOR	A
	LD	(HL),A
	INC	HL
	LD	DE,HTTP_TEXT
	LD	BC,HTTP_TEXT_LEN
	LDIR
	LD	HL,HTTP_TEXT_LEN+2
	LD	(TCP.DEFER_W),HL
	LD	HL,0
	LD	(TCP.DEFER_R),HL
	LD	(TCP.DEFER_FRAME_LEFT),HL
	LD	A,(UNET.ARG_CH)
	CALL	TCP.MUX_LATCH_CLOSED
	RET

; Patch the routine at HL with "XOR A / RET" (success, CF=0).
STUB_OK
	LD	(HL),0xAF
	INC	HL
	LD	(HL),0xC9
	RET

; Patch the routine at HL with "JP DE".
STUB_JP
	LD	(HL),0xC3
	INC	HL
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

UART_TX_SPY
	LD	(UART_CALL_PTR),HL
	LD	A,(FAKE_TX_FAIL)
	AND	A
	RET	Z
	SCF				; transmitter never became ready
	RET

FAILED
	LD	A,(STAGE)
	LD	(TEST_RESULT),A
PASSED
	LD	A,0xA5
	LD	(TEST_MARKER),A
	JR	TEST_DONE
STAGE	DB 0
UART_CALL_PTR	DW 0

TEST_DONE
	HALT

; In: A = channel. Sets the argument the DLL functions read.
SET_CHANNEL
	LD	(UNET.ARG_CH),A
	RET

; Compare TCP.CMD_BUFFER with the ASCIIZ string at DE.
CHECK_CMD
	LD	HL,(UART_CALL_PTR)
	LD	BC,TCP.CMD_BUFFER
	AND	A
	SBC	HL,BC
	JP	NZ,FAILED
	LD	HL,TCP.CMD_BUFFER
.loop
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAILED
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	.loop

; Compare ASCIIZ at HL with ASCIIZ at DE.
CHECK_ASCIIZ
.loop
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAILED
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	.loop

; Compare a known-length prefix at HL with ASCIIZ at DE.
CHECK_ASCIIZ_PREFIX
.loop
	LD	A,(DE)
	AND	A
	RET	Z
	CP	(HL)
	JP	NZ,FAILED
	INC	HL
	INC	DE
	JR	.loop

; Argument strings, staged into window 2 at startup (see HOST_STR below).
HOST_SRC	DB "192.168.1.36",0
	DS 20 - ($ - HOST_SRC),0
	DB "9099",0
	DS 40 - ($ - HOST_SRC),0
	DB "9100",0
	DS 60 - ($ - HOST_SRC),0
	DB "5000",0
	DS 80 - ($ - HOST_SRC),0
HOST_SRC_END

HOST_STR	EQU 0x8000
PORT_STR	EQU HOST_STR + 20
PORT2_STR	EQU HOST_STR + 40
LPORT_STR	EQU HOST_STR + 60

EXP_TCP0	DB "AT+CIPSTART=0,",34,"TCP",34,",",34,"192.168.1.36",34,",9099",13,10,0
EXP_TCP1	DB "AT+CIPSTART=1,",34,"TCP",34,",",34,"192.168.1.36",34,",9100",13,10,0
EXP_TCP1_LINK2	DB "AT+CIPSTART=2,",34,"TCP",34,",",34,"192.168.1.36",34,",9100",13,10,0
EXP_UDP1	DB "AT+CIPSTART=1,",34,"UDP",34,",",34,"192.168.1.36",34,",9099,1070,2",13,10,0
EXP_UDP0	DB "AT+CIPSTART=0,",34,"UDP",34,",",34,"192.168.1.36",34,",9099,5000,2",13,10,0
EXP_CLOSE1	DB "AT+CIPCLOSE=1",13,10,0
LAST_LINE	DB "OK",0
LAST_LINE_LEN	EQU $-LAST_LINE
EXP_LASTERR	DB "send failed 4: OK",0
BINARY_LASTERR	DB 0x91,0x02,0xFF,0
BINARY_LASTERR_LEN EQU $-BINARY_LASTERR
LAST_ERROR	DB "ERROR",0
LAST_ERROR_LEN	EQU $-LAST_ERROR
EXP_CONNECT_TIMEOUT DB "connect failed: no ESP response",0
LIVE_STAGE_1 DB "stage=NETINIT",0
LIVE_STAGE_1_LEN EQU $-LIVE_STAGE_1
LIVE_STAGE_2 DB "stage=CONNECT",0
LIVE_STAGE_2_LEN EQU $-LIVE_STAGE_2
SETOPT_FAILURE DB "setopt failed",0
SETOPT_FAILURE_LEN EQU $-SETOPT_FAILURE
LIVE_AFTER_SETOPT DB "successful GETCAPS",0
LIVE_AFTER_SETOPT_LEN EQU $-LIVE_AFTER_SETOPT
LIVE_AFTER_SEND DB "successful RECV overwrote RS_BUFF",0
LIVE_AFTER_SEND_LEN EQU $-LIVE_AFTER_SEND
EXP_CLOSED_RECV_LASTERR DB "successful RECV overwrote RS_BUFF",0
EXP_SEND_LASTERR DB "send failed 2: 0,CLOSED",0
ESP_CLOSED_LINE DB "0,CLOSED",0
ESP_CLOSED_LINE_LEN EQU $-ESP_CLOSED_LINE
HTTP_TEXT DB "HTTP/1.1 400",0
HTTP_TEXT_LEN EQU $-HTTP_TEXT-1
HTTP_RESPONSE EQU HTTP_TEXT_LEN
FAKE_SEND_CALLS DB 0
FAKE_TX_FAIL	DB 0
FAKE_WAIT_RES	DB 0
FAKE_CAPTURE_FAIL DB 0
FAKE_CMD_RES	DB 0
MOCK_STATUS	DB 0,0		; CLOSE_CHANNEL mock result for channel 0, 1
MOCK_EXPECT	DB 0
MOCK_ARG	DB 0
MOCK_LOG_PTR	DW 0
MOCK_LOG	DS 4,0
CMD_LOG_PTR	DW 0
CMD_LOG		DS 8,0
; {channel 0 status, channel 1 status, expected CLOSE_LINK result}
CLOSE_LINK_CASES
	DB 0,0,0
	DB NERR_BUSY,0,NERR_BUSY
	DB 0,NERR_BUSY,NERR_BUSY
	DB NERR_HW,NERR_TIMEOUT,NERR_TIMEOUT
	DB NERR_CANCEL,0,NERR_CANCEL
CLOSE_LINK_CASE_COUNT EQU ($-CLOSE_LINK_CASES)/3
FAKE_SEND_FULL_ACK DB 0
SEND_BUFFER EQU 0x8000
RECV_BUFFER EQU 0x8800
LASTERR_DEST EQU 0x8900

	END TEST_START
