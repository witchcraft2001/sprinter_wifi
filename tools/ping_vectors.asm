; Host-side regression harness for the actual PING.EXE command-line parser,
; ESP response parser, and statistics rendering (src/lib/ping_lib.asm).
; Run through tools/test-ping.sh.

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"

; Mirrors esplib.asm's RES_* values without pulling in the whole ISA/UART
; hardware stack, the same approach tools/netup_busy_vectors.asm uses.
RES_OK			EQU 0
RES_ERROR		EQU 1
RES_FAIL		EQU 2
RES_TX_TIMEOUT		EQU 3
RES_RS_TIMEOUT		EQU 4
RES_BUSY		EQU 9

HOST_SIZE		EQU 96
MAX_BUFF_SIZE		EQU 16384

; Redirects ping_lib.asm's pacing delay to TEST_DELAY_1MS, which counts calls
; instead of burning emulated cycles.
	DEFINE PING_LIB_TEST

TEST_RESULT	EQU 0xC000
CAPTURE		EQU 0xC100
CMDLINE_BUF	EQU 0xC300		; synthetic DSS length+text cmdline buffer
RESP_BUF	EQU 0xC400		; stand-in for WIFI.RS_BUFF

	ORG 0x4000

TEST_START
	XOR	A
	LD	(TEST_RESULT),A
	LD	(CHECKPOINT),A
	; RST DSS (0x10) is below the loaded image: plant a JP to the stub, as
	; tools/progress_vectors.asm does, so PRINT/PRINTLN capture their output.
	LD	A,0xC3
	LD	(DSS),A
	LD	HL,DSS_STUB
	LD	(DSS+1),HL

	; ---------------- PARSE_PING_ARGS ----------------

	; 1. Bare host -> defaults (count=4, pause=1000, not infinite, not help).
	LD	A,1
	LD	(CHECKPOINT),A
	LD	HL,CL_HOST_ONLY
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	C,FAILED
	LD	A,(MAIN.OPT_HELP)
	AND	A
	JP	NZ,FAILED
	LD	HL,(MAIN.OPT_COUNT)
	LD	DE,4
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,(MAIN.OPT_PAUSE)
	LD	DE,1000
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,MAIN.HOST_BUFF
	LD	DE,STR_88881
	CALL	CMP_STR
	JP	NZ,FAILED

	; 2. Flags before AND after the host, mixed -/ forms and case.
	LD	A,2
	LD	(CHECKPOINT),A
	LD	HL,CL_FLAGS_MIXED
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	C,FAILED
	LD	HL,(MAIN.OPT_COUNT)
	LD	DE,7
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,(MAIN.OPT_PAUSE)
	LD	DE,250
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,MAIN.HOST_BUFF
	LD	DE,STR_EXAMPLE
	CALL	CMP_STR
	JP	NZ,FAILED

	; 3. -t alone (infinite), no -n.
	LD	A,3
	LD	(CHECKPOINT),A
	LD	HL,CL_T_ONLY
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	C,FAILED
	LD	A,(MAIN.OPT_INFINITE)
	AND	A
	JP	Z,FAILED

	; 4. -t together with -n -> usage error.
	LD	A,4
	LD	(CHECKPOINT),A
	LD	HL,CL_T_AND_N
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 5. Help tokens short-circuit regardless of position/case.
	LD	A,5
	LD	(CHECKPOINT),A
	LD	HL,CL_HELP_SLASH_Q
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	C,FAILED
	LD	A,(MAIN.OPT_HELP)
	AND	A
	JP	Z,FAILED

	LD	HL,CL_HELP_DASH_H
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	C,FAILED
	LD	A,(MAIN.OPT_HELP)
	AND	A
	JP	Z,FAILED

	; 6. No arguments at all -> usage error.
	LD	A,6
	LD	(CHECKPOINT),A
	LD	HL,CL_EMPTY
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 7. Unknown flag -> usage error.
	LD	A,7
	LD	(CHECKPOINT),A
	LD	HL,CL_UNKNOWN_FLAG
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 8. Duplicate -n -> usage error.
	LD	A,8
	LD	(CHECKPOINT),A
	LD	HL,CL_DUP_N
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 9. Second positional argument -> usage error.
	LD	A,9
	LD	(CHECKPOINT),A
	LD	HL,CL_TWO_HOSTS
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 10. -n out of range (0 and 70000) -> usage error.
	LD	A,10
	LD	(CHECKPOINT),A
	LD	HL,CL_N_ZERO
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	LD	HL,CL_N_TOO_BIG
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 11. -n with a non-numeric value -> usage error.
	LD	A,11
	LD	(CHECKPOINT),A
	LD	HL,CL_N_NOT_NUM
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 12. -n with a missing value (end of line) -> usage error.
	LD	A,12
	LD	(CHECKPOINT),A
	LD	HL,CL_N_MISSING
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	NC,FAILED

	; 13. -p 0 is valid (no pause).
	LD	A,13
	LD	(CHECKPOINT),A
	LD	HL,CL_P_ZERO
	CALL	SET_CMDLINE
	CALL	MAIN.PARSE_PING_ARGS
	JP	C,FAILED
	LD	HL,(MAIN.OPT_PAUSE)
	LD	A,H
	OR	L
	JP	NZ,FAILED

	; ---------------- IS_IPV4_LITERAL ----------------
	LD	A,14
	LD	(CHECKPOINT),A

	LD	HL,STR_88881
	CALL	MAIN.IS_IPV4_LITERAL
	JP	C,FAILED
	LD	HL,STR_EXAMPLE
	CALL	MAIN.IS_IPV4_LITERAL
	JP	NC,FAILED

	; ---------------- FIND_CIPDOMAIN_IP ----------------
	LD	A,15
	LD	(CHECKPOINT),A

	LD	HL,RESP_CIPDOMAIN_QUOTED
	CALL	COPY_TO_RESP_BUF
	LD	HL,RESP_BUF
	LD	DE,OUT_BUF
	LD	C,15
	CALL	MAIN.FIND_CIPDOMAIN_IP
	JP	C,FAILED
	LD	HL,OUT_BUF
	LD	DE,STR_931842163
	CALL	CMP_STR
	JP	NZ,FAILED

	LD	HL,RESP_CIPDOMAIN_BARE
	CALL	COPY_TO_RESP_BUF
	LD	HL,RESP_BUF
	LD	DE,OUT_BUF
	LD	C,15
	CALL	MAIN.FIND_CIPDOMAIN_IP
	JP	C,FAILED
	LD	HL,OUT_BUF
	LD	DE,STR_931842163
	CALL	CMP_STR
	JP	NZ,FAILED

	LD	HL,RESP_NO_CIPDOMAIN
	CALL	COPY_TO_RESP_BUF
	LD	HL,RESP_BUF
	LD	DE,OUT_BUF
	LD	C,15
	CALL	MAIN.FIND_CIPDOMAIN_IP
	JP	NC,FAILED

	; ---------------- FIND_PING_RTT / RESP_IS_PING_TIMEOUT ----------------
	LD	A,16
	LD	(CHECKPOINT),A

	LD	HL,RESP_PING_24
	CALL	COPY_TO_RESP_BUF
	CALL	MAIN.FIND_PING_RTT
	JP	C,FAILED
	LD	A,B
	OR	A
	JP	NZ,FAILED
	LD	A,C
	CP	24
	JP	NZ,FAILED

	LD	HL,RESP_SHORT_24
	CALL	COPY_TO_RESP_BUF
	CALL	MAIN.FIND_PING_RTT
	JP	C,FAILED
	LD	A,C
	CP	24
	JP	NZ,FAILED

	; A corrupted terminal line (first bytes lost on real 2.2.2 UART) must not
	; be mistaken for a valid RTT.
	LD	HL,RESP_CORRUPT
	CALL	COPY_TO_RESP_BUF
	CALL	MAIN.FIND_PING_RTT
	JP	NC,FAILED

	; "+PING:TIMEOUT" (jesperl/real ESP-AT 2.2.2 unreachable-host form) is not
	; a valid decimal either, and RESP_IS_PING_TIMEOUT must recognise it even
	; though the terminal line is ERROR, not OK.
	LD	HL,RESP_PING_TIMEOUT_ERR
	CALL	COPY_TO_RESP_BUF
	CALL	MAIN.FIND_PING_RTT
	JP	NC,FAILED
	LD	A,RES_ERROR
	CALL	MAIN.RESP_IS_PING_TIMEOUT
	JP	NC,FAILED

	LD	A,RES_RS_TIMEOUT
	CALL	MAIN.RESP_IS_PING_TIMEOUT
	JP	NC,FAILED

	LD	HL,RESP_NO_PING
	CALL	COPY_TO_RESP_BUF
	LD	A,RES_ERROR
	CALL	MAIN.RESP_IS_PING_TIMEOUT
	JP	C,FAILED

	; ---------------- Statistics rendering ----------------
	LD	A,17
	LD	(CHECKPOINT),A

	CALL	MAIN.STAT_RESET
	LD	B,4
.SENT_LOOP
	PUSH	BC
	CALL	MAIN.STAT_SENT
	POP	BC
	DJNZ	.SENT_LOOP
	LD	B,3
.RECV_LOOP
	PUSH	BC
	CALL	MAIN.STAT_RECEIVED
	POP	BC
	DJNZ	.RECV_LOOP
	LD	HL,CAPTURE
	LD	(CAPTURE_PTR),HL
	CALL	MAIN.PRINT_PACKETS_LINE
	LD	HL,CAPTURE
	LD	DE,EXPECTED_PACKETS
	LD	BC,EXPECTED_PACKETS_LEN
	CALL	CMP_MEM
	JP	NZ,FAILED

	; time<1ms (0ms RTT) vs time=Nms.
	LD	HL,CAPTURE
	LD	(CAPTURE_PTR),HL
	LD	BC,0
	CALL	MAIN.PRINT_RTT_MS
	LD	HL,CAPTURE
	LD	DE,EXPECTED_RTT_LT1
	LD	BC,EXPECTED_RTT_LT1_LEN
	CALL	CMP_MEM
	JP	NZ,FAILED

	LD	HL,CAPTURE
	LD	(CAPTURE_PTR),HL
	LD	BC,257
	CALL	MAIN.PRINT_RTT_MS
	LD	HL,CAPTURE
	LD	DE,EXPECTED_RTT_257
	LD	BC,EXPECTED_RTT_257_LEN
	CALL	CMP_MEM
	JP	NZ,FAILED

	; ---------------- inter-request pacing ----------------

	; 18. PAUSE_SPLIT: whole seconds and the sub-second remainder.
	LD	A,18
	LD	(CHECKPOINT),A
	LD	HL,1000
	CALL	MAIN.PAUSE_SPLIT
	LD	A,B
	CP	1
	JP	NZ,FAILED
	LD	A,H
	OR	L
	JP	NZ,FAILED
	LD	HL,250
	CALL	MAIN.PAUSE_SPLIT
	LD	A,B
	AND	A
	JP	NZ,FAILED
	LD	DE,250
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,2500
	CALL	MAIN.PAUSE_SPLIT
	LD	A,B
	CP	2
	JP	NZ,FAILED
	LD	DE,500
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,65535
	CALL	MAIN.PAUSE_SPLIT
	LD	A,B
	CP	65
	JP	NZ,FAILED
	LD	DE,535
	CALL	CMP_HL_DE
	JP	NZ,FAILED

	; 19. A whole-second pause waits until that many seconds have passed since
	; the request was anchored, no matter how fast or slow the quantum loop is.
	LD	A,19
	LD	(CHECKPOINT),A
	CALL	RESET_CLOCK
	CALL	MAIN.PAUSE_ANCHOR_NOW
	LD	HL,2000
	CALL	MAIN.PAUSE_MS
	JP	C,FAILED
	LD	HL,(TEST_WALL)
	LD	DE,2
	CALL	CMP_HL_DE
	JP	NZ,FAILED

	; 20. A sub-second pause never consults the clock: it counts quanta, one
	; per millisecond, like the sibling gap loops.
	LD	A,20
	LD	(CHECKPOINT),A
	CALL	RESET_CLOCK
	CALL	MAIN.PAUSE_ANCHOR_NOW
	LD	HL,250
	CALL	MAIN.PAUSE_MS
	JP	C,FAILED
	LD	HL,(TEST_DELAY_COUNT)
	LD	DE,250
	CALL	CMP_HL_DE
	JP	NZ,FAILED

	; 21. A mixed pause takes both paths: whole seconds against the clock,
	; then 500 quanta.
	LD	A,21
	LD	(CHECKPOINT),A
	CALL	RESET_CLOCK
	CALL	MAIN.PAUSE_ANCHOR_NOW
	LD	HL,2500
	CALL	MAIN.PAUSE_MS
	JP	C,FAILED
	LD	HL,(TEST_WALL)
	LD	DE,2
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	; The clock phase burns PAUSE_POLL quanta of its own, so check that the
	; remainder was counted on top of them rather than a fixed total.
	LD	HL,(TEST_DELAY_COUNT)
	LD	DE,500
	CALL	CMP_HL_GE_DE
	JP	C,FAILED

	; 22. The whole point of anchoring at the request: a request that already
	; outlasted the pause is followed by no wait at all. The ESP round trip is
	; inside the interval, not added to it.
	LD	A,22
	LD	(CHECKPOINT),A
	CALL	RESET_CLOCK
	CALL	MAIN.PAUSE_ANCHOR_NOW
	LD	A,2
	CALL	ADVANCE_CLOCK		; the request itself took two seconds
	LD	HL,1000
	CALL	MAIN.PAUSE_MS
	JP	C,FAILED
	LD	HL,(TEST_DELAY_COUNT)
	LD	DE,0
	CALL	CMP_HL_DE
	JP	NZ,FAILED

	; ... and a request that ate part of the second only shortens the rest.
	CALL	RESET_CLOCK
	CALL	MAIN.PAUSE_ANCHOR_NOW
	LD	A,1
	CALL	ADVANCE_CLOCK
	LD	HL,2000
	CALL	MAIN.PAUSE_MS
	JP	C,FAILED
	LD	HL,(TEST_WALL)
	LD	DE,2
	CALL	CMP_HL_DE		; one more second on the clock, not two
	JP	NZ,FAILED

	; 23. A clock that never advances is given up on after the guard, and the
	; seconds it owes are counted out as quanta instead of hanging the pause.
	LD	A,23
	LD	(CHECKPOINT),A
	CALL	RESET_CLOCK
	CALL	MAIN.PAUSE_ANCHOR_NOW
	XOR	A
	LD	(TEST_CLOCK_DIV),A		; the clock is stopped for good
	LD	HL,1000
	CALL	MAIN.PAUSE_MS
	JP	C,FAILED
	LD	HL,(TEST_WALL)
	LD	DE,0
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	LD	HL,(TEST_DELAY_COUNT)
	LD	DE,200*16+1000		; guard polls, then the counted second
	CALL	CMP_HL_DE
	JP	NZ,FAILED
	JR	TEST_DONE

FAILED
	LD	A,(CHECKPOINT)
	AND	A
	JR	NZ,.HAVE_CP
	LD	A,0xFF
.HAVE_CP
	LD	(TEST_RESULT),A
TEST_DONE
	RET

; ------------------------------------------------------
; Helpers
; ------------------------------------------------------

; Copy the ASCIIZ command line at HL into CMDLINE_BUF as a DSS-style
; length-prefixed buffer, and point MAIN.CMDLINE_PTR at it.
SET_CMDLINE
	PUSH	HL
	LD	DE,CMDLINE_BUF+1
	LD	BC,0
.LEN
	LD	A,(HL)
	AND	A
	JR	Z,.DONE
	LD	(DE),A
	INC	HL
	INC	DE
	INC	BC
	JR	.LEN
.DONE
	LD	A,C
	LD	(CMDLINE_BUF),A
	LD	HL,CMDLINE_BUF
	LD	(MAIN.CMDLINE_PTR),HL
	POP	HL
	RET

; Copy the ASCIIZ response at HL into RESP_BUF (stand-in for WIFI.RS_BUFF).
COPY_TO_RESP_BUF
	LD	DE,RESP_BUF
.LOOP
	LD	A,(HL)
	LD	(DE),A
	AND	A
	JR	Z,.DONE
	INC	HL
	INC	DE
	JR	.LOOP
.DONE
	RET

; Compare HL to DE (16-bit). Out: CF=1 when HL < DE. Preserves HL.
CMP_HL_GE_DE
	OR	A
	SBC	HL,DE
	PUSH	AF
	ADD	HL,DE
	POP	AF
	RET

; Compare HL to DE (16-bit). Out: Z if equal.
CMP_HL_DE
	OR	A
	SBC	HL,DE
	ADD	HL,DE
	RET

; Compare ASCIIZ strings at HL and DE. Out: Z if equal.
CMP_STR
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	OR	A
	RET	Z
	INC	HL
	INC	DE
	JR	CMP_STR

; Compare BC bytes at HL and DE. Out: Z if equal.
CMP_MEM
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	HL
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,CMP_MEM
	XOR	A
	RET

; ------------------------------------------------------
; DSS stub: capture PRINT/PRINTLN output into CAPTURE, same technique as
; tools/progress_vectors.asm.
; ------------------------------------------------------
DSS_STUB
	PUSH	AF
	LD	A,C
	CP	DSS_PCHARS
	JR	Z,.PCHARS
	CP	DSS_PUTCHAR
	JR	Z,.PUTCHAR
	CP	DSS_SYSTIME
	JR	Z,.SYSTIME
	POP	AF
	RET
.SYSTIME
	POP	AF
	CALL	TEST_CLOCK_TICK
	JP	TEST_CLOCK_FIELDS		; H/L = hour/min, B = sec, as DSS does
.PCHARS
	POP	AF
	PUSH	HL
	PUSH	DE
	LD	DE,(CAPTURE_PTR)
.COPY
	LD	A,(HL)
	AND	A
	JR	Z,.COPY_END
	LD	(DE),A
	INC	DE
	INC	HL
	JR	.COPY
.COPY_END
	LD	(CAPTURE_PTR),DE
	POP	DE
	POP	HL
	RET
.PUTCHAR
	POP	AF
	PUSH	HL
	LD	HL,(CAPTURE_PTR)
	LD	(HL),A
	INC	HL
	LD	(CAPTURE_PTR),HL
	POP	HL
	RET

CAPTURE_PTR	DW CAPTURE
CHECKPOINT	DB 0

; ------------------------------------------------------
; Scripted wall clock and delay counter for the pacing vectors. The clock
; advances one second every TEST_CLOCK_DIV reads, so a boundary is a fixed
; number of PAUSE_TICKs away and the pacing is fully deterministic. The delay
; call is counted instead of executed - PAUSE_LOOP_MS converts milliseconds
; into a call count, and that count is what the vectors check.
; ------------------------------------------------------
RESET_CLOCK
	XOR	A
	LD	(TEST_CLOCK_N),A
	LD	HL,0
	LD	(TEST_WALL),HL
	LD	(TEST_DELAY_COUNT),HL
	LD	A,5
	LD	(TEST_CLOCK_DIV),A
	RET

; Advance the scripted clock by whole seconds without waiting for reads, so a
; vector can stage "the request itself already took N seconds".
; In: A = seconds to add.
ADVANCE_CLOCK
	LD	L,A
	LD	H,0
	LD	DE,(TEST_WALL)
	ADD	HL,DE
	LD	(TEST_WALL),HL
	RET

TEST_DELAY_1MS
	PUSH	HL
	LD	HL,(TEST_DELAY_COUNT)
	INC	HL
	LD	(TEST_DELAY_COUNT),HL
	POP	HL
	RET

TEST_CLOCK_TICK
	PUSH	AF
	PUSH	HL
	LD	A,(TEST_CLOCK_DIV)
	AND	A
	JR	Z,.NO_EDGE		; 0 = a stopped clock, for the guard vector
	LD	A,(TEST_CLOCK_N)
	INC	A
	LD	(TEST_CLOCK_N),A
	LD	HL,TEST_CLOCK_DIV
	CP	(HL)
	JR	C,.NO_EDGE
	XOR	A
	LD	(TEST_CLOCK_N),A
	LD	HL,(TEST_WALL)
	INC	HL
	LD	(TEST_WALL),HL
.NO_EDGE
	POP	HL
	POP	AF
	RET

; Split TEST_WALL (second of the hour) into L=minutes and B=seconds, the way
; DSS_SYSTIME reports them - READ_WALL folds the minutes back in.
TEST_CLOCK_FIELDS
	LD	HL,(TEST_WALL)
	LD	B,0
.DIV
	LD	DE,60
	OR	A
	SBC	HL,DE
	JR	C,.DONE
	INC	B
	JR	.DIV
.DONE
	ADD	HL,DE
	LD	A,L
	LD	L,B
	LD	B,A
	LD	H,0
	RET

TEST_WALL		DW 0
TEST_CLOCK_N		DB 0
TEST_CLOCK_DIV		DB 5
TEST_DELAY_COUNT	DW 0

; ------------------------------------------------------
; Fixtures
; ------------------------------------------------------
CL_HOST_ONLY		DB "8.8.8.8",0
CL_FLAGS_MIXED		DB "-N 7 example.com /P 250",0
CL_T_ONLY		DB "-t 8.8.8.8",0
CL_T_AND_N		DB "-t -n 5 8.8.8.8",0
CL_HELP_SLASH_Q		DB "/? -n 5",0
CL_HELP_DASH_H		DB "8.8.8.8 -h",0
CL_EMPTY		DB 0
CL_UNKNOWN_FLAG		DB "-x 8.8.8.8",0
CL_DUP_N		DB "-n 3 -n 4 8.8.8.8",0
CL_TWO_HOSTS		DB "8.8.8.8 8.8.4.4",0
CL_N_ZERO		DB "-n 0 8.8.8.8",0
CL_N_TOO_BIG		DB "-n 70000 8.8.8.8",0
CL_N_NOT_NUM		DB "-n abc 8.8.8.8",0
CL_N_MISSING		DB "8.8.8.8 -n",0
CL_P_ZERO		DB "-p 0 8.8.8.8",0

STR_88881		DB "8.8.8.8",0
STR_EXAMPLE		DB "example.com",0
STR_931842163		DB "93.184.216.34",0

RESP_CIPDOMAIN_QUOTED	DB 13,10,"+CIPDOMAIN:",34,"93.184.216.34",34,13,10,13,10,"OK",13,10,0
RESP_CIPDOMAIN_BARE	DB 13,10,"+CIPDOMAIN:93.184.216.34",13,10,13,10,"OK",13,10,0
RESP_NO_CIPDOMAIN	DB 13,10,"ERROR",13,10,0

RESP_PING_24		DB 13,10,"+PING:24",13,10,13,10,"OK",13,10,0
RESP_SHORT_24		DB 13,10,"+24",13,10,13,10,"OK",13,10,0
RESP_CORRUPT		DB 13,10,"G:228",13,10,13,10,"OK",13,10,0
RESP_PING_TIMEOUT_ERR	DB 13,10,"+PING:TIMEOUT",13,10,13,10,"ERROR",13,10,0
RESP_NO_PING		DB 13,10,"ERROR",13,10,0

OUT_BUF			DS 16,0

EXPECTED_PACKETS
	DB "    Packets: Sent = 4, Received = 3, Lost = 1.",13,10
EXPECTED_PACKETS_LEN	EQU $-EXPECTED_PACKETS

EXPECTED_RTT_LT1
	DB "time<1ms",13,10
EXPECTED_RTT_LT1_LEN	EQU $-EXPECTED_RTT_LT1

EXPECTED_RTT_257
	DB "time=257ms",13,10
EXPECTED_RTT_257_LEN	EQU $-EXPECTED_RTT_257

	MODULE WIFI
RS_BUFF	EQU RESP_BUF
	ENDMODULE

; util.asm's optional dss_error.asm pull-in references WCOMMON.LINE_END
; unconditionally (only in a routine this harness never calls).
	MODULE WCOMMON
LINE_END	DB 13,10,0
; ping_lib.asm polls for Esc through this; the pacing vectors never cancel.
CHECK_CANCEL
	XOR	A
	RET
	ENDMODULE

	INCLUDE "util.asm"

	MODULE MAIN
	INCLUDE "ping_lib.asm"
HOST_BUFF	DS HOST_SIZE,0
CMDLINE_PTR	DW 0
	ENDMODULE

	END TEST_START
