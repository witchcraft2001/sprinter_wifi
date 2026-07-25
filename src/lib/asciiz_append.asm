; ======================================================
; Shared ASCIIZ buffer append helpers.
;
; Each append leaves a zero terminator at HL; a following append overwrites
; that terminator. This makes every intermediate and final dynamically built
; command a valid ASCIIZ string even when its runtime BSS buffer initially
; contains non-zero data.
; ======================================================

	IFNDEF	_ASCIIZ_APPEND
	DEFINE	_ASCIIZ_APPEND

; Append ASCIIZ from DE to buffer at HL.
; Out: HL points at the copied zero terminator.
APPEND_STR
	LD	A,(DE)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	APPEND_STR

; Append ASCIIZ from IX to buffer at HL.
; Out: HL points at the copied zero terminator.
APPEND_IX_STR
	LD	A,(IX+0)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	IX
	JR	APPEND_IX_STR

	ENDIF
