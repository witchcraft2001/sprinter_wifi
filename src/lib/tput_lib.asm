; ======================================================
; Transfer throughput / speed reporting for Sprinter ESP Network Kit.
; Measures wall-clock seconds via DSS_SYSTIME (seconds-of-day) and prints a
; "<bytes> bytes in <secs> sec, <rate>" summary. Ported from the rtl8019a CLI
; utilities so wget/ftp report download speed consistently.
;
; Usage:
;   CALL TPUT.START                 ; just before the transfer (ISA closed)
;   ... transfer ...
;   LD HL,(bytes_lo) / LD DE,(bytes_hi)
;   CALL TPUT.REPORT                ; after the transfer (ISA closed)
;
; DSS calls (SYSTIME / PUTCHAR / PCHARS) need the ISA window CLOSED, so callers
; must invoke these with ISA closed. IX is preserved across SYSTIME.
; ======================================================

	IFNDEF	_TPUT_LIB
	DEFINE	_TPUT_LIB

	MODULE TPUT

; ------------------------------------------------------
; NOW: read DSS_SYSTIME and return wall-clock time as 24-bit seconds-of-day.
;   Out: B = high 8 bits, HL = low 16 bits. Trashes A,BC,DE,HL. IX preserved.
; ------------------------------------------------------
NOW
	PUSH	IX
	LD	C,DSS_SYSTIME
	RST	DSS
	; H = hours, L = minutes, B = seconds.
	PUSH	BC
	PUSH	HL
	XOR	A
	LD	(SCRATCH+0),A
	LD	(SCRATCH+1),A
	LD	(SCRATCH+2),A
	POP	DE			; D = hours, E = minutes
	PUSH	DE
	LD	A,D
	OR	A
	JR	Z,.SKIP_HH
	LD	B,A
.HH_LP
	LD	HL,(SCRATCH)
	LD	DE,3600
	ADD	HL,DE
	LD	(SCRATCH),HL
	JR	NC,.NCHH
	LD	A,(SCRATCH+2)
	INC	A
	LD	(SCRATCH+2),A
.NCHH
	DJNZ	.HH_LP
.SKIP_HH
	POP	DE			; D = hours, E = minutes
	LD	A,E
	OR	A
	JR	Z,.SKIP_MM
	LD	B,A
.MM_LP
	LD	HL,(SCRATCH)
	LD	DE,60
	ADD	HL,DE
	LD	(SCRATCH),HL
	JR	NC,.NCMM
	LD	A,(SCRATCH+2)
	INC	A
	LD	(SCRATCH+2),A
.NCMM
	DJNZ	.MM_LP
.SKIP_MM
	POP	BC			; B = seconds
	LD	HL,(SCRATCH)
	LD	D,0
	LD	E,B
	ADD	HL,DE
	LD	(SCRATCH),HL
	JR	NC,.NCSS
	LD	A,(SCRATCH+2)
	INC	A
	LD	(SCRATCH+2),A
.NCSS
	LD	HL,(SCRATCH)
	LD	A,(SCRATCH+2)
	LD	B,A
	POP	IX
	RET

; ------------------------------------------------------
; START: capture the current seconds-of-day. Call once before the transfer.
; ------------------------------------------------------
START
	CALL	NOW
	LD	(T_START),HL
	LD	A,B
	LD	(T_START+2),A
	; A new transfer restarts the progress line: drop the cached "KB / <total>KB"
	; tail and the last drawn value so the first PROGRESS call always paints.
	XOR	A
	LD	(SUF_OK),A
	LD	(SHOWN),A
	RET
	IFDEF	TPUT_ALIGNED
	IFDEF	TPUT_ALIGN_TEST_SHORT
TPUT_ALIGN_TIMEOUT_MS EQU 4
	ELSE
TPUT_ALIGN_TIMEOUT_MS EQU 2500
	ENDIF
STORE_START
	LD	(T_START),HL
	LD	A,B
	LD	(T_START+2),A
	RET

; ------------------------------------------------------
; START_ALIGNED: wait for an exact DSS RTC second transition, then capture the
; first value on the new second.  The edge-detecting NOW result is stored
; directly; there is deliberately no extra clock read after the transition.
; ------------------------------------------------------
START_ALIGNED
	CALL	NOW
	LD	(T_STOP),HL		; temporary previous sample
	LD	A,B
	LD	(T_STOP+2),A
	LD	HL,TPUT_ALIGN_TIMEOUT_MS
	LD	(ALIGN_LEFT),HL
.WAIT_EDGE
	; Do not spin forever on a stopped/missing RTC. A 1 ms pause also keeps this
	; diagnostic from monopolising the machine while waiting for the edge.
	CALL	@UTIL.DELAY_1MS
	CALL	NOW
	LD	DE,(T_STOP)
	LD	A,L
	CP	E
	JR	NZ,.EDGE
	LD	A,H
	CP	D
	JR	NZ,.EDGE
	LD	A,(T_STOP+2)
	CP	B
	JR	NZ,.EDGE
	LD	HL,(ALIGN_LEFT)
	DEC	HL
	LD	(ALIGN_LEFT),HL
	LD	A,H
	OR	L
	JR	NZ,.WAIT_EDGE
	SCF
	RET
.EDGE
	CALL	STORE_START
	OR	A
	RET

; Capture the stop time.  DLSPEED calls this at the exact Content-Length
; boundary, before CIPCLOSE or any console output.
STOP
	CALL	NOW
	LD	(T_STOP),HL
	LD	A,B
	LD	(T_STOP+2),A
	RET

; Calculate elapsed seconds from the saved start and stop snapshots.
; Out: B:HL = elapsed (24-bit), also stored in T_ELAPSED.
CALC_STOPPED
	LD	HL,(T_STOP)
	LD	A,(T_STOP+2)
	LD	B,A
	LD	DE,(T_START)
	LD	A,L
	SUB	E
	LD	L,A
	LD	A,H
	SBC	A,D
	LD	H,A
	LD	A,(T_START+2)
	LD	E,A
	LD	A,B
	SBC	A,E
	LD	B,A
	JR	NC,.NO_WRAP
	; crossed midnight: add 86400 (0x015180)
	LD	DE,0x5180
	ADD	HL,DE
	LD	A,B
	ADC	A,1
	LD	B,A
.NO_WRAP
	LD	(T_ELAPSED),HL
	LD	A,B
	LD	(T_ELAPSED+2),A
	RET

; Print the saved DLSPEED result.  Unlike REPORT this never reads the RTC.
; In: DE:HL = received bytes. Out: CF=1 when the sample is zero seconds.
REPORT_STOPPED
	LD	(HBUF),HL
	LD	(HBUF+2),DE
	CALL	CALC_STOPPED
	LD	A,B
	OR	H
	OR	L
	JR	Z,.BAD_SAMPLE

	PRINT	S_TIME
	LD	HL,(T_ELAPSED)
	LD	A,(T_ELAPSED+2)
	LD	E,A
	LD	D,0
	CALL	PRINT_DEC_32
	PRINT	S_SEC_NL

	; bytes/sec = received byte count / elapsed seconds.
	LD	HL,(HBUF)
	LD	(SCRATCH),HL
	LD	HL,(HBUF+2)
	LD	(SCRATCH+2),HL
	CALL	DIV32_BY_ELAPSED
	LD	HL,(SCRATCH)
	LD	(HBUF),HL
	LD	HL,(SCRATCH+2)
	LD	(HBUF+2),HL

	PRINT	S_RATE
	LD	HL,(HBUF)
	LD	DE,(HBUF+2)
	CALL	PRINT_DEC_32
	PRINT	S_BPS_PAREN
	; Integer KiB/s = B/s >> 10.
	LD	HL,(HBUF)
	LD	DE,(HBUF+2)
	LD	L,H
	LD	H,E
	LD	E,D
	LD	D,0
	SRL	E
	RR	H
	RR	L
	SRL	E
	RR	H
	RR	L
	CALL	PRINT_DEC_32
	PRINT	S_KIBPS_NL
	OR	A
	RET
.BAD_SAMPLE
	SCF
	RET

; In-place unsigned 32-bit / 24-bit division for the saved DLSPEED duration.
; Dividend/quotient: SCRATCH (LE). Divisor: T_ELAPSED (non-zero, LE).
DIV32_BY_ELAPSED
	XOR	A
	LD	(REM24),A
	LD	(REM24+1),A
	LD	(REM24+2),A
	LD	B,32
.DIV_LOOP
	; Shift the dividend/quotient left and feed its old top bit into REM24.
	LD	HL,SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	LD	HL,REM24
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)

	; Compare remainder and divisor from the most significant byte.
	LD	A,(T_ELAPSED+2)
	LD	C,A
	LD	A,(REM24+2)
	CP	C
	JR	C,.NO_SUB
	JR	NZ,.SUBTRACT
	LD	A,(T_ELAPSED+1)
	LD	C,A
	LD	A,(REM24+1)
	CP	C
	JR	C,.NO_SUB
	JR	NZ,.SUBTRACT
	LD	A,(T_ELAPSED)
	LD	C,A
	LD	A,(REM24)
	CP	C
	JR	C,.NO_SUB
.SUBTRACT
	LD	HL,REM24
	LD	DE,T_ELAPSED
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SUB	C
	LD	(HL),A
	INC	HL
	INC	DE
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SBC	A,C
	LD	(HL),A
	INC	HL
	INC	DE
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	SBC	A,C
	LD	(HL),A
	LD	HL,SCRATCH
	SET	0,(HL)
.NO_SUB
	DJNZ	.DIV_LOOP
	RET
	ENDIF

; ------------------------------------------------------
; REPORT: print "  <bytes> bytes in <secs> sec[, <rate>]".
;   In: DE = high word, HL = low word of bytes transferred.
; Trashes everything.
; ------------------------------------------------------
REPORT
	LD	(HBUF),HL
	LD	(HBUF+2),DE
	CALL	NOW			; current SOD -> B:HL
	; elapsed = current - start (24-bit).
	LD	DE,(T_START)
	LD	A,L
	SUB	E
	LD	L,A
	LD	A,H
	SBC	A,D
	LD	H,A
	LD	A,(T_START+2)
	LD	E,A
	LD	A,B
	SBC	A,E
	LD	B,A
	JR	NC,.NO_WRAP
	; crossed midnight: add 86400 (0x015180).
	LD	DE,0x5180
	ADD	HL,DE
	LD	A,B
	ADC	A,1
	LD	B,A
.NO_WRAP
	LD	(T_ELAPSED),HL
	LD	A,B
	LD	(T_ELAPSED+2),A

	PRINT	S_PREFIX
	LD	HL,(HBUF)
	LD	DE,(HBUF+2)
	CALL	PRINT_DEC_32
	PRINT	S_BYTES_IN
	LD	HL,(T_ELAPSED)
	LD	A,(T_ELAPSED+2)
	LD	E,A
	LD	D,0
	CALL	PRINT_DEC_32
	PRINT	S_SEC

	; rate: skip if elapsed too large (>18h) or zero.
	LD	A,(T_ELAPSED+2)
	OR	A
	JP	NZ,.NL_ONLY
	LD	A,(T_ELAPSED)
	LD	B,A
	LD	A,(T_ELAPSED+1)
	OR	B
	JP	Z,.NL_ONLY

	; B/s = bytes / elapsed (in place).
	LD	HL,(HBUF)
	LD	(SCRATCH),HL
	LD	HL,(HBUF+2)
	LD	(SCRATCH+2),HL
	LD	DE,(T_ELAPSED)
	CALL	DIV32_BY_DE

	PRINT	S_COMMA
	; >= 1024 B/s -> KB/s, else B/s.
	LD	A,(SCRATCH+3)
	OR	A
	JR	NZ,.RATE_KB
	LD	A,(SCRATCH+2)
	OR	A
	JR	NZ,.RATE_KB
	LD	A,(SCRATCH+1)
	CP	4
	JR	NC,.RATE_KB

	LD	HL,(SCRATCH)
	LD	DE,(SCRATCH+2)
	CALL	PRINT_DEC_32
	PRINT	S_BPS
	JR	.NL_ONLY
.RATE_KB
	; KB/s = quotient >> 10.
	LD	HL,(SCRATCH)
	LD	DE,(SCRATCH+2)
	LD	L,H
	LD	H,E
	LD	E,D
	LD	D,0
	SRL	E
	RR	H
	RR	L
	SRL	E
	RR	H
	RR	L
	CALL	PRINT_DEC_32
	PRINT	S_KBS
.NL_ONLY
	PRINT	S_NL
	RET

; ------------------------------------------------------
; PRINT_DEC_32: print 32-bit value (HL=low, DE=high) as unsigned decimal.
; ------------------------------------------------------
PRINT_DEC_32
	LD	(SCRATCH),HL
	LD	(SCRATCH+2),DE
	LD	A,(SCRATCH)
	LD	B,A
	LD	A,(SCRATCH+1)
	OR	B
	LD	B,A
	LD	A,(SCRATCH+2)
	OR	B
	LD	B,A
	LD	A,(SCRATCH+3)
	OR	B
	JR	NZ,.NZ
	LD	A,'0'
	LD	C,DSS_PUTCHAR
	RST	DSS
	RET
.NZ
	LD	B,0			; digit count
.LP
	CALL	.DIV32_10
	ADD	A,'0'
	PUSH	AF
	INC	B
	LD	A,(SCRATCH)
	LD	C,A
	LD	A,(SCRATCH+1)
	OR	C
	LD	C,A
	LD	A,(SCRATCH+2)
	OR	C
	LD	C,A
	LD	A,(SCRATCH+3)
	OR	C
	JR	NZ,.LP
.OUT
	POP	AF
	PUSH	BC
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	BC
	DJNZ	.OUT
	RET

; .DIV32_10: SCRATCH(32-bit LE) /= 10 in place; A = remainder. Preserves B.
.DIV32_10
	PUSH	BC
	PUSH	DE
	LD	HL,0
	LD	B,32
.DLP
	PUSH	HL
	LD	HL,SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	ADC	HL,HL
	LD	DE,10
	OR	A
	SBC	HL,DE
	JR	NC,.DSUB
	ADD	HL,DE
	JR	.DNEXT
.DSUB
	PUSH	HL
	LD	HL,SCRATCH
	SET	0,(HL)
	POP	HL
.DNEXT
	DJNZ	.DLP
	LD	A,L
	POP	DE
	POP	BC
	RET

; ------------------------------------------------------
; DIV32_BY_DE: in-place 32-bit / 16-bit unsigned division.
;   Dividend: SCRATCH (4 bytes LE), replaced by quotient. Divisor: DE (>0).
;   Out: HL = remainder. DE preserved.
; ------------------------------------------------------
DIV32_BY_DE
	LD	HL,0
	LD	B,32
.LP
	PUSH	HL
	LD	HL,SCRATCH
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	ADC	HL,HL
	JR	C,.SUB_FORCE
	OR	A
	SBC	HL,DE
	JR	C,.NOSUB
	JR	.SET
.SUB_FORCE
	OR	A
	SBC	HL,DE
.SET
	PUSH	HL
	LD	HL,SCRATCH
	SET	0,(HL)
	POP	HL
	JR	.NEXT
.NOSUB
	ADD	HL,DE
.NEXT
	DJNZ	.LP
	RET

; ------------------------------------------------------
; PROGRESS: in-place download progress line "<dlKB>KB / <totalKB>KB".
; Emits 0x0D first so repeated calls overwrite the same line (on this console
; 0x0D resets the X column, 0x0A is the line feed). No trailing newline; the
; caller prints a real newline (LINE_END) once the transfer is done.
; In: HL = ptr to downloaded byte count (4-byte LE),
;     DE = ptr to total byte count   (4-byte LE; all-zero -> shown as "?").
; Trashes everything.
; ------------------------------------------------------
PROGRESS
	XOR	A
	JR	PROGRESS_MODE

; Variant for a caller which already owns an RX pause. It renders the same
; line but deliberately leaves RTS deasserted. FTP download uses this while it
; writes a received block: the normal nested pause/resume pair would otherwise
; release the next +IPD burst before the outer receive loop was ready to drain.
PROGRESS_PAUSED
	LD	A,1
PROGRESS_MODE
	LD	(PROGRESS_RX_HELD),A
	PUSH	DE			; total ptr
	CALL	KB_AT_HL		; B:HL = downloaded KB
	LD	(CUR_KB),HL
	LD	A,B
	LD	(CUR_KB+2),A
	POP	HL			; total ptr
	CALL	SYNC_SUFFIX		; CF=1 -> tail rebuilt, repaint is mandatory
	JR	C,.REPAINT
	LD	A,(SHOWN)
	AND	A
	JR	Z,.REPAINT
	; Same total and the same KB figure: the line already on screen is
	; character-for-character what a repaint would produce, so skip it (and
	; skip the RTS pause with it). This is not decimation — every KB step is
	; still drawn; only the redundant redraws of an unchanged number are
	; dropped, which is most of them when ESP delivers sub-KB +IPD chunks.
	LD	HL,(LAST_KB)
	LD	DE,(CUR_KB)
	OR	A
	SBC	HL,DE
	JR	NZ,.REPAINT
	LD	A,(LAST_KB+2)
	LD	HL,CUR_KB+2
	CP	(HL)
	JR	NZ,.REPAINT
	OR	A			; CF=0 (success)
	RET
.REPAINT
	CALL	BUILD_LINE
	; A console repaint is far slower than the old single dot and would stall
	; the UART read long enough to overrun the 16-byte RX FIFO. Keep the common
	; receive guard around it: both current firmware profiles explicitly lower
	; RTS here, since auto-only AFE proved insufficient for real 2.2.2 +IPD
	; bursts. The line is formatted BEFORE the pause, so RTS now stays down for
	; a single DSS_PCHARS instead of a divide-and-putchar sequence.
	; MUST return CF=0 — callers propagate CF as success/fail.
	LD	A,(PROGRESS_RX_HELD)
	AND	A
	JR	NZ,.PRINT_HELD
	CALL	@WIFI.UART_RX_PAUSE
.PRINT_HELD
	LD	HL,LINE
	LD	C,DSS_PCHARS
	RST	DSS
	LD	A,(PROGRESS_RX_HELD)
	AND	A
	JR	NZ,.RX_READY
	CALL	@WIFI.UART_RX_RESUME
.RX_READY
	LD	HL,(CUR_KB)
	LD	(LAST_KB),HL
	LD	A,(CUR_KB+2)
	LD	(LAST_KB+2),A
	LD	A,1
	LD	(SHOWN),A
	OR	A			; CF=0 (success)
	RET

; ------------------------------------------------------
; SYNC_SUFFIX: keep the cached "KB / <totalKB>KB" tail in step with the total.
; The total is constant for a whole transfer, so its KB conversion and decimal
; formatting run once instead of on every repaint. FTP learns the size only from
; the 150 reply, so the total can still change mid-transfer.
;   In:  HL = ptr to total byte count (4-byte LE; all-zero -> "?").
;   Out: CF=1 when the tail was rebuilt (forces a repaint), CF=0 when unchanged.
; ------------------------------------------------------
SYNC_SUFFIX
	PUSH	HL
	LD	A,(SUF_OK)
	AND	A
	JR	Z,.BUILD
	LD	DE,LAST_TOT
	LD	B,4
.CMP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.BUILD
	INC	HL
	INC	DE
	DJNZ	.CMP
	POP	HL
	OR	A			; CF=0: cached tail still valid
	RET
.BUILD
	POP	HL			; total ptr
	LD	DE,LAST_TOT
	PUSH	HL
	LD	BC,4
	LDIR
	POP	HL
	LD	IX,SUFFIX
	LD	DE,S_PROG_MID		; "KB / "
	CALL	APPEND_STR
	LD	A,(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	JR	NZ,.HAVE_TOTAL
	LD	(IX+0),'?'		; total unknown
	INC	IX
	JR	.TAIL
.HAVE_TOTAL
	LD	HL,LAST_TOT
	CALL	KB_AT_HL		; B:HL = total KB
	CALL	FORMAT_KB
.TAIL
	LD	DE,S_PROG_KB		; "KB"
	CALL	APPEND_STR
	LD	(IX+0),0
	LD	A,1
	LD	(SUF_OK),A
	SCF				; tail changed -> repaint
	RET

; Build "<CR><dlKB>" + cached tail into LINE, ready for one DSS_PCHARS.
BUILD_LINE
	LD	IX,LINE
	LD	(IX+0),0x0D		; reset X to column 0 (this console: 0x0D=CR, 0x0A=LF)
	INC	IX
	LD	HL,(CUR_KB)
	LD	A,(CUR_KB+2)
	LD	B,A
	CALL	FORMAT_KB
	LD	DE,SUFFIX
	CALL	APPEND_STR
	LD	(IX+0),0
	RET

; APPEND_STR: copy the ASCIIZ string at (DE) to (IX), terminator excluded.
APPEND_STR
	LD	A,(DE)
	AND	A
	RET	Z
	LD	(IX+0),A
	INC	IX
	INC	DE
	JR	APPEND_STR

; ------------------------------------------------------
; KB_AT_HL: 4-byte LE value at (HL) -> B:HL = value / 1024.
; KB = value >> 10 = drop the low byte, then >> 2 — avoids a 32-iteration long
; division on every progress repaint.
; ------------------------------------------------------
KB_AT_HL
	INC	HL
	LD	E,(HL)			; byte 1
	INC	HL
	LD	D,(HL)			; byte 2
	INC	HL
	LD	B,(HL)			; byte 3
	EX	DE,HL			; HL = bytes 2:1 (= value >> 8)
	SRL	B
	RR	H
	RR	L
	SRL	B
	RR	H
	RR	L
	RET

; ------------------------------------------------------
; FORMAT_KB: write B:HL (24-bit, the full range of a 4 GB byte count in KB) as
; unsigned decimal at (IX). No leading zeros, no terminator. Repeated
; subtraction of a power of ten per digit: ~2.5k T-states worst case, where the
; shared PRINT_DEC_32 spends a 32-iteration long division on EVERY digit.
;   Out: IX past the last digit. Trashes A,BC,DE,HL.
; ------------------------------------------------------
FORMAT_KB
	XOR	A
	LD	(FMT_STARTED),A
	LD	DE,0x4240		; 1000000
	LD	C,0x0F
	CALL	.DIGIT
	LD	DE,0x86A0		; 100000
	LD	C,0x01
	CALL	.DIGIT
	LD	C,0
	LD	DE,10000
	CALL	.DIGIT
	LD	DE,1000
	CALL	.DIGIT
	LD	DE,100
	CALL	.DIGIT
	LD	DE,10
	CALL	.DIGIT
	LD	A,L			; remainder < 10: always printed
	ADD	A,'0'
	LD	(IX+0),A
	INC	IX
	RET

; One digit: subtract C:DE from B:HL while it fits, emit the count.
.DIGIT
	XOR	A
	LD	(FMT_DIG),A
.SUB
	OR	A
	SBC	HL,DE
	LD	A,B
	SBC	A,C
	JR	C,.RESTORE
	LD	B,A
	LD	A,(FMT_DIG)
	INC	A
	LD	(FMT_DIG),A
	JR	.SUB
.RESTORE
	ADD	HL,DE			; undo the failed subtract (B was not stored)
	LD	A,(FMT_DIG)
	AND	A
	JR	NZ,.EMIT
	LD	A,(FMT_STARTED)
	AND	A
	RET	Z			; leading zero: nothing printed yet
	XOR	A
.EMIT
	ADD	A,'0'
	LD	(IX+0),A
	INC	IX
	LD	A,1
	LD	(FMT_STARTED),A
	RET

S_PROG_MID	DB "KB / ",0
S_PROG_KB	DB "KB",0

S_PREFIX	DB "  ",0
S_BYTES_IN	DB " bytes in ",0
S_SEC		DB " sec",0
S_COMMA		DB ", ",0
S_KBS		DB " KB/s",0
S_BPS		DB " B/s",0
S_NL		DB 13,10,0
	IFDEF	TPUT_ALIGNED
S_TIME		DB "Time: ",0
S_SEC_NL	DB " sec",13,10,0
S_RATE		DB "Rate: ",0
S_BPS_PAREN	DB " B/s (",0
S_KIBPS_NL	DB " KiB/s)",13,10,0
	ENDIF

; Small in-image scratch/state (not large runtime buffers).
T_START		DS 3,0
	IFDEF	TPUT_ALIGNED
T_STOP		DS 3,0
REM24		DS 3,0
ALIGN_LEFT	DS 2,0
	ENDIF
T_ELAPSED	DS 3,0
HBUF		DS 4,0
SCRATCH		DS 4,0

; Progress-line state. LINE is at most CR + 7 digits + "KB / " + 7 digits +
; "KB" + NUL = 23 bytes; SUFFIX holds the cached tail alone.
CUR_KB		DS 3,0
LAST_KB		DS 3,0
LAST_TOT	DS 4,0
SUF_OK		DB 0
SHOWN		DB 0
FMT_DIG		DB 0
FMT_STARTED	DB 0
PROGRESS_RX_HELD DB 0
SUFFIX		DS 16,0
LINE		DS 24,0

	ENDMODULE

	ENDIF
