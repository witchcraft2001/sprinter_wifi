; Host-side regression harness for the ESP_TCP_RX_DEFER receive-defer window
; (esp_tcp.asm). Runs the REAL WAIT_PROMPT / WAIT_SEND_OK / RECEIVE /
; CAPTURE_PENDING_PAYLOAD routines against a scripted UART byte source, so it
; verifies that +IPD payload racing a SEND is captured (not discarded) and
; replayed to the next RECEIVE in order, with correct framing, partial-frame
; continuation, and overflow accounting. Run through tools/test-send-defer.sh.

	DEVICE NOSLOT64K

; Enable the feature and shrink the buffer so overflow is cheap to exercise.
	DEFINE	ESP_TCP_RX_DEFER
	DEFINE	TCP_RX_DEFER_SIZE 32

; Constants normally supplied by esplib.asm.
RS_BUFF_SIZE	EQU 192
REG_RBR		EQU 0xC3E8
REG_LSR		EQU 0xC3ED
LSR_DR		EQU 0x01
LSR_OE		EQU 0x02
LSR_PE		EQU 0x04
LSR_FE		EQU 0x08
LSR_BI		EQU 0x10
LSR_RCVE	EQU 0x80
RES_ERROR	EQU 1
RES_FAIL	EQU 2
RES_TX_TIMEOUT	EQU 3
RES_RS_TIMEOUT	EQU 4
RES_NOT_CONN	EQU 6
RES_BUSY	EQU 9

TEST_RESULT	EQU 0xC000
RECV_DEST	EQU 0xC100

	MACRO ASSERT_W16 addr?, val?
	LD	HL,(addr?)
	LD	DE,val?
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,FAILED
	ENDM

	MACRO ASSERT_B addr?, val?
	LD	A,(addr?)
	CP	val?
	JP	NZ,FAILED
	ENDM

	ORG 0x4000

TEST_START
	XOR	A
	LD	(TEST_RESULT),A

; ------------------------------------------------------------------
; Vector 1: a +IPD frame in the CIPSEND '>' prompt window is captured.
; ------------------------------------------------------------------
	LD	A,1
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET
	LD	HL,IN_PROMPT
	LD	BC,IN_PROMPT_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_PROMPT
	JP	C,FAILED		; must have seen '>'
	ASSERT_W16 TCP.DEFER_W, 7	; 2-byte header + "HELLO"
	ASSERT_W16 TCP.DEFER_R, 0
	ASSERT_W16 TCP.DEFER_FRAME_LEFT, 0
	ASSERT_B TCP.DEFER_LOST, 0
	LD	HL,TCP.DEFER_BUF
	LD	DE,EXP_HELLO
	LD	B,7
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 2: a +IPD line in the SEND OK window is captured and appended.
; ------------------------------------------------------------------
	LD	A,2
	LD	(STAGE),A
	LD	HL,IN_SENDOK
	LD	BC,IN_SENDOK_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED		; must have matched "SEND OK"
	ASSERT_W16 TCP.DEFER_W, 12	; previous 7 + header + "ABC"
	ASSERT_B TCP.DEFER_LOST, 0
	LD	HL,TCP.DEFER_BUF+7
	LD	DE,EXP_ABC
	LD	B,5
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 3: RECEIVE replays both buffered frames, in order, concatenated.
; ------------------------------------------------------------------
	LD	A,3
	LD	(STAGE),A
	LD	HL,0
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 8		; "HELLO" + "ABC"
	ASSERT_W16 TCP.DEFER_W, 0	; fully drained -> reset
	ASSERT_W16 TCP.DEFER_R, 0
	LD	HL,RECV_DEST
	LD	DE,EXP_HELLOABC
	LD	B,8
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 3b: a frame larger than the caller buffer is delivered in parts.
; ------------------------------------------------------------------
	LD	A,4
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET
	LD	HL,IN_WORLD
	LD	BC,IN_WORLD_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_PROMPT
	JP	C,FAILED
	ASSERT_W16 TCP.DEFER_W, 7	; header + "WORLD"
	; First RECEIVE with only 2 bytes of room.
	LD	HL,0
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	HL,RECV_DEST
	LD	BC,2
	LD	DE,1000
	CALL	TCP.RECEIVE
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 2
	ASSERT_W16 TCP.DEFER_FRAME_LEFT, 3
	; Second RECEIVE takes the rest.
	LD	HL,0
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	HL,RECV_DEST+2
	LD	BC,10
	LD	DE,1000
	CALL	TCP.RECEIVE
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 3
	ASSERT_W16 TCP.DEFER_W, 0
	LD	HL,RECV_DEST
	LD	DE,EXP_WORLD
	LD	B,5
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 4: a frame too big for the buffer is dropped and flagged; later
; frames still land intact, and the lost flag is sticky.
; ------------------------------------------------------------------
	LD	A,5
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET
	LD	HL,IN_BIG
	LD	BC,IN_BIG_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_PROMPT
	JP	C,FAILED
	ASSERT_W16 TCP.DEFER_W, 0	; 40+2 > 32: dropped
	ASSERT_B TCP.DEFER_LOST, 1
	LD	HL,IN_GOOD
	LD	BC,IN_GOOD_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_PROMPT
	JP	C,FAILED
	ASSERT_W16 TCP.DEFER_W, 6	; header + "GOOD"
	ASSERT_B TCP.DEFER_LOST, 1	; sticky
	LD	HL,TCP.DEFER_BUF
	LD	DE,EXP_GOOD
	LD	B,6
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 5: an unread payload at SEND start is rescued into the defer
; buffer (not flushed), and the following '>' prompt still parses.
; ------------------------------------------------------------------
	LD	A,6
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET
	LD	HL,4
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	HL,IN_PENDING
	LD	BC,IN_PENDING_LEN
	CALL	SET_INPUT
	CALL	TCP.CAPTURE_PENDING_PAYLOAD
	ASSERT_W16 TCP.PAYLOAD_LEFT, 0
	ASSERT_W16 TCP.DEFER_W, 6	; header + "WXYZ"
	LD	HL,TCP.DEFER_BUF
	LD	DE,EXP_WXYZ
	LD	B,6
	CALL	CMP_MEM
	; The remaining '>' must still be seen by WAIT_PROMPT.
	CALL	TCP.WAIT_PROMPT
	JP	C,FAILED
	ASSERT_W16 TCP.DEFER_W, 6	; unchanged by the prompt

; ------------------------------------------------------------------
; Vector 6: if the unread payload goes silent mid-frame, SEND must stop before
; transmitting AT+CIPSEND. The exact remainder stays live and can be captured
; later, so command text is never injected into binary +IPD data.
; ------------------------------------------------------------------
	LD	A,7
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET
	LD	HL,5
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	HL,IN_PART_A
	LD	BC,IN_PART_A_LEN
	CALL	SET_INPUT
	XOR	A
	LD	(WIFI.TX_STRING_COUNT),A
	LD	HL,PAYLOAD_XYZ
	LD	BC,3
	CALL	TCP.SEND_BUFFER
	JP	NC,FAILED
	CP	RES_RS_TIMEOUT
	JP	NZ,FAILED
	ASSERT_B WIFI.TX_STRING_COUNT, 0
	ASSERT_W16 TCP.PAYLOAD_LEFT, 3
	ASSERT_W16 TCP.DEFER_W, 4	; patched header + "AB"
	ASSERT_B TCP.DEFER_LOST, 1	; the split is visible diagnostically
	LD	HL,IN_PART_B
	LD	BC,IN_PART_B_LEN
	CALL	SET_INPUT
	CALL	TCP.CAPTURE_PENDING_PAYLOAD
	JP	C,FAILED
	ASSERT_W16 TCP.PAYLOAD_LEFT, 0
	ASSERT_W16 TCP.DEFER_W, 9	; {2,"AB"}, then {3,"CDE"}
	LD	HL,TCP.DEFER_BUF
	LD	DE,EXP_SPLIT
	LD	B,9
	CALL	CMP_MEM

	JP	TEST_DONE

FAILED
	LD	A,(STAGE)
	LD	(TEST_RESULT),A
	JR	TEST_DONE
STAGE	DB 0

TEST_DONE
	HALT

; ------------------------------------------------------------------
; Helpers
; ------------------------------------------------------------------
SET_INPUT
	LD	(WIFI.INPUT_PTR),HL
	LD	(WIFI.INPUT_LEFT),BC
	RET

CMP_MEM
.l
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAILED
	INC	HL
	INC	DE
	DJNZ	.l
	RET

LAST_BC		DW 0

; Scripted UART input streams.
IN_PROMPT	DB "+IPD,5:HELLO>"
IN_PROMPT_LEN	EQU $-IN_PROMPT
IN_SENDOK	DB "+IPD,3:ABC",13,10,"SEND OK",13,10
IN_SENDOK_LEN	EQU $-IN_SENDOK
IN_WORLD	DB "+IPD,5:WORLD>"
IN_WORLD_LEN	EQU $-IN_WORLD
IN_BIG		DB "+IPD,40:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX>"
IN_BIG_LEN	EQU $-IN_BIG
IN_GOOD		DB "+IPD,4:GOOD>"
IN_GOOD_LEN	EQU $-IN_GOOD
IN_PENDING	DB "WXYZ>"
IN_PENDING_LEN	EQU $-IN_PENDING
IN_PART_A	DB "AB"
IN_PART_A_LEN	EQU $-IN_PART_A
IN_PART_B	DB "CDE"
IN_PART_B_LEN	EQU $-IN_PART_B
PAYLOAD_XYZ	DB "XYZ"

; Expected buffer contents ({len16le, payload}).
EXP_HELLO	DB 5,0,"HELLO"
EXP_ABC		DB 3,0,"ABC"
EXP_HELLOABC	DB "HELLOABC"
EXP_WORLD	DB "WORLD"
EXP_GOOD	DB 4,0,"GOOD"
EXP_WXYZ	DB 4,0,"WXYZ"
EXP_SPLIT	DB 2,0,"AB",3,0,"CDE"

; ------------------------------------------------------------------
; Stubs for the modules esp_tcp.asm depends on.
; ------------------------------------------------------------------
	MODULE WIFI

RS_BUFF		EQU 0xD000
INPUT_PTR	DW 0
INPUT_LEFT	DW 0
TX_STRING_COUNT DB 0

; Read one byte from the scripted stream. In: BC=timeout (ignored).
; Out: CF=0 if a byte is available (mirrors UART_WAIT_RS + UART_READ split).
UART_WAIT_RS
	PUSH	HL
	LD	HL,(INPUT_LEFT)
	LD	A,H
	OR	L
	POP	HL
	JR	Z,.empty
	OR	A			; CF=0: byte ready
	RET
.empty
	SCF
	RET

; In: HL = register address (ignored). Out: A = next scripted byte.
UART_READ
	PUSH	BC,DE,HL
	LD	HL,(INPUT_PTR)
	LD	A,(HL)
	INC	HL
	LD	(INPUT_PTR),HL
	LD	HL,(INPUT_LEFT)
	DEC	HL
	LD	(INPUT_LEFT),HL
	POP	HL,DE,BC
	RET

UART_TX_STRING
	LD	A,(TX_STRING_COUNT)
	INC	A
	LD	(TX_STRING_COUNT),A
	OR	A
	RET
UART_TX_BUFFER
	OR	A
	RET
UART_TX_CMD
	XOR	A
	RET
UART_EMPTY_RS
	RET
UART_SET_DATA_RX_MODE
	RET

	ENDMODULE

	MODULE ISA
ISA_OPEN
	RET
ISA_CLOSE
	RET
	ENDMODULE

	MODULE WCOMMON
CANCELLED	DB 0
CHECK_CANCEL_IN_ISA
	OR	A			; CF=0: never cancelled in the harness
	RET
	ENDMODULE

	MODULE UTIL
; Only STRCMP runs on the tested paths; the rest resolve symbols.
STRCMP
	PUSH	DE,HL
.next
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.ne
	AND	A
	JR	Z,.eq
	INC	DE
	INC	HL
	JR	.next
.ne
	SCF
.eq
	POP	HL,DE
	RET
UTOA
	RET
DELAY
	RET
DELAY_1MS
	RET
	ENDMODULE

	INCLUDE "esp_tcp.asm"

	END TEST_START
