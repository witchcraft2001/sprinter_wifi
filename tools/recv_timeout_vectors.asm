; Host-side regression vectors for BUGREPORT-RECV-IY0-HANG.
; The harness assembles the real UNETESP DLL, calls its public F_RECV entry
; with IY=0, and exercises the common UART byte reader with BC=0. The old
; implementation wrapped BC to 0xFFFF and did not return for about 65 seconds.

	DEVICE NOSLOT64K

	INCLUDE "unetesp.asm"

TEST_RESULT	EQU 0xBFE0
TEST_MARKER	EQU 0xBFE1	; 0xA5 once all vectors have run

DRIVER_BASE	EQU 0x4000
	ASSERT $ <= DRIVER_BASE
	DS DRIVER_BASE - $, 0
	ORG DRIVER_BASE

TEST_START
	LD	SP,0x7FF0
	XOR	A
	LD	(TEST_RESULT),A
	LD	(TEST_MARKER),A

	; Replace the transport body so this vector observes exactly which timeout
	; the ABI layer passes down without needing an emulated ESP.
	LD	HL,TCP.RECEIVE_MUX
	LD	DE,RECEIVE_SPY
	CALL	STUB_JP
	LD	A,1
	LD	(UNET.CH_STATE),A
	XOR	A
	LD	(UNET.RX_PAUSED),A
	LD	A,1
	LD	(STAGE),A
	XOR	A			; channel 0
	LD	DE,0x8000		; caller-owned buffer outside the DLL
	LD	IX,16
	LD	IY,0			; documented non-blocking poll
	CALL	UNET.F_RECV
	AND	A
	JP	NZ,FAILED
	LD	A,D
	OR	E
	JP	NZ,FAILED		; timeout is reported as OK / zero bytes
	LD	HL,(SPY_TIMEOUT)
	LD	DE,1
	AND	A
	SBC	HL,DE
	JP	NZ,FAILED		; ABI must clamp zero to one tick

	; Defense in depth: a direct zero-budget byte read gets one spin window and
	; then times out without calling the 1 ms delay or wrapping BC to 0xFFFF.
	LD	A,2
	LD	(STAGE),A
	LD	HL,UTIL.DELAY_1MS
	LD	DE,UNEXPECTED_DELAY
	CALL	STUB_JP
	XOR	A
	LD	(REG_LSR),A
	LD	BC,0
	CALL	TCP.READ_BYTE_TIMEOUT_OPEN
	JP	NC,FAILED
	LD	A,B
	OR	C
	JP	NZ,FAILED		; reader preserves the caller's zero budget

	; Zero is checked only after the spin: an already pending UART byte must
	; still be returned immediately.
	LD	A,3
	LD	(STAGE),A
	LD	A,LSR_DR
	LD	(REG_LSR),A
	LD	A,0x5A
	LD	(REG_RBR),A
	LD	BC,0
	CALL	TCP.READ_BYTE_TIMEOUT_OPEN
	JP	C,FAILED
	CP	0x5A
	JP	NZ,FAILED
	LD	A,C
	CP	0x5A
	JP	NZ,FAILED

	; The non-open esplib reader used by direct TCP consumers had the same
	; zero-to-0xFFFF wrap. Its zero budget must stop after one LSR sample too.
	LD	A,4
	LD	(STAGE),A
	XOR	A
	LD	(REG_LSR),A
	LD	BC,0
	CALL	WIFI.UART_WAIT_RS
	JP	NC,FAILED
	LD	A,B
	OR	C
	JP	NZ,FAILED

	; Command/interrupt receive owns the ISA window but shares the same public
	; timeout contract and therefore needs its own underflow guard.
	LD	A,5
	LD	(STAGE),A
	XOR	A
	LD	(REG_LSR),A
	LD	BC,0
	CALL	WIFI.UART_WAIT_RS_INT
	JP	NC,FAILED
	LD	A,B
	OR	C
	JP	NZ,FAILED

	JP	PASSED

; Patch the routine at HL with "JP DE".
STUB_JP
	LD	(HL),0xC3
	INC	HL
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

RECEIVE_SPY
	LD	(SPY_TIMEOUT),DE
	LD	A,RES_RS_TIMEOUT
	SCF
	RET

UNEXPECTED_DELAY
	JP	FAILED

FAILED
	LD	A,(STAGE)
	LD	(TEST_RESULT),A
PASSED
	LD	A,0xA5
	LD	(TEST_MARKER),A
TEST_DONE
	HALT

STAGE		DB 0
SPY_TIMEOUT	DW 0

	END TEST_START
