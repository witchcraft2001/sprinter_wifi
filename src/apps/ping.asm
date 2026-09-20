; ======================================================
; PING for Sprinter ESP Network Kit
; Host reachability diagnostic using ESP-AT AT+PING, formatted like the
; sibling RTL8019A/3C509B ping utilities. ESP-AT's AT+PING returns only an
; RTT in milliseconds - it has no packet-size, TTL, or per-reply timeout
; knobs - so -l/-i/-w (present on the sibling kits) are not offered here.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
PING_TIMEOUT		EQU 8000
PING_BUSY_RETRIES	EQU 8			; AT+PING retries while the ESP answers "busy"
PING_BUSY_DELAY		EQU 400			; ms between busy retries
PING_FORMAT_RETRIES	EQU 3			; retry a terminal OK with a damaged/missing +PING line
PING_FORMAT_DELAY	EQU 150
HOST_SIZE		EQU 96
CMD_SIZE		EQU 128

	DEVICE NOSLOT64K

	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "exit_codes.inc"

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
	; DSS passes the command-line buffer pointer in IX at entry; capture it
	; before any CALL clobbers IX (load-#80 = 0x8080 is the default, not assumed).
	LD	(CMDLINE_PTR),IX
	CALL	ISA.ISA_RESET
	CALL	WCOMMON.INIT_VMODE
	PRINTLN MSG_START

	CALL	PARSE_PING_ARGS
	JP	C,USAGE
	LD	A,(OPT_HELP)
	AND	A
	JP	NZ,SHOW_HELP

	CALL	WIFI.UART_FIND
	JP	C,NO_WIFI
	CALL	WCOMMON.REQUIRE_NET_UP

	CALL	WCOMMON.APPLY_NET_BAUD		; baud from env NET_BAUD (NETUP session); utilities never read NET.CFG
	CALL	WIFI.UART_INIT
	PRINTLN MSG_UART_READY

	; NETUP uses session-only Wi-Fi settings. A diagnostic must not reset ESP:
	; that would invalidate NET_* and turn a transient UART probe into a lost
	; association. Retry only the harmless AT probe.
	CALL	WCOMMON.SYNC_ESP_COMMAND
	AND	A
	JP	NZ,COMMAND_ERROR_EXIT

	LD	HL,CMD_ECHO_OFF
	CALL	SEND_CMD

	; Confirm the local UART mode selected from NET_ESP_FLOW; this does not
	; reconfigure the ESP or toggle AFE.
	CALL	WCOMMON.SETUP_UART_FLOW
	AND	A
	JR	Z,.UART_FLOW_OK
	JP	COMMAND_ERROR_EXIT
.UART_FLOW_OK

	CALL	STAT_RESET
	CALL	RESOLVE_TARGET

	LD	HL,(OPT_COUNT)
	LD	(PING_LEFT),HL
	XOR	A
	LD	(PING_STOP),A

.LOOP
	; Anchor the pacing before the request, not after the reply: AT+PING plus
	; the ESP's own ping take most of a second, and that time belongs inside
	; the one-second interval, not on top of it.
	CALL	PAUSE_ANCHOR_NOW
	CALL	BUILD_PING_CMD
	CALL	SEND_PING_ONE

	LD	A,(WCOMMON.CANCELLED)
	AND	A
	JP	NZ,.CANCELLED

	CALL	STAT_SENT

	LD	A,(PING_STATUS)
	AND	A
	JR	NZ,.NOT_OK
	CALL	FIND_PING_RTT
	JR	C,.TIMEOUT_LINE
	; PRINT below issues RST DSS, which clobbers C (and thus BC) - stash the
	; RTT value before printing anything else.
	LD	(PING_RTT),BC
	CALL	STAT_RECEIVED
	PRINT	MSG_REPLY_FROM
	LD	HL,(PING_TARGET)
	PRINT_HL
	PRINT	MSG_COLON_SPACE
	LD	BC,(PING_RTT)
	CALL	PRINT_RTT_MS
	JR	.ADVANCE
.NOT_OK
	LD	A,(PING_STATUS)
	CALL	RESP_IS_PING_TIMEOUT
	JR	C,.TIMEOUT_LINE
	; A genuine ESP/comm error (not a ping timeout) stops further requests;
	; the statistics collected so far are still printed.
	CALL	PRINT_HARD_ERROR
	LD	A,1
	LD	(PING_STOP),A
	JR	.ADVANCE
.TIMEOUT_LINE
	PRINTLN	MSG_TIMED_OUT
.ADVANCE
	LD	A,(PING_STOP)
	AND	A
	JR	NZ,.FINISH
	LD	A,(OPT_INFINITE)
	AND	A
	JR	NZ,.PAUSE
	LD	HL,(PING_LEFT)
	DEC	HL
	LD	(PING_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.FINISH
.PAUSE
	CALL	PING_PAUSE
	JR	C,.FINISH
	JP	.LOOP
.CANCELLED
	; The in-flight request is counted as sent and lost, same as the sibling
	; ping utilities.
	CALL	STAT_SENT
.FINISH
	LD	A,(WCOMMON.CANCELLED)
	AND	A
	JR	Z,.NO_CANCEL_MSG
	PRINT	WCOMMON.LINE_END
	PRINTLN	MSG_CANCELLED_LINE
.NO_CANCEL_MSG
	PRINT	WCOMMON.LINE_END
	PRINT	MSG_STATS_FOR
	LD	HL,(PING_TARGET)
	PRINT_HL
	PRINTLN	MSG_COLON
	CALL	PRINT_PACKETS_LINE

	LD	A,(WCOMMON.CANCELLED)
	AND	A
	JR	NZ,.EXIT_CANCELLED
	LD	HL,(PING_RECEIVED)
	LD	A,H
	OR	L
	JR	Z,.EXIT_FAIL
	; Every utility in this package closes with "<NAME> done." on success and
	; with a reason line plus "<NAME> failed." on failure (WCOMMON.EXIT prints
	; the latter); the sibling kits' "RESULT OK/FAIL" would be the odd one out.
	PRINTLN	MSG_DONE
	LD	B,EXIT_OK
	JP	WCOMMON.EXIT
.EXIT_FAIL
	PRINTLN	MSG_NO_REPLY
	LD	B,EXIT_NETWORK
	JP	WCOMMON.EXIT
.EXIT_CANCELLED
	; "Cancelled by user." is already on screen above the statistics.
	LD	B,EXIT_CANCELLED
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,EXIT_HARDWARE
	JP	WCOMMON.EXIT

USAGE
	PRINTLN MSG_USAGE
	LD	B,EXIT_ARGUMENT
	JP	WCOMMON.EXIT

SHOW_HELP
	PRINTLN MSG_USAGE
	LD	B,EXIT_OK
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Resolve HOST_BUFF via AT+CIPDOMAIN when it is not already a dotted-decimal
; IPv4 literal, and print the "Pinging ..." / "Our IP=" header. Sets
; PING_TARGET to whichever ASCIIZ buffer AT+PING should actually address
; (IP_BUFF on a successful resolve, HOST_BUFF otherwise). jesperl does not
; implement AT+CIPDOMAIN, so a failed/unsupported resolve falls back to
; pinging the host text directly, same as real ESP-AT would refuse to open a
; hostname it cannot resolve.
; ------------------------------------------------------
RESOLVE_TARGET
	LD	HL,HOST_BUFF
	LD	(PING_TARGET),HL
	LD	HL,HOST_BUFF
	CALL	IS_IPV4_LITERAL
	JR	NC,.HEADER_PLAIN
	LD	HL,CMD_BUFF
	LD	DE,CMD_CIPDOMAIN_PREFIX
	CALL	APPEND_STR
	LD	IX,HOST_BUFF
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	CALL	APPEND_STR
	LD	HL,CMD_BUFF
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	JR	NZ,.HEADER_PLAIN
	LD	HL,WIFI.RS_BUFF
	LD	DE,IP_BUFF
	LD	C,15
	CALL	FIND_CIPDOMAIN_IP
	JR	C,.HEADER_PLAIN
	LD	HL,IP_BUFF
	LD	(PING_TARGET),HL
	PRINT	MSG_PINGING
	PRINT	HOST_BUFF
	PRINT	MSG_OPEN_BRACKET
	PRINT	IP_BUFF
	PRINTLN	MSG_CLOSE_COLON
	JR	.OUR_IP
.HEADER_PLAIN
	PRINT	MSG_PINGING
	PRINT	HOST_BUFF
	PRINTLN	MSG_COLON
.OUR_IP
	CALL	PRINT_OUR_IP
	RET

; Print "Our IP=<addr>" from env NET_IP (published by NETUP); omitted if the
; variable is missing or empty.
PRINT_OUR_IP
	LD	HL,ENV_NET_IP_KEY
	LD	DE,WCOMMON.ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	RET	Z
	LD	A,(WCOMMON.ENV_VAL_BUF)
	AND	A
	RET	Z
	PRINT	MSG_OUR_IP
	PRINT	WCOMMON.ENV_VAL_BUF
	PRINT	WCOMMON.LINE_END
	RET

; ------------------------------------------------------
; Send one AT+PING for PING_TARGET, preserving the busy-retry (ESP IP stack
; still coming up right after NETUP) and malformed-response retry (2.2.2
; sometimes loses the first bytes of a delayed response, "+PING:228" ->
; "G:228"). The former warm-up-timeout retry is intentionally gone: with a
; multi-ping series, an early timeout is now legitimate, visible ping output
; instead of something to hide.
; Out: A = PING_STATUS = RES_* result (0 on a clean OK).
; ------------------------------------------------------
SEND_PING_ONE
	LD	A,PING_BUSY_RETRIES
	LD	(PING_RETRY),A
	LD	A,PING_FORMAT_RETRIES
	LD	(PING_FRETRY),A
.TRY
	LD	HL,CMD_BUFF
	LD	DE,WIFI.RS_BUFF
	LD	BC,PING_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	LD	(PING_STATUS),A
	CP	RES_BUSY
	JR	NZ,.NOT_BUSY
	LD	A,(PING_RETRY)
	OR	A
	JR	Z,.RETURN_STATUS
	DEC	A
	LD	(PING_RETRY),A
	LD	HL,PING_BUSY_DELAY
	CALL	UTIL.DELAY
	JP	.TRY
.NOT_BUSY
	LD	A,(PING_STATUS)
	AND	A
	JR	NZ,.RETURN_STATUS
	CALL	FIND_PING_RESULT
	JR	NC,.OK_VALID
	LD	A,(PING_FRETRY)
	AND	A
	JR	Z,.OK_VALID			; retries spent -> accept the terminal OK as-is
	DEC	A
	LD	(PING_FRETRY),A
	LD	HL,PING_FORMAT_DELAY
	CALL	UTIL.DELAY
	JP	.TRY
.OK_VALID
	XOR	A
	LD	(PING_STATUS),A
	RET
.RETURN_STATUS
	LD	A,(PING_STATUS)
	RET

PRINT_HARD_ERROR
	LD	A,(PING_STATUS)
	CP	RES_TX_TIMEOUT
	JR	Z,.TXTIMEOUT
	PRINTLN MSG_PING_UNSUPPORTED
	RET
.TXTIMEOUT
	PRINTLN MSG_TX_TIMEOUT
	RET

; ------------------------------------------------------
; Pause OPT_PAUSE ms between requests; OPT_PAUSE=0 pauses for 0 ms. Whole
; seconds are paced on the DSS wall clock and any remainder on the measured
; delay loop (see ping_lib.asm). ISA is already closed here - UART_TX_CMD
; closes it on the way out - so both the RST DSS clock read and
; WCOMMON.CHECK_CANCEL are safe to call directly.
; Out: CF=1 - cancelled (WCOMMON.CANCELLED set); CF=0 - pause elapsed.
; ------------------------------------------------------
PING_PAUSE
	LD	HL,(OPT_PAUSE)
	JP	PAUSE_MS

; ------------------------------------------------------
; Send command in HL with default timeout.
; ------------------------------------------------------
SEND_CMD
	CALL	SEND_CMD_STATUS
	AND	A
	RET	Z
	JP	COMMAND_ERROR_EXIT

; Send command in HL with default timeout.
; Out: A = RES_* result, zero on ESP OK.
SEND_CMD_STATUS
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	JP	WIFI.UART_TX_CMD

; Print the actual ESP response before terminating a command-mode failure.
; In: A = RES_* result, WIFI.RS_BUFF = complete or partial ESP response.
COMMAND_ERROR_EXIT
	PUSH	AF
	CALL	PRINT_ESP_FAILURE
	POP	AF
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,EXIT_NETWORK
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Build AT+PING command from PING_TARGET (HOST_BUFF, or IP_BUFF once
; RESOLVE_TARGET has resolved a hostname).
; ------------------------------------------------------
BUILD_PING_CMD
	LD	HL,CMD_BUFF
	LD	DE,CMD_PING_PREFIX
	CALL	APPEND_STR
	LD	IX,(PING_TARGET)
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ------------------------------------------------------
; Print ESP response buffer with LF -> CRLF conversion.
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
	JP	PUT_CHAR

PRINT_ESP_FAILURE
	PRINTLN MSG_ESP_RESPONSE
	LD	HL,WIFI.RS_BUFF
	JP	PRINT_ESP_RESPONSE

PUT_CHAR
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	RET

; Keep the dynamically assembled AT+PING/AT+CIPDOMAIN command terminated even
; though CMD_BUFF is runtime BSS and can contain bytes left by a previous
; program. Without the copied zero UART_TX_STRING continued past CR/LF and
; fed ESP a second garbage line, commonly producing ERR CODE:0x010b0000 /
; "busy p...".
	INCLUDE "asciiz_append.asm"
	INCLUDE "ping_lib.asm"

MSG_START
	DB "PING "
	PACKAGE_VERSION_TAG
	DB " - SprinterESP host diagnostic"
	DB 0
MSG_USAGE
	DB "Usage:",13,10
	DB "  PING.EXE [-t] [-n count] [-p ms] host",13,10
	DB "  PING.EXE /?",13,10,13,10
	DB "  -t        ping until interrupted (Esc/Ctrl+Z).",13,10
	DB "  -n count  number of echo requests (default 4, max 65535).",13,10
	DB "  -p ms     pause between requests (default 1000, 0 = no pause).",13,10
	DB "  host      destination IPv4 address or host name.",0
MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found!",0
MSG_UART_READY
	DB "UART initialized.",0
MSG_ESP_RESPONSE
	DB "ESP response:",0
MSG_PINGING
	DB "Pinging ",0
MSG_OPEN_BRACKET
	DB " [",0
MSG_CLOSE_COLON
	DB "]:",0
MSG_COLON
	DB ":",0
MSG_COLON_SPACE
	DB ": ",0
MSG_OUR_IP
	DB "Our IP=",0
MSG_REPLY_FROM
	DB "Reply from ",0
MSG_TIMED_OUT
	DB "Request timed out.",0
MSG_PING_UNSUPPORTED
	DB "ESP-AT PING failed or is not supported by firmware/emulator.",0
MSG_TX_TIMEOUT
	DB "Could not send AT+PING command (UART busy).",0
MSG_CANCELLED_LINE
	DB "Cancelled by user.",0
MSG_STATS_FOR
	DB "Ping statistics for ",0
MSG_DONE
	DB "PING done.",0
MSG_FAILED
	DB "PING failed.",0
MSG_NO_REPLY
	DB "No replies received.",0
MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0

CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_PING_PREFIX
	DB "AT+PING=",34,0
CMD_CIPDOMAIN_PREFIX
	DB "AT+CIPDOMAIN=",34,0
CMD_QUOTE_CRLF
	DB 34,13,10,0
ENV_NET_IP_KEY
	DB "NET_IP",0

PING_STATUS
	DB 0
PING_RETRY
	DB 0
PING_FRETRY
	DB 0
PING_STOP
	DB 0
PING_LEFT
	DW 0
PING_TARGET
	DW 0
PING_RTT
	DW 0
CMDLINE_PTR
	DW 0			; arg buffer ptr captured from IX at entry

	ENDMODULE

	DEFINE WCOMMON_USE_NETCFG
	DEFINE WCOMMON_FAIL_LINE
	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

	MODULE MAIN

HOST_BUFF	EQU NETCFG.NETCFG_BSS_END
CMD_BUFF	EQU HOST_BUFF + HOST_SIZE
IP_BUFF		EQU CMD_BUFF + CMD_SIZE
PING_BSS_END	EQU IP_BUFF + 16

	ENDMODULE

	END MAIN.START
