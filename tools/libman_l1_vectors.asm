; Host-side regression vector for the real UNETESP L1 relocation bitmap.
; DLL_CODE_SIZE is read from the L1 header by tools/test-libman.sh.

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"

TEST_RESULT	EQU 0x7000
TEST_STAGE	EQU 0x7001
INFO_WIN0	EQU 0x2000
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
	LD	A,1
	LD	(TEST_STAGE),A

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

	; The real relocated INIT contains an absolute CALL/variable reference and
	; is exactly the function l_load invokes before returning to the application.
	; Exercise it before GETCAPS so a damaged early relocation fails here instead
	; of escaping through DSS's emergency return address as error #27.
	LD	A,2
	LD	(TEST_STAGE),A
	LD	HL,0
	LD	B,0
	CALL	LIBMAN.l_call
	JP	C,FAILED_INIT_CF
	OR	A
	JP	NZ,FAILED_INIT_A

	LD	A,3
	LD	(TEST_STAGE),A
	LD	HL,0
	LD	B,UNET_FN_GETCAPS
	CALL	LIBMAN.l_call
	JP	C,FAILED
	LD	A,D
	CP	HIGH EXPECTED_CAPS
	JP	NZ,FAILED
	LD	A,E
	CP	LOW EXPECTED_CAPS
	JP	NZ,FAILED
	PUSH	IX
	POP	HL
	LD	DE,UNET_ABI_VERSION
	OR	A
	SBC	HL,DE
	JP	NZ,FAILED

	; Exercise a real pointer+length export. This catches CHECK_BUF_RANGE
	; corrupting BC while it checks the caller's window.
	LD	A,4
	LD	(TEST_STAGE),A
	LD	A,UNET_IF_IP
	LD	DE,INFO_OUT
	LD	IX,32
	LD	HL,0
	LD	B,UNET_FN_GETINFO
	CALL	LIBMAN.l_call
	JP	C,FAILED
	OR	A
	JP	NZ,FAILED
	LD	A,(INFO_OUT)
	CP	'1'
	JP	NZ,FAILED
	LD	A,(INFO_OUT + 12)
	OR	A
	JP	NZ,FAILED

	; WIN0 ownership is the caller's responsibility. The ABI must accept a
	; caller-owned page mapped there instead of treating every WIN0 pointer as
	; DSS/system memory.
	LD	A,5
	LD	(TEST_STAGE),A
	LD	A,UNET_IF_BACKEND
	LD	DE,INFO_WIN0
	LD	IX,16
	LD	HL,0
	LD	B,UNET_FN_GETINFO
	CALL	LIBMAN.l_call
	JP	C,FAILED
	OR	A
	JP	NZ,FAILED
	LD	HL,INFO_WIN0
	LD	DE,EXPECTED_BACKEND
.check_win0
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAILED
	INC	DE
	INC	HL
	OR	A
	JR	NZ,.check_win0

	; Allowing WIN0 must not open either window occupied by the DLL itself or
	; WIN3, which is reserved for the ISA aperture while UNETESP is executing.
	LD	A,6
	LD	(TEST_STAGE),A
	LD	DE,0x6000		; DLL is relocated into WIN1 in this vector
	CALL	EXPECT_BAD_INFO_PTR
	JP	NZ,FAILED

	LD	A,7
	LD	(TEST_STAGE),A
	LD	DE,0xC100		; WIN3 / ISA aperture
	CALL	EXPECT_BAD_INFO_PTR
	JP	NZ,FAILED
	JR	TEST_DONE

; In: DE=destination expected to be rejected by GETINFO.
; Out: Z when the DLL returned the required NERR_PARAM status.
EXPECT_BAD_INFO_PTR
	LD	A,UNET_IF_BACKEND
	LD	IX,16
	LD	HL,0
	LD	B,UNET_FN_GETINFO
	CALL	LIBMAN.l_call
	CP	NERR_PARAM
	RET

FAILED
	LD	A,(TEST_STAGE)
	LD	(TEST_RESULT),A
	JR	TEST_DONE

FAILED_INIT_CF
	LD	A,0x22
	LD	(TEST_RESULT),A
	JR	TEST_DONE

FAILED_INIT_A
	LD	A,0x23
	LD	(TEST_RESULT),A

TEST_DONE
	HALT

EXPECTED_CAPS	EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING | UNET_CAP_RXFLOW | UNET_CAP_MULTICHAN | UNET_CAP_ASYNCSEND
EXPECTED_BACKEND DB "ESP",0
ENV_VALUE	DB "192.168.1.2",0

	; Keep the flat test copy of libman above the largest legal WIN1 DLL image.
	; UNETESP now reaches past 0x7800; placing libman there made the LDIR below
	; overwrite its own l_call jump before the real INIT vector could run.
	ASSERT $ < 0x8000
	DS	0x8000 - $,0

	INCLUDE "unet.inc"
	INCLUDE "libman13.asm"

	ASSERT $ < 0xC000
	DS	0xC000 - $,0

DLL_IMAGE
	INCBIN "../build/UNETESP.DLL"

	END TEST_START
