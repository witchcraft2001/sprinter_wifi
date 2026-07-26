; Host-side regression harness for the libman 1.3 DLL dispatcher.
; Run through tools/test-libman.sh.
;
; Estex-DSS returns the previously mapped physical page from SETWIN with CF=0.
; The dispatcher must call DLL INIT only after that successful mapping and
; preserve a real SETWIN failure separately from INIT's A/CF result.

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"

TEST_RESULT	EQU 0xC100
INIT_CALLED	EQU 0xC101
SETWIN_FAIL	EQU 0xC102
INFO_COPY	EQU 0xC110

; Fake RST #10 dispatcher. Generic DSS_SETWIN is rejected deliberately:
; current Estex-DSS computes its slot port incorrectly, so libman must use the
; explicit SETWIN1/2/3 entry points.
	ORG 0x0010

DSS_STUB
	LD	A,C
	CP	DSS_SETWIN1
	JR	Z,.SETWIN
	CP	DSS_SETWIN2
	JR	Z,.SETWIN
	CP	DSS_SETWIN3
	JR	NZ,.BAD_CALL
.SETWIN
	LD	A,(SETWIN_FAIL)
	OR	A
	JR	NZ,.SETWIN_ERROR
	LD	IX,0xDEAD		; DSS/BIOS is allowed to clobber index registers
	LD	IY,0xBEEF
	LD	H,0xE2			; Estex-DSS SETWIN derives and returns SLOT in H
	LD	A,0x8C			; previously mapped physical page
	OR	A				; successful Estex-DSS SETWIN clears CF
	RET
.SETWIN_ERROR
	LD	A,0x1F			; representative DSS memory-handle error
	SCF
	RET
.BAD_CALL
	LD	A,1
	LD	(TEST_RESULT),A
	SCF
	RET

	ASSERT $ < 0x0100
	DS	0x0100 - $,0

TEST_START
	LD	SP,0x3FF0
	XOR	A
	LD	(TEST_RESULT),A
	LD	(INIT_CALLED),A
	LD	(SETWIN_FAIL),A

	; Install one synthetic library-table entry: handle 0, one page in WIN1.
	LD	HL,LIBMAN.lib_table
	LD	(HL),1			; occupied
	INC	HL
	LD	(HL),7			; fake DSS block ID
	INC	HL
	LD	(HL),0x40		; start at 0x4000
	INC	HL
	LD	(HL),0x41		; end high byte (not used by l_call)

	LD	HL,0			; library handle
	LD	B,0			; INIT
	CALL	LIBMAN.l_call
	JP	C,FAILED
	OR	A
	JP	NZ,FAILED
	LD	A,(INIT_CALLED)
	CP	0xA5
	JP	NZ,FAILED

	; l_info must preserve its C000 source address across Estex-DSS SETWIN.
	LD	HL,0
	LD	DE,INFO_COPY
	CALL	LIBMAN.l_info
	JP	C,FAILED
	LD	A,(INFO_COPY)
	CP	'L'
	JP	NZ,FAILED
	LD	A,(INFO_COPY+1)
	CP	'1'
	JP	NZ,FAILED
	LD	A,(INFO_COPY+16)
	CP	'T'
	JP	NZ,FAILED

	; A normal exported call must survive SETWIN's register clobbering too.
	LD	HL,0
	LD	B,2
	CALL	LIBMAN.l_call
	JP	C,FAILED
	LD	A,D
	CP	0x01
	JP	NZ,FAILED
	LD	A,E
	CP	0x0F
	JP	NZ,FAILED
	PUSH	IX
	POP	HL
	LD	A,H
	CP	0x01
	JP	NZ,FAILED
	LD	A,L
	OR	A
	JP	NZ,FAILED

	; Public IX/IY arguments must survive the internal DSS_SETWIN call.
	LD	IX,0x1234
	LD	IY,0x5678
	LD	HL,0
	LD	B,3
	CALL	LIBMAN.l_call
	JP	C,FAILED
	OR	A
	JP	NZ,FAILED

	; A real SETWIN error must not enter the DLL and must preserve the raw DSS
	; error separately from the dispatch-stage discriminator.
	XOR	A
	LD	(INIT_CALLED),A
	INC	A
	LD	(SETWIN_FAIL),A
	LD	HL,0
	LD	B,0
	LD	A,0x8C
	CALL	LIBMAN.l_call
	JP	NC,FAILED
	CP	0x8C
	JP	NZ,FAILED
	LD	A,(LIBMAN.l_call_error)
	CP	LIBMAN.LCERR_SETWIN
	JP	NZ,FAILED
	LD	A,(LIBMAN.l_call_dsserr)
	CP	0x1F
	JP	NZ,FAILED
	LD	A,(INIT_CALLED)
	OR	A
	JP	NZ,FAILED
	XOR	A
	LD	(SETWIN_FAIL),A

	; An empty table entry is an internal dispatcher failure, not an INIT
	; refusal. l_call historically preserves the caller's A (#8C here).
	LD	HL,LIBMAN.lib_table
	LD	(HL),0
	LD	HL,0
	LD	B,0
	LD	A,0x8C
	CALL	LIBMAN.l_call
	JP	NC,FAILED
	CP	0x8C
	JP	NZ,FAILED
	LD	A,(LIBMAN.l_call_error)
	CP	LIBMAN.LCERR_HANDLE
	JP	NZ,FAILED

	; An occupied entry whose address is outside WIN1..WIN3 must be reported
	; separately from both the bad-handle case and the DLL's own INIT result.
	LD	HL,LIBMAN.lib_table
	LD	(HL),1
	INC	HL
	LD	(HL),7
	INC	HL
	LD	(HL),0x00
	INC	HL
	LD	(HL),0x01
	LD	HL,0
	LD	B,0
	LD	A,0x8C
	CALL	LIBMAN.l_call
	JP	NC,FAILED
	CP	0x8C
	JP	NZ,FAILED
	LD	A,(LIBMAN.l_call_error)
	CP	LIBMAN.LCERR_WINDOW
	JP	NZ,FAILED
	JP	TEST_DONE

FAILED
	LD	A,1
	LD	(TEST_RESULT),A

TEST_DONE
	HALT

; Synthetic DLL image in WIN1: libman dispatches function 0 through 0x4020.
	ASSERT $ < 0x4020
	DS	0x4020 - $,0

	JP	DLL_INIT
	JP	DLL_FINI
	JP	DLL_CAPS
	JP	DLL_ARGS

DLL_INIT
	LD	A,0xA5
	LD	(INIT_CALLED),A
	XOR	A
	RET

DLL_FINI
	XOR	A
	RET

DLL_CAPS
	LD	DE,0x010F
	LD	IX,0x0100
	XOR	A
	RET

DLL_ARGS
	PUSH	IX
	POP	HL
	LD	DE,0x1234
	OR	A
	SBC	HL,DE
	JR	NZ,.bad
	PUSH	IY
	POP	HL
	LD	DE,0x5678
	OR	A
	SBC	HL,DE
	JR	NZ,.bad
	XOR	A
	RET
.bad
	LD	A,1
	OR	A
	RET

; Exercise the actual vendored dispatcher, not a test copy.
	ASSERT $ < 0x8000
	DS	0x8000 - $,0

	INCLUDE "libman13.asm"

; Header exposed through l_info after the synthetic page is mapped in WIN3.
	ASSERT $ < 0xC000
	DS	0xC000 - $,0
	DB	"L1"
	DS	14,0
	DB	"TEST DLL",0
	DS	8,0

	END TEST_START
