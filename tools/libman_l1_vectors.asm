; Host-side regression vector for the real UNETESP L1 relocation bitmap.
; DLL_CODE_SIZE is read from the L1 header by tools/test-libman.sh.

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"

TEST_RESULT	EQU 0x7000
INFO_OUT	EQU 0xA000

	ORG 0x0010

; The image is already copied into logical WIN1 by this flat-memory harness.
; Require explicit SETWIN1: generic SETWIN is broken in current Estex-DSS.
DSS_STUB
	LD	A,C
	CP	DSS_ENVIRON
	JR	Z,.env
	CP	DSS_SETWIN1
	JR	NZ,.bad
	LD	IX,0xDEAD
	LD	IY,0xBEEF
	LD	H,0xE2			; reproduce Estex-DSS register clobbering
	LD	A,0x8C
	OR	A
	RET
.env
	LD	HL,ENV_VALUE
.env_copy
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.env_copy
	LD	A,0xFF
	OR	A
	RET
.bad
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

	; Reproduce libman 1.3's L1 relocation inputs exactly.
	LD	HL,DLL_IMAGE + 32
	LD	IY,DLL_IMAGE + DLL_CODE_SIZE
	LD	DE,DLL_CODE_SIZE - 1
	LD	BC,0x4000
	CALL	LIBMAN.remake

	; libman keeps the L1 header in memory and places the export table at +32.
	LD	HL,DLL_IMAGE
	LD	DE,0x4000
	LD	BC,DLL_CODE_SIZE
	LDIR

	LD	HL,LIBMAN.lib_table
	LD	(HL),1
	INC	HL
	LD	(HL),7
	INC	HL
	LD	(HL),0x40
	INC	HL
	LD	(HL),0x5B

	LD	HL,0
	LD	B,UNET_FN_GETCAPS
	CALL	LIBMAN.l_call
	JR	C,FAILED
	LD	A,D
	CP	HIGH EXPECTED_CAPS
	JR	NZ,FAILED
	LD	A,E
	CP	LOW EXPECTED_CAPS
	JR	NZ,FAILED
	PUSH	IX
	POP	HL
	LD	DE,UNET_ABI_VERSION
	OR	A
	SBC	HL,DE
	JR	NZ,FAILED

	; Exercise a real pointer+length export. This catches CHECK_BUF_RANGE
	; corrupting BC while it checks the caller's window.
	LD	A,UNET_IF_IP
	LD	DE,INFO_OUT
	LD	IX,32
	LD	HL,0
	LD	B,UNET_FN_GETINFO
	CALL	LIBMAN.l_call
	JR	C,FAILED
	OR	A
	JR	NZ,FAILED
	LD	A,(INFO_OUT)
	CP	'1'
	JR	NZ,FAILED
	LD	A,(INFO_OUT + 12)
	OR	A
	JR	NZ,FAILED
	JR	TEST_DONE

FAILED
	LD	A,1
	LD	(TEST_RESULT),A

TEST_DONE
	HALT

EXPECTED_CAPS	EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING | UNET_CAP_RXFLOW
ENV_VALUE	DB "192.168.1.2",0

	ASSERT $ < 0x7800
	DS	0x7800 - $,0

	INCLUDE "unet.inc"
	INCLUDE "libman13.asm"

	ASSERT $ < 0xC000
	DS	0xC000 - $,0

DLL_IMAGE
	INCBIN "../build/UNETESP.DLL"

	END TEST_START
