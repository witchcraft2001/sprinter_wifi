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
	; here, the transport is not.
	LD	HL,TCP.TX_CMD_BUSY_RETRY
	CALL	STUB_OK
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

	JP	PASSED

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
	XOR	A
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

	END TEST_START
