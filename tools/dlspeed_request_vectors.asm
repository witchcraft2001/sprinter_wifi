; Regression vectors for the exact HTTP request builder linked into DLSPEED.
; The test build includes the application so pointer/register regressions in
; BUILD_HTTP_REQUEST cannot be hidden by a separately copied implementation.

	DEFINE	DLSPEED_REQUEST_TEST
	INCLUDE "../src/apps/dlspeed.asm"

TEST_RESULT	EQU 0xC000

	MODULE DLSPEED_REQUEST_VECTORS

TEST_START
	LD	SP,MAIN.STACK_TOP
	XOR	A
	LD	(TEST_RESULT),A

	; A custom port must be appended to Host without corrupting PORT_BUFF or
	; looping in the overlapping ASCIIZ copy that caused the hardware hang.
	LD	A,1
	LD	(TEST_RESULT),A
	LD	HL,V_HOST
	LD	DE,MAIN.HOST_BUFF
	CALL	MAIN.COPY_ASCIIZ
	LD	HL,V_PORT_8080
	LD	DE,MAIN.PORT_BUFF
	CALL	MAIN.COPY_ASCIIZ
	LD	HL,V_PATH
	LD	DE,MAIN.PATH_BUFF
	CALL	MAIN.COPY_ASCIIZ
	CALL	MAIN.BUILD_HTTP_REQUEST
	LD	HL,MAIN.REQ_BUFF
	LD	DE,V_EXPECT_8080
	CALL	STRCMP
	JP	C,FAILED
	LD	HL,MAIN.PORT_BUFF
	LD	DE,V_PORT_8080
	CALL	STRCMP
	JP	C,FAILED

	; Port 80 is implicit in HTTP and must not appear in the Host header.
	LD	A,2
	LD	(TEST_RESULT),A
	LD	HL,V_PORT_80
	LD	DE,MAIN.PORT_BUFF
	CALL	MAIN.COPY_ASCIIZ
	CALL	MAIN.BUILD_HTTP_REQUEST
	LD	HL,MAIN.REQ_BUFF
	LD	DE,V_EXPECT_80
	CALL	STRCMP
	JP	C,FAILED

	; A retry must request exactly the first missing byte as an open-ended Range.
	LD	A,3
	LD	(TEST_RESULT),A
	LD	A,1
	LD	(MAIN.RANGE_ACTIVE),A
	LD	HL,0x7A60		; 1473120 = 0x00167A60
	LD	(MAIN.TOTAL_RECEIVED),HL
	LD	HL,0x0016
	LD	(MAIN.TOTAL_RECEIVED+2),HL
	CALL	MAIN.BUILD_HTTP_REQUEST
	LD	HL,MAIN.REQ_BUFF
	LD	DE,V_EXPECT_RANGE
	CALL	STRCMP
	JP	C,FAILED

	XOR	A
	LD	(TEST_RESULT),A
FAILED
TEST_DONE
	NOP

; In: HL, DE point to ASCIIZ strings. Out: CF=1 when different.
STRCMP
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.DIFFERENT
	OR	A
	RET	Z
	INC	HL
	INC	DE
	JR	STRCMP
.DIFFERENT
	SCF
	RET

V_HOST		DB "192.168.1.36",0
V_PORT_8080	DB "8080",0
V_PORT_80	DB "80",0
V_PATH		DB "/test.bin",0

V_EXPECT_8080
	DB "GET /test.bin HTTP/1.1",13,10
	DB "Host: 192.168.1.36:8080",13,10
	DB "Accept-Encoding: identity",13,10
	DB "Connection: keep-alive",13,10,13,10,0

V_EXPECT_80
	DB "GET /test.bin HTTP/1.1",13,10
	DB "Host: 192.168.1.36",13,10
	DB "Accept-Encoding: identity",13,10
	DB "Connection: keep-alive",13,10,13,10,0

V_EXPECT_RANGE
	DB "GET /test.bin HTTP/1.1",13,10
	DB "Host: 192.168.1.36",13,10
	DB "Range: bytes=1473120-",13,10
	DB "Accept-Encoding: identity",13,10
	DB "Connection: keep-alive",13,10,13,10,0

	ENDMODULE

	END DLSPEED_REQUEST_VECTORS.TEST_START
