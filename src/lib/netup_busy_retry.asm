; ======================================================
; NETUP ESP busy-response retry helpers.
;
; Included by NETUP and by tools/netup_busy_vectors.asm so the host-side
; harness executes the same Z80 retry loop as the application.
;
; Required definitions:
;   NETUP_BUSY_RETRIES, NETUP_BUSY_DELAY
;   RES_BUSY, WIFI.RS_BUFF, WIFI.UART_TX_CMD, UTIL.DELAY
; ======================================================

	IFNDEF	_NETUP_BUSY_RETRY
	DEFINE	_NETUP_BUSY_RETRY

; Retry a command rejected while the preceding command is still completing.
SEND_CMD_BUSY_TIMEOUT
	LD	A,NETUP_BUSY_RETRIES
	JR	SEND_CMD_BUSY_RETRY_COUNT

; In:  A = number of retries after the first attempt
;      HL = command, BC = response timeout
; Out: A = RES_* from WIFI.UART_TX_CMD
SEND_CMD_BUSY_RETRY_COUNT
	LD	(BUSY_RETRY_LEFT),A
.TRY
	LD	DE,WIFI.RS_BUFF
	CALL	WIFI.UART_TX_CMD
	CP	RES_BUSY
	RET	NZ
	LD	A,(BUSY_RETRY_LEFT)
	AND	A
	JR	Z,.SPENT
	DEC	A
	LD	(BUSY_RETRY_LEFT),A
	PUSH	BC,HL
	LD	HL,NETUP_BUSY_DELAY
	CALL	UTIL.DELAY
	POP	HL,BC
	JR	.TRY
.SPENT
	LD	A,RES_BUSY
	RET

BUSY_RETRY_LEFT
	DB 0

	ENDIF
