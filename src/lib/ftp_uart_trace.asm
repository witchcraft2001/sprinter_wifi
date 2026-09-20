; Developer-only boundary probes; no hot per-byte logging, no FIFO flush or
; UART reconfiguration. All probes run with RTS paused. Reading LSR clears
; error bits, so retain them across the caller's per-receive accumulator reset.
	MODULE UART_TRACE

; Reserve 11 bytes in the unused last 64 bytes of the allocated WIN2 page.
DATA	EQU MAIN.WIN2_BASE + 0x3FC0
FIRST	EQU DATA + 5
ERRORS	EQU DATA + 6
COUNT	EQU 11
	ASSERT DATA + COUNT <= 0xC000
	ASSERT MAIN.PASV_PORT_BUFF + 8 <= DATA

INIT
	LD	HL,DATA
	LD	B,COUNT
.CLEAR
	LD	(HL),0xFF		; FF = boundary has not yet been sampled
	INC	HL
	DJNZ	.CLEAR
	XOR	A
	LD	(FIRST),A
	LD	(ERRORS),A
	RET

; A=1 pre-resume, 2 stopped, 3 before write, 4 after write, 5 after progress.
; Preserves BC/DE/HL; caller saves AF. 2.2.1 performs no extra UART reads.
SAMPLE
	PUSH	BC,DE,HL
	LD	C,A
	LD	A,(WCOMMON.UART_ESP_PROFILE)
	CP	UART_RX_PROFILE_222
	JR	NZ,.DONE
	LD	A,C
	CALL	ISA.ISA_OPEN
	CALL	RECORD
	CALL	ISA.ISA_CLOSE
.DONE
	POP	HL,DE,BC
	RET

SAMPLE_OPEN
	PUSH	BC,DE,HL
	CALL	RECORD
	POP	HL,DE,BC
	RET

RECORD
	LD	C,A
	LD	L,A
	LD	H,0
	LD	DE,DATA-1
	ADD	HL,DE
	LD	A,(REG_LSR)
	LD	(HL),A
	AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	JR	Z,.MERGE
	LD	HL,ERRORS
	OR	(HL)
	LD	(HL),A
	LD	A,(FIRST)
	OR	A
	JR	NZ,.MERGE
	LD	A,C
	LD	(FIRST),A
.MERGE
	; Never hide an error by acknowledging it here: the next pre-resume probe
	; re-injects this sticky mask even if RECV_DATA_TRANSFER cleared LSR_ACCUM.
	LD	A,(ERRORS)
	LD	HL,TCP.LSR_ACCUM
	OR	(HL)
	LD	(HL),A
	RET

REPORT
	; Read-only register snapshot at report time. Do not change DLAB to read
	; the baud divisor: diagnostic reads must not alter live UART framing.
	CALL	ISA.ISA_OPEN
	LD	A,(REG_LCR)
	LD	(DATA+7),A
	LD	A,(REG_MCR)
	LD	(DATA+8),A
	LD	A,(REG_IIR)
	LD	(DATA+9),A
	CALL	ISA.ISA_CLOSE
	LD	A,(TCP.MULTI_DIAG_PHASE)
	LD	(DATA+10),A
	PRINTLN HEADER
	LD	HL,DATA
	LD	DE,ROW
	LD	B,COUNT
.HEX
	LD	C,(HL)
	INC	HL
	CALL	UTIL.HEXB
	INC	DE
	DJNZ	.HEX
	PRINTLN ROW
	RET

HEADER	DB "UART trace: pre stp wr0 wr1 ui first err LCR MCR IIR rx",0
ROW	DB "xx xx xx xx xx xx xx xx xx xx xx",0
	ENDMODULE
