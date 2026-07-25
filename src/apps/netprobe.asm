; ======================================================
; NETPROBE for Sprinter-WiFi / SprinterESP
; Minimal DSS diagnostic utility.
; ======================================================

; Version of EXE file, 1 for DSS 1.70+
EXE_VERSION		EQU 1

; Timeout to wait ESP response
DEFAULT_TIMEOUT		EQU 2000

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START
	DW START
	DW STACK_TOP
	DS 106, 0

	ORG 0x8100
@STACK_TOP

START
	CALL	ISA.ISA_RESET
	CALL	WCOMMON.INIT_VMODE

	PRINTLN MSG_START

	CALL	WIFI.UART_FIND
	JP	C, NO_WIFI

	LD	A,(ISA.ISA_SLOT)
	ADD	A,'1'
	LD	(MSG_SLOT_NO),A
	PRINTLN MSG_WIFI_FOUND

	CALL	WCOMMON.APPLY_NET_BAUD		; baud from env NET_BAUD (NETUP session); utilities never read NET.CFG
	CALL	WIFI.UART_INIT
	PRINTLN MSG_UART_READY

	LD	HL,CMD_AT
	CALL	SEND_PROBE_CMD_RECOVER

	LD	HL,CMD_ECHO_OFF
	CALL	SEND_PROBE_CMD_RECOVER

	; Verify command transport without changing the ESP-side UART contract.
	CALL	WCOMMON.SETUP_UART_FLOW
	AND	A
	JR	Z,.UART_FLOW_OK
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT
.UART_FLOW_OK

	LD	HL,CMD_GMR
	CALL	SEND_PROBE_CMD_RECOVER
	PRINTLN MSG_GMR_RESPONSE
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE

	PRINTLN MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL to ESP and exit on communication error.
; ------------------------------------------------------
SEND_PROBE_CMD
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z

	PUSH	AF
	CALL	PRINT_ESP_FAILURE
	POP	AF
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Synchronize without resetting ESP, then send the requested diagnostic
; command. NETUP's association is session-only, so NETPROBE must not destroy it.
; ------------------------------------------------------
SEND_PROBE_CMD_RECOVER
	PUSH	HL
	CALL	WCOMMON.SYNC_ESP_COMMAND
	POP	HL
	JP	SEND_PROBE_CMD

; ------------------------------------------------------
; Print ESP response buffer. WIFI.UART_TX_CMD strips CR and keeps LF as a line
; separator, but DSS text output needs CR+LF for a new console line.
; In: HL - zero-ended response buffer.
; ------------------------------------------------------
PRINT_ESP_RESPONSE
	LD	A,(HL)
	AND	A
	JR	Z,.DONE
	CP	10
	JR	NZ,.PUT_CHAR
	LD	A,13
	CALL	PUT_CHAR
	LD	A,10
.PUT_CHAR
	CALL	PUT_CHAR
	INC	HL
	JR	PRINT_ESP_RESPONSE
.DONE
	LD	A,13
	CALL	PUT_CHAR
	LD	A,10

PUT_CHAR
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	RET

PRINT_ESP_FAILURE
	PRINTLN MSG_ESP_RESPONSE
	LD	HL,WIFI.RS_BUFF
	JP	PRINT_ESP_RESPONSE

MSG_START
	DB "NETPROBE "
	PACKAGE_VERSION_TAG
	DB " for SprinterESP / Sprinter-WiFi"
	DB 0

MSG_WIFI_FOUND
	DB "Sprinter-WiFi found in ISA#"
MSG_SLOT_NO
	DB "n slot.",0

MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found!",0

MSG_UART_READY
	DB "UART initialized.",0

MSG_FIRST_RESPONSE
	DB "Initial ESP response before recovery:",0

MSG_ESP_RESPONSE
	DB "ESP response:",0

MSG_GMR_RESPONSE
	DB "ESP firmware response:",0

MSG_DONE
	DB "NETPROBE done.",0

MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_GMR
	DB "AT+GMR",13,10,0

	ENDMODULE

	DEFINE WCOMMON_USE_NETCFG
	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

	END MAIN.START
