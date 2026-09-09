; Host-side regression harness for the UNET_CAP_LISTEN wire-level plumbing in
; esp_tcp.asm: the "CONNECT" pattern WAIT_IPD_HEADER_MUX/.MARK_CONNECT add to
; their scanners, MUX_TRY_ACCEPT's link claim, and MAP_LINK_TO_CH converting
; wire link ids to channel space for +IPD/CLOSED demultiplexing. Follows the
; mux_demux_vectors.asm pattern: the REAL esp_tcp.asm runs against a scripted
; UART byte source. Run through tools/test-listen.sh.

	DEVICE NOSLOT64K

	DEFINE	ESP_TCP_RX_DEFER
	DEFINE	ESP_TCP_MUX
	DEFINE	ESP_TCP_TEST_READER
	DEFINE	TCP_RX_DEFER_SIZE 32

; Constants normally supplied by esplib.asm.
RS_BUFF_SIZE	EQU 192
REG_RBR		EQU 0xC3E8
REG_LSR		EQU 0xC3ED
LSR_DR		EQU 0x01
LSR_OE		EQU 0x02
RES_ERROR	EQU 1
RES_FAIL	EQU 2
RES_TX_TIMEOUT	EQU 3
RES_RS_TIMEOUT	EQU 4
RES_NOT_CONN	EQU 6
RES_BUSY	EQU 9

TEST_RESULT	EQU 0xC000
TEST_MARKER	EQU 0xC001	; 0xA5 once the vector chain has actually run
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

; Select a channel's defer context so the working cursors can be asserted.
	MACRO SELECT_CH ch?
	LD	A,ch?
	CALL	TCP.DEFER_SELECT
	ENDM

; Reset the LISTEN bookkeeping this file pokes directly (the DLL normally
; owns it through F_LISTEN/UNLISTEN/CH_RELEASE; here only the esp_tcp.asm
; wire-level half is under test).
	MACRO RESET_LISTEN
	LD	A,0xFF
	LD	(TCP.MUX_LISTEN_CH),A
	LD	HL,TCP.MUX_LINK_MAP
	LD	(HL),0xFF
	INC	HL
	LD	(HL),0xFF
	ENDM

	ORG 0x4000

TEST_START
	XOR	A
	LD	(TEST_RESULT),A
	LD	(TEST_MARKER),A
	CALL	TCP.RX_DEFER_RESET_ALL

; ------------------------------------------------------------------
; Vector 1: a spontaneous "<link>,CONNECT" claims the armed listening
; channel, and the +IPD that follows on the wire is delivered to it - proof
; that MAP_LINK_TO_CH sees the freshly written MUX_LINK_MAP entry.
; ------------------------------------------------------------------
	LD	A,1
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	RESET_LISTEN
	LD	A,1
	LD	(TCP.MUX_LISTEN_CH),A		; channel 1 is listening
	LD	HL,IN_ACCEPT_HELLO
	LD	BC,IN_ACCEPT_HELLO_LEN
	CALL	SET_INPUT
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 5
	LD	HL,RECV_DEST
	LD	DE,EXP_HELLO
	LD	B,5
	CALL	CMP_MEM
	ASSERT_B TCP.MUX_LINK_MAP+1, 1		; channel 1 -> link 1 recorded

; ------------------------------------------------------------------
; Vector 2: "WIFI CONNECTED" contains the literal text "CONNECT" but no
; "<digit>," prefix precedes it, so MUX_CAND stays 0xFF and MUX_TRY_ACCEPT
; must reject it - the scan continues to real data with nothing claimed.
; ------------------------------------------------------------------
	LD	A,2
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	RESET_LISTEN
	XOR	A
	LD	(TCP.MUX_LISTEN_CH),A		; channel 0 is listening
	LD	HL,IN_WIFI_CONNECTED
	LD	BC,IN_WIFI_CONNECTED_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 3
	LD	HL,RECV_DEST
	LD	DE,EXP_ABC
	LD	B,3
	CALL	CMP_MEM
	ASSERT_B TCP.MUX_LINK_MAP, 0xFF	; the false match never claimed a link

; ------------------------------------------------------------------
; Vector 3: an accepted channel's own "<link>,CLOSED" is latched in CHANNEL
; space (MUX_CLOSED_MASK bit == channel index), not in raw link-id space,
; and RECEIVE_MUX reports it as this channel's close.
; ------------------------------------------------------------------
	LD	A,3
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	RESET_LISTEN
	LD	A,1
	LD	(TCP.MUX_LISTEN_CH),A
	LD	HL,IN_ACCEPT_THEN_CLOSE
	LD	BC,IN_ACCEPT_THEN_CLOSE_LEN
	CALL	SET_INPUT
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	NC,FAILED			; must report the close, not idle/data
	CP	RES_NOT_CONN
	JP	NZ,FAILED
	ASSERT_B TCP.MUX_CLOSED_MASK, 2	; bit1 = channel 1, not raw link "1"

; ------------------------------------------------------------------
; Vector 4: a spontaneous CONNECT for a foreign link, seen inside WAIT_SEND_OK
; while another channel's own CIPSEND is in flight, must not disturb that
; transaction and must still be claimed for the listening channel.
; ------------------------------------------------------------------
	LD	A,4
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.SEND_STATE_RESET
	RESET_LISTEN
	XOR	A
	LD	(TCP.LINK_ID),A			; our own transaction is on link 0
	LD	A,1
	LD	(TCP.MUX_LISTEN_CH),A		; channel 1 is listening
	LD	HL,IN_FOREIGN_CONNECT_SENDOK
	LD	BC,IN_FOREIGN_CONNECT_SENDOK_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED			; "0,SEND OK" must still complete it
	ASSERT_B TCP.MUX_LINK_MAP+1, 1		; channel 1 claimed link 1 mid-transaction

; ------------------------------------------------------------------
; Vector 5: the same foreign CONNECT with LISTEN disarmed is dropped, exactly
; like the pre-LISTEN behaviour - MUX_LINK_MAP is untouched.
; ------------------------------------------------------------------
	LD	A,5
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.SEND_STATE_RESET
	RESET_LISTEN
	XOR	A
	LD	(TCP.LINK_ID),A
	LD	HL,IN_FOREIGN_CONNECT_SENDOK
	LD	BC,IN_FOREIGN_CONNECT_SENDOK_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED
	ASSERT_B TCP.MUX_LINK_MAP, 0xFF
	ASSERT_B TCP.MUX_LINK_MAP+1, 0xFF

; ------------------------------------------------------------------
; Vector 6: a +IPD frame for the just-accepted channel, arriving while the
; caller is reading a DIFFERENT channel, is stashed in that channel's own
; defer window (XCHAN) and replayed correctly on the next read of it.
; ------------------------------------------------------------------
	LD	A,6
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	RESET_LISTEN
	LD	A,1
	LD	(TCP.MUX_LISTEN_CH),A
	LD	HL,IN_ACCEPT_HELLO		; "1,CONNECT" then "+IPD,1,5:HELLO"
	LD	BC,IN_ACCEPT_HELLO_LEN
	CALL	SET_INPUT
	LD	A,0				; reading channel 0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 0			; nothing for channel 0
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 7		; header(2) + "HELLO"(5)
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_HELLO
	LD	B,7
	CALL	CMP_MEM
	; reading channel 1 now replays the stashed frame
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 5
	LD	HL,RECV_DEST
	LD	DE,EXP_HELLO
	LD	B,5
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 7: link-map helper unit checks. (a) MUX_ALLOC_LINK yields identity
; when free, dodges an identity slot squatted by the other channel's accept,
; and reclaiming one's own stale entry still prefers identity. (b)
; SET_LINK_FROM_MAP resolves a mapped channel and fails an unmapped one.
; (c) MAP_LINK_TO_CH refuses the identity fallback for a stray wire id whose
; channel is itself bound to a different link.
; ------------------------------------------------------------------
	LD	A,7
	LD	(STAGE),A
	RESET_LISTEN
	; (a) identity free: channel 0 -> link 0
	XOR	A
	CALL	TCP.MUX_ALLOC_LINK
	ASSERT_B TCP.MUX_LINK_MAP, 0
	ASSERT_B TCP.LINK_ID, 0
	; identity squatted: channel 0's accept took link 1, channel 1 must dodge
	RESET_LISTEN
	LD	A,1
	LD	(TCP.MUX_LINK_MAP),A		; channel 0 holds link 1
	LD	A,1
	CALL	TCP.MUX_ALLOC_LINK
	ASSERT_B TCP.MUX_LINK_MAP+1, 0		; channel 1 fell back to link 0
	ASSERT_B TCP.LINK_ID, 0
	; own stale entry released first: reopening channel 1 regains identity
	LD	A,1
	CALL	TCP.MUX_ALLOC_LINK		; map still holds ch0=1, ch1=0
	ASSERT_B TCP.MUX_LINK_MAP+1, 0		; ...but 1 is claimed by ch0: dodge again
	; (b) SET_LINK_FROM_MAP: mapped channel programs LINK_ID
	LD	A,0xFF
	LD	(TCP.LINK_ID),A
	XOR	A
	CALL	TCP.SET_LINK_FROM_MAP		; channel 0 -> link 1
	JP	C,FAILED
	ASSERT_B TCP.LINK_ID, 1
	; unmapped channel refuses with CF=1 and leaves LINK_ID alone
	RESET_LISTEN
	LD	A,0xEE
	LD	(TCP.LINK_ID),A
	XOR	A
	CALL	TCP.SET_LINK_FROM_MAP
	JP	NC,FAILED
	ASSERT_B TCP.LINK_ID, 0xEE
	; (c) stray wire id vs a channel bound elsewhere: map = [0xFF, 0] models
	; channel 1 accepted inbound on link 0; wire id 1 belongs to nobody and
	; must NOT fall back to "channel 1".
	RESET_LISTEN
	XOR	A
	LD	(TCP.MUX_LINK_MAP+1),A		; channel 1 -> link 0
	LD	A,1
	CALL	TCP.MAP_LINK_TO_CH
	CP	0xFF
	JP	NZ,FAILED
	LD	A,0				; wire id 0 resolves through the map
	CALL	TCP.MAP_LINK_TO_CH
	CP	1
	JP	NZ,FAILED
	; plain identity still works while the map is empty (legacy behaviour)
	RESET_LISTEN
	XOR	A
	CALL	TCP.MAP_LINK_TO_CH
	CP	0
	JP	NZ,FAILED

	JP	PASSED

FAILED
	LD	A,(STAGE)
	LD	(TEST_RESULT),A
PASSED
	LD	A,0xA5
	LD	(TEST_MARKER),A
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

; Scripted byte source shared by both readers (the open-window reader is
; redirected here by ESP_TCP_TEST_READER; the send-window reader arrives
; through the WIFI stubs below).
TEST_READ_BYTE
	PUSH	HL
	LD	HL,(WIFI.INPUT_LEFT)
	LD	A,H
	OR	L
	JR	Z,.empty
	DEC	HL
	LD	(WIFI.INPUT_LEFT),HL
	LD	HL,(WIFI.INPUT_PTR)
	LD	A,(HL)
	INC	HL
	LD	(WIFI.INPUT_PTR),HL
	POP	HL
	LD	C,A
	AND	A			; CF=0: byte delivered
	RET
.empty
	POP	HL
	SCF
	RET

LAST_BC		DW 0

; Scripted UART input streams.
IN_ACCEPT_HELLO	DB "1,CONNECT",13,10,"+IPD,1,5:HELLO"
IN_ACCEPT_HELLO_LEN EQU $-IN_ACCEPT_HELLO
IN_WIFI_CONNECTED DB "WIFI CONNECTED",13,10,"+IPD,0,3:ABC"
IN_WIFI_CONNECTED_LEN EQU $-IN_WIFI_CONNECTED
IN_ACCEPT_THEN_CLOSE DB "1,CONNECT",13,10,"1,CLOSED"
IN_ACCEPT_THEN_CLOSE_LEN EQU $-IN_ACCEPT_THEN_CLOSE
IN_FOREIGN_CONNECT_SENDOK DB "1,CONNECT",13,10,"0,SEND OK",13,10
IN_FOREIGN_CONNECT_SENDOK_LEN EQU $-IN_FOREIGN_CONNECT_SENDOK

; Expected payloads and buffer contents ({len16le, payload}).
EXP_HELLO	DB "HELLO"
EXP_ABC		DB "ABC"
EXP_FRAME_HELLO	DB 5,0,"HELLO"

; ------------------------------------------------------------------
; Stubs for the modules esp_tcp.asm depends on.
; ------------------------------------------------------------------
	MODULE WIFI

RS_BUFF		EQU 0xD000
INPUT_PTR	DW 0
INPUT_LEFT	DW 0
CMD_LSR_ACCUM	DB 0		; line-error accumulator (send-window diagnostics)
TX_STRING_COUNT DB 0
RX_PAUSE_COUNT DB 0
RX_RESUME_COUNT DB 0
RX_PAUSE_OPEN_COUNT DB 0
RX_RESUME_OPEN_COUNT DB 0

; Send-window reader path (UART_WAIT_RS + UART_READ split).
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
UART_SET_DATA_RX_MODE_OPEN
	RET
UART_RX_PAUSE
	LD	A,(RX_PAUSE_COUNT)
	INC	A
	LD	(RX_PAUSE_COUNT),A
	RET
UART_RX_PAUSE_OPEN
	LD	A,(RX_PAUSE_COUNT)
	INC	A
	LD	(RX_PAUSE_COUNT),A
	LD	A,(RX_PAUSE_OPEN_COUNT)
	INC	A
	LD	(RX_PAUSE_OPEN_COUNT),A
	RET
UART_RX_RESUME
	LD	A,(RX_RESUME_COUNT)
	INC	A
	LD	(RX_RESUME_COUNT),A
	RET
UART_RX_RESUME_OPEN
	LD	A,(RX_RESUME_COUNT)
	INC	A
	LD	(RX_RESUME_COUNT),A
	LD	A,(RX_RESUME_OPEN_COUNT)
	INC	A
	LD	(RX_RESUME_OPEN_COUNT),A
	RET

	ENDMODULE

	MODULE ISA
OPEN_COUNT	DB 0
CLOSE_COUNT	DB 0
ISA_OPEN
	PUSH	HL
	LD	HL,OPEN_COUNT
	INC	(HL)
	POP	HL
	RET
ISA_CLOSE
	PUSH	HL
	LD	HL,CLOSE_COUNT
	INC	(HL)
	POP	HL
	RET
	ENDMODULE

	MODULE WCOMMON
CANCELLED	DB 0
CHECK_CANCEL_IN_ISA
	OR	A			; CF=0: never cancelled in the harness
	RET
	ENDMODULE

	MODULE UTIL
; Only STRCMP/STARTSWITH run on the tested paths; the rest resolve symbols.
; Both copy the real util.asm register/flag conventions.
STARTSWITH
	PUSH	HL,DE
.sw_next
	LD	A,(DE)
	OR	A
	JR	Z,.sw_end
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.sw_end
	INC	HL
	INC	DE
	JR	.sw_next
.sw_end
	POP	DE,HL
	RET
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
