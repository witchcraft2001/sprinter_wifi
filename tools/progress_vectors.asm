; Host-side regression harness for the actual TPUT.PROGRESS render path
; (KB conversion, decimal formatting, cached total tail, unchanged-value skip).
; Run through tools/test-progress.sh.

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"

TEST_RESULT	EQU 0xC000
CAPTURE		EQU 0xC100

	ORG 0x4000

TEST_START
	XOR	A
	LD	(TEST_RESULT),A
	; RST DSS (0x10) is below the loaded image: plant a JP to the stub.
	LD	A,0xC3
	LD	(DSS),A
	LD	HL,DSS_STUB
	LD	(DSS+1),HL

	CALL	TPUT.START

	; 1. First paint: nothing downloaded, size unknown.
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; 2. Below the next KB boundary: the line would be identical, so no paint
	;    and, just as important, no RTS pause.
	LD	HL,1023
	CALL	SET_DONE
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED
	LD	A,(WIFI.PAUSE_COUNT)
	CP	1
	JP	NZ,FAILED

	; 3. KB figure moves -> paint.
	LD	HL,1024
	CALL	SET_DONE
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; 4. FTP learns the size mid-transfer: the cached tail must be rebuilt and
	;    the line repainted even though the KB figure did not move.
	LD	HL,0x0000
	LD	(TOTAL),HL
	LD	HL,0x0010		; 1048576 bytes = 1024 KB
	LD	(TOTAL+2),HL
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; 5. Transfer complete: done == total.
	LD	HL,0x0000
	LD	(DONE),HL
	LD	HL,0x0010
	LD	(DONE+2),HL
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; 6. Seven-digit KB (0xFFFFFFFF bytes = 4194303 KB): the widest line the
	;    formatter can produce.
	LD	HL,0xFFFF
	LD	(DONE),HL
	LD	(DONE+2),HL
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; 7. Zero suppression inside the number: 1024000000 bytes = 1000000 KB.
	LD	HL,0x0000
	LD	(DONE),HL
	LD	HL,0x3D09
	LD	(DONE+2),HL
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; 8. A new transfer must repaint even with values identical to the last
	;    line drawn (TPUT.START drops the cache).
	CALL	TPUT.START
	LD	HL,DONE
	LD	DE,TOTAL
	CALL	TPUT.PROGRESS
	JP	C,FAILED

	; Every paint must have re-armed RTS exactly once.
	LD	A,(WIFI.PAUSE_COUNT)
	CP	7
	JP	NZ,FAILED
	LD	A,(WIFI.RESUME_COUNT)
	CP	7
	JP	NZ,FAILED

	; Compare the whole captured stream.
	LD	HL,CAPTURE
	LD	DE,EXPECTED
	LD	BC,EXPECTED_LEN
.COMPARE
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAILED
	INC	HL
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.COMPARE
	LD	HL,(CAPTURE_PTR)
	LD	DE,CAPTURE+EXPECTED_LEN
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED
	JR	TEST_DONE

FAILED
	LD	A,1
	LD	(TEST_RESULT),A
TEST_DONE
	RET

; SET_DONE: DONE = HL (high word cleared).
SET_DONE
	LD	(DONE),HL
	LD	HL,0
	LD	(DONE+2),HL
	RET

; ------------------------------------------------------
; DSS stub: capture console output, hand back a fixed clock.
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
.SYSTIME
	POP	AF
	LD	H,1			; 01:02:03
	LD	L,2
	LD	B,3
	RET

CAPTURE_PTR	DW CAPTURE

DONE		DS 4,0
TOTAL		DS 4,0

EXPECTED
	DB 13,"0KB / ?KB"
	; 1023 bytes: no repaint at all
	DB 13,"1KB / ?KB"
	DB 13,"1KB / 1024KB"
	DB 13,"1024KB / 1024KB"
	DB 13,"4194303KB / 1024KB"
	DB 13,"1000000KB / 1024KB"
	DB 13,"1000000KB / 1024KB"
EXPECTED_LEN	EQU $ - EXPECTED

	MODULE WIFI
UART_RX_PAUSE
	PUSH	AF
	LD	A,(PAUSE_COUNT)
	INC	A
	LD	(PAUSE_COUNT),A
	POP	AF
	RET
UART_RX_RESUME
	PUSH	AF
	LD	A,(RESUME_COUNT)
	INC	A
	LD	(RESUME_COUNT),A
	POP	AF
	RET
PAUSE_COUNT	DB 0
RESUME_COUNT	DB 0
	ENDMODULE

	INCLUDE "tput_lib.asm"

	END TEST_START
