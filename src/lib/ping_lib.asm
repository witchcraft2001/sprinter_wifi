; ======================================================
; PING.EXE command-line parsing, ESP response parsing, and statistics
; rendering. No DSS or ESP/UART calls except the final PRINT/PRINTLN output,
; so tools/ping_vectors.asm can exercise every branch on a host CPU.
;
; Included inside MODULE MAIN by src/apps/ping.asm and by
; tools/ping_vectors.asm.
;
; Required definitions (from the includer):
;   HOST_SIZE, HOST_BUFF, CMDLINE_PTR
;   RES_RS_TIMEOUT, RES_BUSY (esplib.asm)
;   WIFI.RS_BUFF
;   UTIL.STARTSWITH, UTIL.ATOU, UTIL.UPCASE, UTIL.UTOA
;   WCOMMON.CHECK_CANCEL
;   dss.inc: DSS, DSS_SYSTIME
;   macro.inc: PRINT, PRINTLN, PRINT_HL
; ======================================================

	IFNDEF	_PING_LIB
	DEFINE	_PING_LIB

PING_DEFAULT_COUNT	EQU 4
PING_DEFAULT_PAUSE	EQU 1000

PING_SEEN_T	EQU 0x01
PING_SEEN_N	EQU 0x02
PING_SEEN_P	EQU 0x04
PING_SEEN_HOST	EQU 0x08

; ------------------------------------------------------
; Parse the PING.EXE command line from (CMDLINE_PTR) into HOST_BUFF,
; OPT_COUNT, OPT_PAUSE, OPT_INFINITE, OPT_HELP. Grammar:
;   [-t] [-n count] [-p ms] host
;   /?  -?  -h  /h            (help; short-circuits, rest of line ignored)
; Flags and the host may appear in any order, case-insensitively, as -x or /x.
; Out: CF=0 - parsed; caller must check OPT_HELP before using the other
;      fields. CF=1 - usage error (unknown/duplicate flag, missing/invalid/
;      out-of-range value, missing or a second positional argument, or -t
;      together with -n).
; ------------------------------------------------------
PARSE_PING_ARGS
	XOR	A
	LD	(OPT_HELP),A
	LD	(OPT_INFINITE),A
	LD	(PING_SEEN),A
	LD	HL,PING_DEFAULT_COUNT
	LD	(OPT_COUNT),HL
	LD	HL,PING_DEFAULT_PAUSE
	LD	(OPT_PAUSE),HL
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	LD	B,A
	INC	HL
.NEXT_TOKEN
	CALL	PL_SKIP_SPACES
	JP	C,.END_ARGS
	LD	A,(HL)
	CP	'-'
	JR	Z,.FLAG
	CP	'/'
	JR	Z,.FLAG
	LD	A,(PING_SEEN)
	AND	PING_SEEN_HOST
	JP	NZ,.BAD
	LD	DE,HOST_BUFF
	LD	C,HOST_SIZE-1
	CALL	PL_COPY_ARG
	JP	C,.BAD
	LD	A,(PING_SEEN)
	OR	PING_SEEN_HOST
	LD	(PING_SEEN),A
	JP	.NEXT_TOKEN
.FLAG
	LD	DE,PL_FLAG_BUF
	LD	C,2
	CALL	PL_COPY_ARG
	JP	C,.BAD
	LD	A,(PL_ARG_LEN)
	CP	2
	JP	NZ,.BAD
	LD	A,(PL_FLAG_BUF+1)
	CALL	UTIL.UPCASE
	CP	'T'
	JR	Z,.OPT_T
	CP	'N'
	JR	Z,.OPT_N
	CP	'P'
	JR	Z,.OPT_P
	CP	'H'
	JR	Z,.OPT_HELP
	CP	'?'
	JR	Z,.OPT_HELP
	JP	.BAD
.OPT_HELP
	LD	A,1
	LD	(OPT_HELP),A
	AND	A
	RET
.OPT_T
	LD	A,(PING_SEEN)
	AND	PING_SEEN_T
	JP	NZ,.BAD
	LD	A,(PING_SEEN)
	OR	PING_SEEN_T
	LD	(PING_SEEN),A
	LD	A,1
	LD	(OPT_INFINITE),A
	JR	.NEXT_TOKEN
.OPT_N
	LD	A,(PING_SEEN)
	AND	PING_SEEN_N
	JR	NZ,.BAD
	LD	A,(PING_SEEN)
	OR	PING_SEEN_N
	LD	(PING_SEEN),A
	CALL	PL_SKIP_SPACES
	JR	C,.BAD
	LD	DE,PL_NUM_BUF
	LD	C,5
	CALL	PL_COPY_ARG
	JR	C,.BAD
	; PARSE_U16 uses HL/BC as its own working registers, not the outer
	; cmdline cursor (HL=pointer, B=remaining count) - save/restore them
	; around the call.
	PUSH	HL
	PUSH	BC
	LD	HL,PL_NUM_BUF
	CALL	PARSE_U16
	JR	C,.N_BAD
	LD	A,B
	OR	C
	JR	Z,.N_BAD		; -n 0 is invalid, count must be >=1
	LD	(OPT_COUNT),BC
	POP	BC
	POP	HL
	JP	.NEXT_TOKEN
.N_BAD
	POP	BC
	POP	HL
	JP	.BAD
.OPT_P
	LD	A,(PING_SEEN)
	AND	PING_SEEN_P
	JR	NZ,.BAD
	LD	A,(PING_SEEN)
	OR	PING_SEEN_P
	LD	(PING_SEEN),A
	CALL	PL_SKIP_SPACES
	JR	C,.BAD
	LD	DE,PL_NUM_BUF
	LD	C,5
	CALL	PL_COPY_ARG
	JR	C,.BAD
	PUSH	HL
	PUSH	BC
	LD	HL,PL_NUM_BUF
	CALL	PARSE_U16
	JR	C,.P_BAD
	LD	(OPT_PAUSE),BC
	POP	BC
	POP	HL
	JP	.NEXT_TOKEN
.P_BAD
	POP	BC
	POP	HL
	JP	.BAD
.END_ARGS
	LD	A,(PING_SEEN)
	AND	PING_SEEN_HOST
	JR	Z,.BAD
	LD	A,(PING_SEEN)
	AND	PING_SEEN_T|PING_SEEN_N
	CP	PING_SEEN_T|PING_SEEN_N
	JR	Z,.BAD
	AND	A
	RET
.BAD
	SCF
	RET

; Skip whitespace (any byte < 0x21). In/Out: HL=cursor, B=remaining count.
; Out: CF=1 - no more tokens.
PL_SKIP_SPACES
	LD	A,B
	AND	A
	JR	Z,.ERR
	LD	A,(HL)
	CP	0x21
	RET	NC
	INC	HL
	DJNZ	PL_SKIP_SPACES
.ERR
	SCF
	RET

; Copy the next whitespace-delimited token into (DE), capacity C (excludes
; the terminator). In/Out: HL,B = cmdline cursor, advanced past the token.
; Out: CF=1 - token longer than capacity, or no token (caller must have
;      skipped spaces first). PL_ARG_LEN = number of characters copied.
PL_COPY_ARG
	XOR	A
	LD	(PL_ARG_LEN),A
.NEXT
	LD	A,B
	AND	A
	JR	Z,.END
	LD	A,(HL)
	CP	0x21
	JR	C,.END
	LD	A,C
	AND	A
	JR	Z,.ERR
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	DEC	C
	LD	A,(PL_ARG_LEN)
	INC	A
	LD	(PL_ARG_LEN),A
	JR	.NEXT
.END
	XOR	A
	LD	(DE),A
	LD	A,(PL_ARG_LEN)
	AND	A
	RET	NZ
.ERR
	SCF
	RET

; ------------------------------------------------------
; Convert an ASCIIZ decimal string (HL) into BC.
; Out: CF=1 - empty string, a non-digit character, or a value >65535.
; ------------------------------------------------------
PARSE_U16
	LD	A,(HL)
	AND	A
	JR	Z,.BAD
	LD	BC,0
.LOOP
	LD	A,(HL)
	AND	A
	JR	Z,.DONE
	CP	'0'
	JR	C,.BAD
	CP	'9'+1
	JR	NC,.BAD
	SUB	'0'
	LD	(PL_DIGIT),A
	PUSH	HL
	LD	H,B
	LD	L,C
	ADD	HL,HL			; *2
	JR	C,.OVERFLOW
	LD	D,H
	LD	E,L
	ADD	HL,HL			; *4
	JR	C,.OVERFLOW
	ADD	HL,HL			; *8
	JR	C,.OVERFLOW
	ADD	HL,DE			; *8 + *2 = *10
	JR	C,.OVERFLOW
	LD	A,(PL_DIGIT)
	LD	E,A
	LD	D,0
	ADD	HL,DE			; + digit
	JR	C,.OVERFLOW
	LD	B,H
	LD	C,L
	POP	HL
	INC	HL
	JR	.LOOP
.DONE
	AND	A
	RET
.OVERFLOW
	POP	HL
.BAD
	SCF
	RET

; ------------------------------------------------------
; In: HL = ASCIIZ string. Out: CF=0 - every character is a digit or '.', and
; the string is non-empty (a dotted-decimal IPv4 literal); CF=1 - anything
; else, so the caller should resolve it via AT+CIPDOMAIN.
; ------------------------------------------------------
IS_IPV4_LITERAL
	LD	A,(HL)
	AND	A
	JR	Z,.BAD
.LOOP
	LD	A,(HL)
	AND	A
	JR	Z,.OK
	CP	'.'
	JR	Z,.NEXT
	CP	'0'
	JR	C,.BAD
	CP	'9'+1
	JR	NC,.BAD
.NEXT
	INC	HL
	JR	.LOOP
.OK
	AND	A
	RET
.BAD
	SCF
	RET

; ------------------------------------------------------
; Scan a "+CIPDOMAIN:" response line and copy the resolved address.
; In: HL = response buffer to scan; DE = destination; C = capacity (excludes
;     the terminator).
; Out: CF=0 - address copied to (DE), ASCIIZ; CF=1 - "+CIPDOMAIN:" not found.
; ------------------------------------------------------
FIND_CIPDOMAIN_IP
.SCAN
	LD	A,(HL)
	AND	A
	JR	Z,.NOT_FOUND
	PUSH	DE
	LD	DE,PL_CIPDOMAIN_PREFIX
	CALL	UTIL.STARTSWITH
	POP	DE
	JR	Z,.FOUND
	CALL	SKIP_LINE
	JR	.SCAN
.FOUND
	; BC is scratch here; C on entry is the caller's copy capacity and must
	; survive this offset add.
	PUSH	BC
	LD	BC,11			; length of "+CIPDOMAIN:"
	ADD	HL,BC
	POP	BC
	LD	A,(HL)
	CP	34			; leading quote is optional
	JR	NZ,.COPY
	INC	HL
.COPY
	LD	A,(HL)
	AND	A
	JR	Z,.TERM
	CP	13
	JR	Z,.TERM
	CP	10
	JR	Z,.TERM
	CP	34
	JR	Z,.TERM
	LD	A,C
	AND	A
	JR	Z,.TERM
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	C
	JR	.COPY
.TERM
	XOR	A
	LD	(DE),A
	AND	A
	RET
.NOT_FOUND
	SCF
	RET

; ------------------------------------------------------
; Locate the decimal RTT in an AT+PING response, accepting both ESP-AT forms:
;   +PING:<ms>
;   +<ms>
; Out: CF=0 - HL -> first digit of the value; CF=1 - no valid line found (also
;      true for "+PING:TIMEOUT", since 'T' is not a digit).
; ------------------------------------------------------
FIND_PING_RESULT
	LD	HL,WIFI.RS_BUFF
.NEXT
	LD	A,(HL)
	AND	A
	JR	Z,.NOT_FOUND
	LD	DE,RESP_PING_PREFIX
	CALL	UTIL.STARTSWITH
	JR	Z,.FOUND_PING
	LD	A,(HL)
	CP	'+'
	JR	Z,.FOUND_SHORT
	CALL	SKIP_LINE
	JR	.NEXT
.FOUND_PING
	LD	BC,6
	ADD	HL,BC
	JR	.FOUND_DECIMAL
.FOUND_SHORT
	INC	HL
.FOUND_DECIMAL
	CALL	FIND_DECIMAL_FIELD
	RET
.NOT_FOUND
	SCF
	RET

FIND_DECIMAL_FIELD
	LD	A,(HL)
	CP	' '
	JR	Z,.SKIP
	CP	9
	JR	Z,.SKIP
	CP	'0'
	JR	C,.ERR
	CP	'9'+1
	JR	NC,.ERR
	AND	A
	RET
.SKIP
	INC	HL
	JR	FIND_DECIMAL_FIELD
.ERR
	SCF
	RET

; Out: CF=0 - BC = RTT in ms; CF=1 - no valid +PING/+<ms> line (see above).
FIND_PING_RTT
	CALL	FIND_PING_RESULT
	RET	C
	EX	DE,HL
	CALL	UTIL.ATOU
	LD	B,H
	LD	C,L
	AND	A
	RET

; Skip to just past the next LF (or to the end of the string).
SKIP_LINE
	LD	A,(HL)
	AND	A
	RET	Z
	INC	HL
	CP	10
	RET	Z
	JR	SKIP_LINE

; ------------------------------------------------------
; RESP_IS_PING_TIMEOUT: a "timed out" outcome, whether the ESP stayed silent
; (RES_RS_TIMEOUT) or answered with a terminal line (OK or ERROR alike)
; carrying "+timeout"/"+PING:TIMEOUT" - unreachable-host ESP-AT firmware and
; jesperl both report it this way, with ERROR as the terminal line.
; In: A = RES_* result from WIFI.UART_TX_CMD; WIFI.RS_BUFF = ESP response.
; Out: CF=1 - timed out. Trashes A,B,DE,HL.
; ------------------------------------------------------
RESP_IS_PING_TIMEOUT
	CP	RES_RS_TIMEOUT
	JR	Z,.YES
	LD	HL,LIT_TIMEOUT_LOWER
	CALL	RESP_CONTAINS
	RET	C
	LD	HL,LIT_TIMEOUT_UPPER
	JP	RESP_CONTAINS
.YES
	SCF
	RET

; ------------------------------------------------------
; RESP_CONTAINS: scan WIFI.RS_BUFF for the ASCIIZ needle at HL.
; Out: CF=1 - found, CF=0 - not found. Trashes A,B,DE,HL.
; ------------------------------------------------------
RESP_CONTAINS
	PUSH	HL			; needle start
	LD	DE,WIFI.RS_BUFF
.SCAN
	LD	A,(DE)
	AND	A
	JR	Z,.NO
	POP	HL			; reload needle start
	PUSH	HL
	PUSH	DE			; save haystack position
.CMP
	LD	A,(HL)
	AND	A
	JR	Z,.YES			; whole needle matched
	LD	B,A
	LD	A,(DE)
	CP	B
	JR	NZ,.NEXT
	INC	HL
	INC	DE
	JR	.CMP
.NEXT
	POP	DE			; restore haystack position
	INC	DE
	JR	.SCAN
.YES
	POP	DE			; discard saved position
	POP	HL			; discard needle start
	SCF
	RET
.NO
	POP	HL			; discard needle start
	OR	A
	RET

; ------------------------------------------------------
; Sent/received counters. Lost is derived at print time (Sent - Received),
; matching both sibling ping utilities. Saturate at 65535 for -t runs.
; ------------------------------------------------------
STAT_RESET
	LD	HL,0
	LD	(PING_SENT),HL
	LD	(PING_RECEIVED),HL
	RET

STAT_SENT
	LD	HL,(PING_SENT)
	INC	HL
	LD	A,H
	OR	L
	JR	NZ,.STORE
	LD	HL,0xFFFF
.STORE
	LD	(PING_SENT),HL
	RET

STAT_RECEIVED
	LD	HL,(PING_RECEIVED)
	INC	HL
	LD	A,H
	OR	L
	JR	NZ,.STORE
	LD	HL,0xFFFF
.STORE
	LD	(PING_RECEIVED),HL
	RET

; Print "    Packets: Sent = S, Received = R, Lost = L.\r\n".
; Trashes A,BC,DE,HL.
PRINT_PACKETS_LINE
	PRINT	PL_MSG_PACKETS
	LD	HL,(PING_SENT)
	CALL	PL_PRINT_U16
	PRINT	PL_MSG_RECEIVED
	LD	HL,(PING_RECEIVED)
	CALL	PL_PRINT_U16
	PRINT	PL_MSG_LOST
	LD	HL,(PING_SENT)
	LD	DE,(PING_RECEIVED)
	OR	A
	SBC	HL,DE
	CALL	PL_PRINT_U16
	PRINTLN	PL_MSG_PERIOD
	RET

; Print "time=Nms" or "time<1ms" (0ms) followed by CRLF. In: BC = RTT in ms.
; Trashes A,BC,DE,HL.
PRINT_RTT_MS
	; PRINT below issues RST DSS with C=DSS_PCHARS, clobbering the RTT value
	; still held in BC - stash it in memory first.
	LD	(PL_RTT_VALUE),BC
	LD	A,B
	OR	C
	JR	NZ,.EXACT
	PRINT	PL_MSG_TIME_LT
	LD	HL,1
	JR	.VALUE
.EXACT
	PRINT	PL_MSG_TIME_EQ
	LD	HL,(PL_RTT_VALUE)
.VALUE
	CALL	PL_PRINT_U16
	PRINTLN	PL_MSG_MS
	RET

; Print HL as unsigned decimal. Trashes A,DE,HL.
PL_PRINT_U16
	PUSH	HL
	LD	DE,PL_NUM_OUT
	CALL	UTIL.UTOA
	LD	HL,PL_NUM_OUT
	PRINT_HL
	POP	HL
	RET

; ------------------------------------------------------
; Inter-request pacing, built the way the sibling kits build it.
;
; sprinter-rtl8019a's WAIT_PING_GAP counts PING_GAP_MS one-millisecond ticks
; and polls the keyboard on every tick; sprinter-3C509B's WAIT_INTERVAL counts
; the same milliseconds as NETTIME quanta and keeps a coarse DSS_SYSTIME
; backstop behind them (nettime.asm, netdrv.inc). Two things are taken from
; there.
;
; First, the quantum is a loop count sized from a measurement of a real
; Sprinter, not from the nominal 21 MHz instruction timing that the bus does
; not deliver: netdrv.inc records NETPROF measuring the textbook 808 at 10000
; quanta per 19 wall seconds, and NETTIME_TICK_LOOP = 425 follows from that.
; UTIL.DELAY_1MS is the same five-access loop with 400 and is shared by every
; ESP timeout in the package, so PING sizes its own quantum here instead of
; re-tuning a constant those timeouts were tuned against.
;
; Second, the DSS wall clock decides whole seconds. 3C509B aligns a wire
; timeout to a second edge for exactly the reason PING needs it here
; (stage7_app.asm WAIT_SECOND_EDGE): only the clock knows how long a second is
; on a machine whose effective speed is not known, and the default pause is
; exactly one second. A clock that stops advancing is given up on after a
; finite guard, as WAIT_SECOND_EDGE does, and the seconds it still owes are
; counted out as quanta.
;
; The wait is anchored at the moment the REQUEST goes out, not at the moment
; the reply came back (PAUSE_ANCHOR_NOW, called by the send loop). An AT+PING
; is not a wire round trip: the command, the ESP's own ping and the response
; cost most of a second by themselves, and a pause measured after all that
; would add a whole second on top of it - which is exactly the "1 s pause
; behaves like 2-3 s" the sibling kits never see, because their ICMP echo is a
; card write. Anchored at the request, the interval is request-to-request: the
; ESP's time is inside the second, and a request that already outlasted the
; pause is followed by no wait at all.
; ------------------------------------------------------

PING_TICK_LOOP		EQU 425		; ~1 ms quantum; see the netdrv.inc measurement
PAUSE_POLL_TICKS	EQU 16		; quanta between cancel/wall-clock polls
PAUSE_EDGE_GUARD	EQU 200		; polls without the clock moving before giving up

; ------------------------------------------------------
; Split a millisecond count into whole seconds and a remainder.
; In:  HL = milliseconds.
; Out: B = whole seconds (0..65), HL = 0..999 ms remainder. Trashes A,DE.
; ------------------------------------------------------
PAUSE_SPLIT
	LD	B,0
.LOOP
	LD	DE,1000
	OR	A
	SBC	HL,DE
	JR	C,.DONE
	INC	B
	JR	.LOOP
.DONE
	ADD	HL,DE				; undo the subtraction that went negative
	RET

; ------------------------------------------------------
; Pause for HL milliseconds: whole seconds on the DSS wall clock, the
; remainder - and anything a stopped clock failed to deliver - on counted
; quanta.
; Out: CF=1 - cancelled by the user (WCOMMON.CANCELLED is set); CF=0 - the
;      pause elapsed. Trashes A,BC,DE,HL.
; ------------------------------------------------------
PAUSE_MS
	LD	A,H
	OR	L
	RET	Z				; OR leaves CF=0
	CALL	PAUSE_SPLIT
	LD	(PAUSE_REM),HL
	LD	A,B
	LD	(PAUSE_SECS),A
	AND	A
	JR	Z,.REMAINDER
	CALL	PAUSE_WALL_SECS
	RET	C
.FALLBACK
	; Whatever PAUSE_SECS still holds is a second the clock never reported.
	LD	A,(PAUSE_SECS)
	AND	A
	JR	Z,.REMAINDER
	LD	HL,1000
	CALL	PAUSE_QUANTA
	RET	C
	LD	HL,PAUSE_SECS
	DEC	(HL)
	JR	.FALLBACK
.REMAINDER
	LD	HL,(PAUSE_REM)
	LD	A,H
	OR	L
	RET	Z
	JP	PAUSE_QUANTA

; ------------------------------------------------------
; Wait until (PAUSE_SECS) whole seconds have passed since PAUSE_ANCHOR, which
; the send loop set when the request went out. Comparing elapsed seconds (not
; counting edges) is what lets a slow request shorten - or cancel - the pause
; that follows it.
; Out: CF=1 - cancelled. CF=0 - PAUSE_SECS is 0 when the clock delivered the
;      whole wait, or the number of seconds still owed when it stopped
;      advancing and the caller has to count them. Trashes A,BC,DE,HL.
; ------------------------------------------------------
PAUSE_WALL_SECS
	LD	A,PAUSE_EDGE_GUARD
	LD	(PAUSE_GUARD),A
	CALL	READ_WALL
	LD	(PAUSE_LAST),HL
.CHECK
	CALL	PAUSE_ELAPSED			; HL = seconds since the request
	LD	A,(PAUSE_SECS)
	LD	E,A
	LD	D,0
	OR	A
	SBC	HL,DE
	JR	C,.WAIT				; elapsed < wanted
	XOR	A
	LD	(PAUSE_SECS),A			; the clock delivered all of it
	RET					; XOR left CF=0
.WAIT
	CALL	PAUSE_POLL
	RET	C
	CALL	READ_WALL
	LD	DE,(PAUSE_LAST)
	OR	A
	SBC	HL,DE
	JR	Z,.NO_MOVE
	CALL	READ_WALL
	LD	(PAUSE_LAST),HL
	LD	A,PAUSE_EDGE_GUARD
	LD	(PAUSE_GUARD),A
	JR	.CHECK
.NO_MOVE
	LD	HL,PAUSE_GUARD
	DEC	(HL)
	JR	NZ,.CHECK
	; The clock has not moved for the whole guard. Hand the seconds it still
	; owes back to the caller to count out as quanta.
	CALL	PAUSE_ELAPSED
	EX	DE,HL				; DE = elapsed
	LD	A,(PAUSE_SECS)
	LD	L,A
	LD	H,0
	OR	A
	SBC	HL,DE
	LD	A,L
	LD	(PAUSE_SECS),A
	OR	A				; CF=0
	RET

; ------------------------------------------------------
; Out: HL = whole seconds since PAUSE_ANCHOR (0..3599). Trashes A,DE.
; ------------------------------------------------------
PAUSE_ELAPSED
	CALL	READ_WALL
	LD	DE,(PAUSE_ANCHOR)
	OR	A
	SBC	HL,DE
	RET	NC
	LD	DE,3600				; the clock wrapped past the hour
	ADD	HL,DE
	RET

; ------------------------------------------------------
; Anchor the pacing at "now". The send loop calls this immediately before each
; request, so the pause that follows covers the request as well.
; Preserves every register.
; ------------------------------------------------------
PAUSE_ANCHOR_NOW
	PUSH	AF,HL
	CALL	READ_WALL
	LD	(PAUSE_ANCHOR),HL
	POP	HL,AF
	RET

; ------------------------------------------------------
; Read the DSS wall clock as a second within the current hour, the way
; 3C509B's nettime.asm READ_WALL does. Minutes have to be folded in: a bare
; seconds field goes backwards once a minute, which would make an elapsed-time
; comparison jump by 60. ISA must be closed, as it is between requests.
; Out: HL = 0..3599. Trashes A; every other register is preserved.
; ------------------------------------------------------
READ_WALL
	PUSH	BC,DE,IX
	LD	C,DSS_SYSTIME
	RST	DSS				; H=hour L=min B=sec D=day E=month IX=year
	LD	A,B
	LD	(PAUSE_SEC_TMP),A
	LD	A,L				; minutes
	LD	HL,0
	LD	DE,60
	AND	A
	JR	Z,.SECONDS
	LD	B,A
.MINUTES
	ADD	HL,DE
	DJNZ	.MINUTES
.SECONDS
	LD	A,(PAUSE_SEC_TMP)
	LD	E,A
	LD	D,0
	ADD	HL,DE
	POP	IX,DE,BC
	RET

; ------------------------------------------------------
; Wait HL = milliseconds as counted quanta, polling for cancel every
; PAUSE_POLL_TICKS - the rtl8019a gap loop, with the key poll batched rather
; than run on every tick, because a DSS SCANKEY costs about as much as a
; quantum does.
; Out: CF=1 - cancelled. Trashes A,BC,DE,HL.
; ------------------------------------------------------
PAUSE_QUANTA
	LD	(PAUSE_LEFT),HL
	LD	A,PAUSE_POLL_TICKS
	LD	(PAUSE_POLL_LEFT),A
.LOOP
	LD	A,(PAUSE_POLL_LEFT)
	DEC	A
	JR	NZ,.NO_POLL
	CALL	WCOMMON.CHECK_CANCEL
	RET	C
	LD	A,PAUSE_POLL_TICKS
.NO_POLL
	LD	(PAUSE_POLL_LEFT),A
	CALL	PAUSE_ONE_TICK
	LD	HL,(PAUSE_LEFT)
	DEC	HL
	LD	(PAUSE_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.LOOP
	OR	A				; CF=0: the pause elapsed
	RET

; ------------------------------------------------------
; One polling interval: a cancel check plus PAUSE_POLL_TICKS quanta.
; Out: CF=1 - cancelled. Trashes A,B.
; ------------------------------------------------------
PAUSE_POLL
	CALL	WCOMMON.CHECK_CANCEL
	RET	C
	LD	B,PAUSE_POLL_TICKS
.LOOP
	CALL	PAUSE_ONE_TICK
	DJNZ	.LOOP
	OR	A
	RET

; ------------------------------------------------------
; One ~1 ms quantum: the same loop shape as 3C509B's WAIT_TICK and util.asm's
; DELAY_1MS_INT, only the count differs. Preserves BC.
; tools/ping_vectors.asm redirects it to a counter so the pacing vectors can
; check quantum counts instead of burning emulated cycles.
; ------------------------------------------------------
PAUSE_ONE_TICK
	IFDEF PING_LIB_TEST
	JP	@TEST_DELAY_1MS
	ELSE
	PUSH	BC
	LD	BC,PING_TICK_LOOP
.LOOP
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LOOP
	POP	BC
	RET
	ENDIF

; ------------------------------------------------------
; Read the DSS wall clock. ISA must be closed, as it is between requests.
; Out: A = seconds 0..59. Every other register is preserved.
; ------------------------------------------------------
READ_WALL_SEC
	PUSH	BC,DE,HL,IX
	LD	C,DSS_SYSTIME
	RST	DSS				; H=hour L=min B=sec D=day E=month IX=year
	LD	A,B
	POP	IX,HL,DE,BC
	RET

PL_MSG_PACKETS
	DB "    Packets: Sent = ",0
PL_MSG_RECEIVED
	DB ", Received = ",0
PL_MSG_LOST
	DB ", Lost = ",0
PL_MSG_PERIOD
	DB ".",0
PL_MSG_TIME_EQ
	DB "time=",0
PL_MSG_TIME_LT
	DB "time<",0
PL_MSG_MS
	DB "ms",0
PL_CIPDOMAIN_PREFIX
	DB "+CIPDOMAIN:",0
RESP_PING_PREFIX
	DB "+PING:",0
LIT_TIMEOUT_LOWER
	DB "timeout",0			; ESP-AT 2.2.1 form: "+timeout"
LIT_TIMEOUT_UPPER
	DB "TIMEOUT",0			; ESP-AT 2.2.2 form / jesperl: "+PING:TIMEOUT"

OPT_COUNT	DW 0
OPT_PAUSE	DW 0
OPT_INFINITE	DB 0
OPT_HELP	DB 0
PING_SENT	DW 0
PING_RECEIVED	DW 0
PING_SEEN	DB 0
PL_ARG_LEN	DB 0
PL_DIGIT	DB 0
PL_RTT_VALUE	DW 0
PAUSE_REM	DW 0
PAUSE_LEFT	DW 0
PAUSE_ANCHOR	DW 0
PAUSE_LAST	DW 0
PAUSE_SECS	DB 0
PAUSE_GUARD	DB 0
PAUSE_POLL_LEFT	DB 0
PAUSE_SEC_TMP	DB 0
PL_FLAG_BUF	DS 3,0
PL_NUM_BUF	DS 6,0
PL_NUM_OUT	DS 8,0

	ENDIF
