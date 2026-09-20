; ======================================================
; ISA Library for Sprinter computer
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_ISA
	DEFINE	_ISA

	INCLUDE "sprinter.inc"
	INCLUDE "util.asm"

PORT_ISA		EQU 0x9FBD
PORT_SYSTEM		EQU 0x1FFD

ISA_BASE_A		EQU 0xC000								; Базовый адрес портов ISA в памяти

; --- PORT_ISA bits
ISA_A14  		EQU	0x01
ISA_A15  		EQU	0x02
ISA_A16  		EQU	0x04
ISA_A17  		EQU	0x08
ISA_A18  		EQU	0x10
ISA_A19  		EQU	0x20
ISA_AEN  		EQU	0x40
ISA_RST			EQU	0x80

	MODULE	ISA

; ------------------------------------------------------
; Reset ISA device
; ------------------------------------------------------
ISA_RESET
	LD		BC, PORT_ISA
	LD		A,ISA_RST | ISA_AEN							; RESET=1 AEN=1
	OUT 	(C), A
	CALL 	@UTIL.DELAY_1MS
	XOR 	A
	OUT 	(C), A										; RESET=0 AEN=0
	LD		HL,100
	JP		@UTIL.DELAY
	;RET

; ------------------------------------------------------
; Open access to ISA ports as memory
; ------------------------------------------------------
ISA_OPEN
	PUSH	AF,BC
	IFDEF ISA_RX_GUARD
	; FTP 2.2.2 holds RTS high only while draining mapped UART registers.
	; DSS interrupts may spend longer than a FIFO's worth of time away from
	; that loop. Match RTL's IFF-preserving ISA critical section, but opt in
	; at runtime so the proven 2.2.1 receive path is not changed.
	LD	A,(RX_CRITICAL)
	OR	A
	JR	Z,.SAVE_IFF
	LD	A,I
	JP	PE,.IFF_ON
	LD	A,I			; retry the NMOS LD A,I interrupt race, as RTL does
	JP	PE,.IFF_ON
	DI
	XOR	A
	JR	.SAVE_IFF
.IFF_ON
	DI
	LD	A,1
.SAVE_IFF
	; Do not disable interrupts in the legacy path.
	LD	(SAVE_IFF),A
	ENDIF
	LD		BC, PAGE3
	IN 		A,(C)
	LD 		(SAVE_MMU3), A
	LD 		BC, PORT_SYSTEM
	LD 		A, 0x11
	OUT 	(C), A
ISA_SLOT	EQU $+1
	LD		A, 0x00
	SLA		A
	OR 		A, 0xD4										; D4 - ISA1, D6 - ISA2
	//AND		A, 0xFB										; mem
	LD		BC, PAGE3
	OUT 	(C), A
	LD 		BC, PORT_ISA
	XOR 	A
	OUT 	(C), A
	POP 	BC,AF
	RET


; ------------------------------------------------------
; Close access to ISA ports
; ------------------------------------------------------
ISA_CLOSE
	PUSH	AF,BC
	LD		A,0x01
	LD 		BC,PORT_SYSTEM
	OUT		(C),A
	LD		BC,PAGE3
	LD		A,(SAVE_MMU3)
	OUT		(C),A
	IFDEF ISA_RX_GUARD
	; The guarded caller must lower RTS BEFORE closing ISA. This also allows
	; idle/cancel checks to service DSS interrupts safely between drain runs.
	LD	A,(SAVE_IFF)
	OR	A
	JR	Z,.NO_EI
	EI
.NO_EI
	ENDIF
	POP		BC,AF
	RET

; To save memory page 3
SAVE_MMU3		DB	0
	IFDEF ISA_RX_GUARD
RX_CRITICAL		DB	0
SAVE_IFF		DB	0
	ENDIF

	ENDMODULE

	ENDIF
