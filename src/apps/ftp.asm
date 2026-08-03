; ======================================================
; Minimal passive FTP client for Sprinter ESP Network Kit.
; Logs in, opens PASV data link and downloads files or prints listings.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 5000
FTP_RECV_TIMEOUT	EQU 10000
FTP_DATA_TIMEOUT	EQU 20000
FTP_FINAL_TIMEOUT	EQU 800				; short wait for post-transfer 226 / QUIT 221 replies (the busy-poll receive inflates this, so keep it small)
FTP_BURST_TIMEOUT	EQU 120
FTP_ACTIVE_IPD_MAX	EQU 3000
; WIN2 also holds the command-line/control strings. Keep a 1 KiB tail for that
; runtime-only scratch, leaving a 15 KiB data area for streaming and the 8 KiB
; retained FIN tail. This preserves the mandatory WIN1 stack margin.
RECV_SIZE		EQU 15360
; Bytes handed to one AT+CIPSEND. The ESP does its own TCP segmentation, so this
; is NOT the TCP MSS - it only sets how many bytes ship per CIPSEND handshake
; (prompt + payload + SEND OK). Small chunks throttle upload throughput because
; each one pays the full round-trip. 2048 is the documented per-send maximum for
; ESP8266 ESP-AT; the 16550 CTS auto-flow (MCR_AFE) backpressures the UART so a
; large chunk cannot overrun the ESP. (Was 536, inherited from the rtl8019a TCP
; stack where it WAS the MSS - meaningless here, ~4x more handshakes.)
FTP_PUT_CHUNK		EQU 2048
FTP_PUT_READ_SIZE	EQU RECV_SIZE		; one disk read fills the available WIN2 data area
CONTROL_LINK		EQU 0
DATA_LINK		EQU 1
HOST_SIZE		EQU 96
PORT_SIZE		EQU 8
USER_SIZE		EQU 48
PASS_SIZE		EQU 64
PATH_SIZE		EQU 128
ARG_SIZE		EQU 128
CMD_SIZE		EQU 128
; Retain-tail margin for file downloads: once the server-announced size is
; within this many bytes of completion we stop pausing for DSS_WRITE and
; accumulate the final bytes in RECV_BUFFER, flushing only after the data link
; closes. This keeps RTS asserted across the close so ESP-AT never discards
; queued-but-unsent +IPD data on the data-connection FIN. Must be < RECV_SIZE.
FTP_HOLD_TAIL_MARGIN	EQU 8192
; FTP control replies used here (220/227/150/226/...) are short. Keeping this
; at 78 preserves the mandatory WIN1 stack margin while the common library
; stores the NET_ESP_FW-selected receive profile.
LINE_SIZE		EQU 78
NO_HANDLE		EQU 0xFF
DATA_CLOSED_LEN		EQU 8
FTP_RESUME_LIMIT	EQU 12			; max automatic REST re-fetch attempts per download
; Quiet ESP recovery (ESP_SOFT_RECOVER) tuning.
FTP_DRAIN_IDLE_MS	EQU 60			; UART idle gap that ends a drain
FTP_DRAIN_MAX_BYTES	EQU 8192		; safety cap on bytes discarded per drain
FTP_SOFT_AT_RETRIES	EQU 12			; AT probes before giving up to a hard reset
FTP_SOFT_AT_TIMEOUT	EQU 1200		; ms to wait for each AT reply
FTP_SOFT_AT_DELAY	EQU 300			; ms between AT probes
DSS_CREATE_OVERWRITE	EQU 0x0A
OUT_SIZE		EQU 80

		DEVICE NOSLOT64K

		INCLUDE "macro.inc"
		INCLUDE "dss.inc"

		MODULE MAIN

		; Load at 0x4100 so code and small BSS live below the #8000 stack.
		; The cmdline buffer pointer is taken from IX at entry (see START);
		; load_addr-0x80 = 0x4080 is the documented default but not assumed.
LOAD_ADDR	EQU 0x4100
STACK_TOP	EQU 0x8000
WIN2_BASE	EQU 0x8000
OVERLAY_RUN	EQU 0x8000	; cold overlay page runs here when mapped into WIN2

		; Full 512-byte DSS EXE header.
		ORG LOAD_ADDR - 0x0200
EXE_HEADER
		DB "EXE"
		DB EXE_VERSION
		DW 0x0200
		DW 0
		DW 0
		DW 0
		DW 0
		DW 0
		DW START
		DW START
		DW STACK_TOP
		DS 490, 0

		ORG LOAD_ADDR

START
		; DSS passes the command-line buffer pointer in IX at entry
		; ([IX+0]=length, [IX+1..]=text). Capture it first, before any CALL
		; clobbers IX, instead of assuming the load-#80 address. CMDLINE_PTR is
		; a code-segment var, so CLEAR_BSS (WIN2) does not wipe it.
		LD	(CMDLINE_PTR),IX
		CALL	INIT_RUNTIME_PAGE
		JP	C,INIT_MEMORY_ERROR
		CALL	CLEAR_BSS
		LD	A,NO_HANDLE
		LD	(OUT_FH),A
		CALL	ISA.ISA_RESET
		CALL	WCOMMON.INIT_VMODE
		PRINTLN MSG_START

		CALL	PARSE_CMD_LINE
		JP	C,USAGE
		LD	A,(HELP_REQUESTED)
		AND	A
		JP	NZ,SHOW_HELP

		CALL	WIFI.UART_FIND
		JP	C,NO_WIFI
		CALL	WCOMMON.REQUIRE_NET_UP
		LD	A,(ISA.ISA_SLOT)
		ADD	A,'1'
		LD	(MSG_SLOT_NO),A
		PRINTLN	MSG_WIFI_FOUND

		CALL	WCOMMON.APPLY_NET_BAUD		; baud from env NET_BAUD (NETUP session); utilities never read NET.CFG
		CALL	WIFI.UART_INIT
		PRINTLN MSG_UART_READY

		CALL	ESP_PRELUDE
		CALL	LOGIN_SEQUENCE

		LD	A,(LIST_FLAG)
		AND	A
		JP	NZ,.LIST_PATH
		LD	A,(PUT_MODE)
		AND	A
		JP	NZ,.PUT_PATH

; ===== File download with automatic REST resume =====
		CALL	OPEN_OUTPUT_FILE		; prompt R/O/C; sets DATA_TOTAL & RESUME_MODE
		JP	C,FILE_ERROR_EXIT
		XOR	A
		LD	(DATA_EXPECTED_SEEN),A
		; Ask SIZE once before the first RETR. A 213 result gives the complete
		; remote length independently of the server-specific 150 text and stays
		; unchanged across subsequent REST attempts. Servers that do not support
		; SIZE still use the legacy 150 "(size)" parser as a fallback.
		CALL	QUERY_REMOTE_SIZE
		JP	C,NET_ERROR_EXIT
		; Speed base = bytes already on disk (resume offset, or 0 for fresh),
		; so the rate reflects only what is fetched this run.
		LD	HL,(DATA_TOTAL)
		LD	(SESSION_BASE),HL
		LD	HL,(DATA_TOTAL+2)
		LD	(SESSION_BASE+2),HL
		XOR	A
		LD	(RESUME_ATTEMPTS),A
		CALL	TPUT.START
		PRINT	MSG_DOWNLOADING
		PRINT	OUT_FILE
		PRINT	WCOMMON.LINE_END
.DL_ATTEMPT
		CALL	DO_PASV_OPEN			; PASV + parse + OPEN_LINK (exits on error)
		; REST when we already hold bytes: a prompt-resume offset, or a prior
		; short attempt's partial. The server (confirmed) reports the FULL size
		; in its 150 reply, so DATA_EXPECTED stays the whole file.
		CALL	DATA_TOTAL_NONZERO
		JR	NC,.DL_RETR
		CALL	BUILD_REST_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		LD	A,(REPLY_FIRST)
		CP	'3'				; 350 Restart marker accepted
		JP	NZ,REST_REJECTED
.DL_RETR
		PRINTLN	MSG_RETR
		CALL	BUILD_RETR_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_LIST_PRELIM_REPLY
		JP	C,FTP_ERROR_EXIT
		CALL	PARSE_EXPECTED_SIZE
		CALL	RECV_DATA_TRANSFER
		JP	C,NET_ERROR_EXIT
		CALL	DOWNLOAD_COMPLETE		; Z if DATA_TOTAL >= DATA_EXPECTED
		JR	Z,.DL_DONE
		; Short transfer (ESP dropped the tail on the data-link close). Retry
		; from where we stopped via REST, up to the attempt limit.
		LD	A,(RESUME_ATTEMPTS)
		CP	FTP_RESUME_LIMIT
		JR	NC,.DL_DONE			; give up -> VERIFY reports the mismatch
		INC	A
		LD	(RESUME_ATTEMPTS),A
		; After the peer closed the data link mid-transfer, the ESP control
		; channel can be left desynced so the next PASV reply never arrives
		; (observed as a #4 timeout). Reusing the control connection is not
		; reliable on this firmware; tear down both TCP links and re-login,
		; exactly like a manual resume run, which is the only path proven to
		; recover. The output file stays open so we keep appending.
		PRINTLN	MSG_AUTO_RESUME
		LD	A,(DATA_OPEN)
		AND	A
		JR	Z,.AR_CTRL
		LD	A,DATA_LINK
		CALL	TCP.CLOSE_LINK
.AR_CTRL
		LD	A,(CONTROL_OPEN)
		AND	A
		JR	Z,.AR_RECON
		LD	A,CONTROL_LINK
		CALL	TCP.CLOSE_LINK
.AR_RECON
		XOR	A
		LD	(DATA_OPEN),A
		LD	(CONTROL_OPEN),A
		LD	(DATA_BYTES_SEEN),A
		; First try a QUIET recovery: drain the backlog the truncated transfer
		; left in the UART, poll AT until the ESP answers, then close the stale
		; sockets and restore CIPMUX=1 - all without AT+RST, which would drop the
		; Wi-Fi join and force a manual NETUP. The routine is cold, so it runs
		; from the WIN2 overlay and reports back in SOFT_RECOVER_OK.
		LD	HL,OVL_ESP_SOFT_RECOVER
		CALL	CALL_OVERLAY
		LD	A,(SOFT_RECOVER_OK)
		AND	A
		JR	NZ,.AR_LOGIN			; ESP responsive -> re-login (no reset)
		; Do not hardware-reset here. NETUP uses volatile session settings, so
		; reset would guarantee loss of Wi-Fi while NET_* still claims it is up.
		LD	A,RES_RS_TIMEOUT
		JP	NET_ERROR_EXIT
.AR_LOGIN
		CALL	LOGIN_SEQUENCE
		JP	.DL_ATTEMPT
.DL_DONE
		CALL	CLOSE_OUTPUT_FILE
		JP	C,FILE_ERROR_EXIT
		CALL	VERIFY_DATA_SIZE
		JP	C,NET_ERROR_EXIT
		CALL	REPORT_SESSION_SPEED
		LD	A,(FINAL_REPLY_SEEN)
		AND	A
		JR	NZ,.DL_FINAL
		CALL	RECV_CONTROL_REPLY_OPTIONAL
		JP	C,.FINISH
.DL_FINAL
		CALL	CHECK_REPLY_POSITIVE
		JP	C,FTP_ERROR_EXIT
		JP	.FINISH

; ===== File upload (single shot) =====
.PUT_PATH
		CALL	OPEN_INPUT_FILE
		JP	C,FILE_ERROR_EXIT
		XOR	A
		LD	(DATA_TOTAL),A
		LD	(DATA_TOTAL+1),A
		LD	(DATA_TOTAL+2),A
		LD	(DATA_TOTAL+3),A
		LD	(SESSION_BASE),A
		LD	(SESSION_BASE+1),A
		LD	(SESSION_BASE+2),A
		LD	(SESSION_BASE+3),A
		CALL	TPUT.START
		PRINT	MSG_UPLOADING
		PRINT	PATH_BUFF
		PRINT	WCOMMON.LINE_END
		CALL	DO_PASV_OPEN
		PRINTLN	MSG_STOR
		CALL	BUILD_STOR_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_LIST_PRELIM_REPLY
		JP	C,FTP_ERROR_EXIT
		CALL	SEND_DATA_TRANSFER
		JP	C,NET_ERROR_EXIT
		LD	A,DATA_LINK
		CALL	TCP.CLOSE_LINK
		JP	C,NET_ERROR_EXIT
		XOR	A
		LD	(DATA_OPEN),A
		CALL	CLOSE_OUTPUT_FILE
		JP	C,FILE_ERROR_EXIT
		CALL	REPORT_SESSION_SPEED
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_REPLY_POSITIVE
		JP	C,FTP_ERROR_EXIT
		JR	.FINISH

; ===== Directory listing (single shot) =====
.LIST_PATH
		CALL	DO_PASV_OPEN
		PRINTLN	MSG_LIST
		CALL	BUILD_LIST_COMMAND
		XOR	A
		LD	(DATA_TOTAL),A
		LD	(DATA_TOTAL+1),A
		LD	(DATA_TOTAL+2),A
		LD	(DATA_TOTAL+3),A
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_LIST_PRELIM_REPLY
		JP	C,FTP_ERROR_EXIT
		CALL	PARSE_EXPECTED_SIZE
		CALL	WIFI.UART_RX_PAUSE
		PRINTLN	MSG_LISTING
		CALL	WIFI.UART_RX_RESUME
		CALL	RECV_DATA_TRANSFER
		JP	C,NET_ERROR_EXIT
		LD	A,(FINAL_REPLY_SEEN)
		AND	A
		JR	NZ,.LIST_FINAL
		CALL	RECV_CONTROL_REPLY_OPTIONAL
		JR	C,.FINISH
.LIST_FINAL
		CALL	CHECK_REPLY_POSITIVE
		JP	C,FTP_ERROR_EXIT

.FINISH
		LD	DE,FTP_QUIT
		CALL	BUILD_SIMPLE_COMMAND
		CALL	SEND_CONTROL
		; QUIT reply (221) is informational; wait only briefly so a slow/absent
		; goodbye does not stall the finish for the full control timeout.
		CALL	RECV_CONTROL_REPLY_OPTIONAL

		CALL	CLEANUP_TCP
		PRINTLN MSG_DONE
		LD	B,0
		JP	WCOMMON.EXIT

USAGE
		LD	HL,OVL_SHOW_HELP	; help text lives in the WIN2 cold overlay
		CALL	CALL_OVERLAY
		LD	B,1
		JP	WCOMMON.EXIT

SHOW_HELP
		LD	HL,OVL_SHOW_HELP
		CALL	CALL_OVERLAY
		LD	B,0
		JP	WCOMMON.EXIT

NO_WIFI
		PRINTLN MSG_WIFI_NOT_FOUND
		LD	B,2
		JP	WCOMMON.EXIT

NET_ERROR_EXIT
		PUSH	AF
		CALL	CLEANUP_TCP
		POP	AF
		PUSH	AF
		ADD	A,'0'
		LD	(MSG_NET_ERROR_NO),A
		PRINTLN MSG_NET_ERROR
		POP	AF
		CALL	PRINT_NET_REASON		; plain-language hint for the RES_* code
		LD	B,3
		JP	WCOMMON.EXIT

; Print a human-readable explanation line for the RES_* network error code in A
; (esplib.asm). "#3" alone means nothing to a tester; this says what to check.
; Unknown/benign codes print nothing. Trashes A,HL,DE.
PRINT_NET_REASON
		CP	NET_REASON_COUNT
		RET	NC
		LD	L,A
		LD	H,0
		ADD	HL,HL				; code * 2 (word table)
		LD	DE,NET_REASON_TABLE
		ADD	HL,DE
		LD	E,(HL)
		INC	HL
		LD	D,(HL)
		LD	A,D
		OR	E				; null entry -> no extra line
		RET	Z
		EX	DE,HL
		PRINTLN_HL
		RET

FTP_ERROR_EXIT
		CALL	CLEANUP_TCP
		PRINT MSG_FTP_ERROR
		LD	A,(REPLY_CODE_1)
		CALL	PUT_CHAR
		LD	A,(REPLY_CODE_2)
		CALL	PUT_CHAR
		LD	A,(REPLY_CODE_3)
		CALL	PUT_CHAR
		PRINT WCOMMON.LINE_END
		LD	B,4
		JP	WCOMMON.EXIT

FILE_ERROR_EXIT
		CALL	CLEANUP_TCP
		LD	A,(OUTPUT_ABORTED)
		AND	A
		JR	NZ,FILE_ABORT_EXIT
		PRINTLN MSG_FILE_ERROR
		LD	B,5
		JP	WCOMMON.EXIT

FILE_ABORT_EXIT
		PRINTLN MSG_ABORTED
		LD	B,1
		JP	WCOMMON.EXIT

; Resume requested but the server rejected REST (no 3xx reply). Cannot continue
; a partial file on this server; the user should re-run and choose Overwrite.
REST_REJECTED
		CALL	CLOSE_OUTPUT_FILE_IGNORE
		CALL	CLEANUP_TCP
		PRINTLN MSG_NO_REST
		LD	B,4
		JP	WCOMMON.EXIT

; ------------------------------------------------------
; Parse:
;   FTP.EXE host[:port] file [-o output] [-u user] [-p pass] [-y|-f overwrite] [-r resume]
;   FTP.EXE host[:port] PUT local [-o remote] [-u user] [-p pass]
;   FTP.EXE host[:port] [path] -l [-u user] [-p pass]
;   FTP.EXE host[:port] [path] -n [-u user] [-p pass]
; ------------------------------------------------------
PARSE_CMD_LINE
		XOR	A
		LD	(HELP_REQUESTED),A
		LD	(LIST_MODE),A
		LD	(LIST_FLAG),A
		LD	(PUT_MODE),A
		LD	(USER_GIVEN),A
		LD	(PASS_GIVEN),A
		LD	(FORCE_OVERWRITE),A
		LD	(OUTPUT_ABORTED),A
		LD	(PATH_BUFF),A
		LD	(OUT_FILE),A
		LD	HL,DEFAULT_PORT
		LD	DE,PORT_BUFF
		CALL	COPY_ASCIIZ_DE
		LD	HL,DEFAULT_USER
		LD	DE,USER_BUFF
		CALL	COPY_ASCIIZ_DE
		LD	HL,DEFAULT_PASS
		LD	DE,PASS_BUFF
		CALL	COPY_ASCIIZ_DE

		LD	HL,(CMDLINE_PTR)
		LD	A,(HL)
		AND	A
		JP	Z,.ERR
		LD	B,A
		INC	HL
		CALL	SKIP_SPACES
		JP	C,.ERR
		LD	DE,HOST_BUFF
		LD	C,HOST_SIZE-1
		CALL	COPY_ARG
		JP	C,.ERR
		PUSH	HL
		PUSH	BC
		CALL	IS_HOST_HELP
		POP	BC
		POP	HL
		JP	NC,.HELP
		; SPLIT_HOST_PORT scans HOST_BUFF and clobbers HL/DE. Preserve our
		; cmdline pointer (HL) and remaining-length counter (B) across the
		; call so SKIP_SPACES below still walks the cmdline, not HOST_BUFF.
		PUSH	HL
		PUSH	BC
		CALL	SPLIT_HOST_PORT
		POP	BC
		POP	HL
		JP	C,.ERR

.NEXT_ARG
		CALL	SKIP_SPACES
		JP	C,.DONE
		LD	DE,ARG_BUFF
		LD	C,ARG_SIZE-1
		CALL	COPY_ARG
		JP	C,.ERR
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_LIST
		POP	BC
		POP	HL
		JP	NC,.LIST
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_NLST
		POP	BC
		POP	HL
		JP	NC,.NLST
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_PUT
		POP	BC
		POP	HL
		JP	NC,.PUT
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_USER
		POP	BC
		POP	HL
		JP	NC,.USER
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_PASS
		POP	BC
		POP	HL
		JP	NC,.PASS
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_OUTPUT
		POP	BC
		POP	HL
		JP	NC,.OUTPUT
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_YES
		POP	BC
		POP	HL
		JP	NC,.YES
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_RESUME
		POP	BC
		POP	HL
		JP	NC,.RESUME_ARG
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_DOTS
		POP	BC
		POP	HL
		JP	NC,.DOTS_ARG
		PUSH	HL
		PUSH	BC
		CALL	IS_ARG_HELP
		POP	BC
		POP	HL
		JP	NC,.HELP
		LD	A,(PATH_BUFF)
		AND	A
		JP	NZ,.ERR
		; COPY_ASCIIZ_LIMIT clobbers HL/BC, which here still hold the cmdline
		; cursor and remaining-length. Without preserving them, the NEXT token
		; after this positional (e.g. a trailing -y/-f/-r flag) is read from
		; garbage and silently lost.
		PUSH	HL
		PUSH	BC
		LD	HL,ARG_BUFF
		LD	DE,PATH_BUFF
		LD	C,PATH_SIZE-1
		CALL	COPY_ASCIIZ_LIMIT
		POP	BC
		POP	HL
		JP	NC,.NEXT_ARG
		JP	.ERR
.LIST
		LD	A,(PUT_MODE)
		AND	A
		JP	NZ,.ERR
		LD	A,1
		LD	(LIST_FLAG),A
		XOR	A
		LD	(LIST_MODE),A
		JP	.NEXT_ARG
.NLST
		LD	A,(PUT_MODE)
		AND	A
		JP	NZ,.ERR
		LD	A,1
		LD	(LIST_FLAG),A
		LD	(LIST_MODE),A
		JP	.NEXT_ARG
.PUT
		LD	A,(LIST_FLAG)
		AND	A
		JP	NZ,.ERR
		LD	A,(PATH_BUFF)
		AND	A
		JP	NZ,.ERR
		LD	A,1
		LD	(PUT_MODE),A
		JP	.NEXT_ARG
.USER
		CALL	SKIP_SPACES
		JP	C,.ERR
		LD	DE,USER_BUFF
		LD	C,USER_SIZE-1
		CALL	COPY_ARG
		JP	C,.ERR
		LD	A,1
		LD	(USER_GIVEN),A
		JP	.NEXT_ARG
.PASS
		CALL	SKIP_SPACES
		JP	C,.ERR
		LD	DE,PASS_BUFF
		LD	C,PASS_SIZE-1
		CALL	COPY_ARG
		JP	C,.ERR
		LD	A,1
		LD	(PASS_GIVEN),A
		JP	.NEXT_ARG
.OUTPUT
		CALL	SKIP_SPACES
		JP	C,.ERR
		LD	DE,OUT_FILE
		LD	C,OUT_SIZE-1
		CALL	COPY_ARG
		JP	C,.ERR
		JP	.NEXT_ARG
.YES
		LD	A,1
		LD	(FORCE_OVERWRITE),A
		JP	.NEXT_ARG
.RESUME_ARG
		LD	A,1
		LD	(FORCE_RESUME),A
		JP	.NEXT_ARG
.DOTS_ARG
		LD	A,1
		LD	(DOTS_FLAG),A
		JP	.NEXT_ARG
.DONE
		LD	A,(HOST_BUFF)
		AND	A
		JP	Z,.ERR
		LD	A,(LIST_FLAG)
		AND	A
		JP	NZ,.CHECK_PASS
		LD	A,(PATH_BUFF)
		AND	A
		JP	Z,.ERR
		LD	A,(OUT_FILE)
		AND	A
		CALL	Z,BUILD_OUTPUT_FROM_REMOTE
		JP	C,.ERR
.CHECK_PASS
		LD	A,(USER_GIVEN)
		AND	A
		JP	Z,.OK
		LD	A,(PASS_GIVEN)
		AND	A
		JP	NZ,.OK
		XOR	A
		LD	(PASS_BUFF),A
.OK
		LD	A,(HOST_BUFF)
		AND	A
		RET	NZ
.HELP
		LD	A,1
		LD	(HELP_REQUESTED),A
		RET
.ERR
		SCF
		RET

IS_HOST_HELP
		LD	DE,HOST_BUFF
		JR	IS_HELP_TOKEN

IS_ARG_HELP
		LD	DE,ARG_BUFF
IS_HELP_TOKEN
		LD	HL,SWITCH_HELP_Q_SLASH
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_HELP_Q_DASH
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_HELP_H_SLASH
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_HELP_H_DASH
		JP	UTIL.STRCMP_CI

IS_ARG_LIST
		LD	HL,SWITCH_LIST_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_LIST_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

IS_ARG_NLST
		LD	HL,SWITCH_NLST_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_NLST_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

IS_ARG_PUT
		LD	HL,SWITCH_PUT
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

IS_ARG_USER
		LD	HL,SWITCH_USER_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_USER_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

IS_ARG_PASS
		LD	HL,SWITCH_PASS_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_PASS_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

IS_ARG_OUTPUT
		LD	HL,SWITCH_OUTPUT_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_OUTPUT_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

; Overwrite flag: -y / /y, plus -f / /f as a clearer "force" alias.
IS_ARG_YES
		LD	HL,SWITCH_YES_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_YES_SLASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_FORCE_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_FORCE_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

; Resume flag: -r / /r (force append to an existing file, no prompt).
IS_ARG_RESUME
		LD	HL,SWITCH_RESUME_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_RESUME_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

; Dot-progress flag: -d / /d (one dot per write instead of the KB counter).
IS_ARG_DOTS
		LD	HL,SWITCH_DOTS_DASH
		LD	DE,ARG_BUFF
		CALL	UTIL.STRCMP_CI
		RET	NC
		LD	HL,SWITCH_DOTS_SLASH
		LD	DE,ARG_BUFF
		JP	UTIL.STRCMP_CI

SKIP_SPACES
		LD	A,B
		AND	A
		JR	Z,.ERR
.NEXT
		LD	A,(HL)
		CP	' '
		RET	NZ
		INC	HL
		DJNZ	.NEXT
.ERR
		SCF
		RET

COPY_ARG
		XOR	A
		LD	(ARG_LEN),A
.NEXT
		LD	A,B
		AND	A
		JR	Z,.END
		LD	A,(HL)
		CP	' '
		JR	Z,.END
		LD	A,(ARG_LEN)
		CP	C
		JR	NC,.ERR
		LD	A,(HL)
		LD	(DE),A
		INC	HL
		INC	DE
		DEC	B
		LD	A,(ARG_LEN)
		INC	A
		LD	(ARG_LEN),A
		JR	.NEXT
.END
		XOR	A
		LD	(DE),A
		LD	A,(ARG_LEN)
		AND	A
		RET	NZ
.ERR
		SCF
		RET

SPLIT_HOST_PORT
		LD	HL,HOST_BUFF
.NEXT
		LD	A,(HL)
		AND	A
		RET	Z
		CP	':'
		JR	Z,.FOUND
		INC	HL
		JR	.NEXT
.FOUND
		XOR	A
		LD	(HL),A
		INC	HL
		LD	DE,PORT_BUFF
		LD	C,PORT_SIZE-1
		CALL	COPY_ASCIIZ_LIMIT
		RET

COPY_ASCIIZ_LIMIT
		LD	A,(HL)
		AND	A
		JR	Z,.END
		LD	A,C
		AND	A
		JR	Z,.END
		LD	A,(HL)
		LD	(DE),A
		INC	HL
		INC	DE
		DEC	C
		JR	COPY_ASCIIZ_LIMIT
.END
		XOR	A
		LD	(DE),A
		RET

COPY_ASCIIZ_DE
		LD	A,(HL)
		LD	(DE),A
		AND	A
		RET	Z
		INC	HL
		INC	DE
		JR	COPY_ASCIIZ_DE

BUILD_OUTPUT_FROM_REMOTE
		LD	HL,PATH_BUFF
		CALL	FIND_BASENAME
		LD	DE,OUT_FILE
		LD	C,OUT_SIZE-1
		JP	COPY_ASCIIZ_LIMIT

FIND_BASENAME
		LD	DE,PATH_BUFF
		LD	HL,PATH_BUFF
.NEXT
		LD	A,(HL)
		AND	A
		JR	Z,.DONE
		CP	'/'
		JR	Z,.SEP
		CP	'\'
		JR	Z,.SEP
		CP	':'
		JR	Z,.SEP
		INC	HL
		JR	.NEXT
.SEP
		INC	HL
		LD	D,H
		LD	E,L
		JR	.NEXT
.DONE
		EX	DE,HL
		LD	A,(HL)
		AND	A
		RET	NZ
		SCF
		RET

; ------------------------------------------------------
; FTP control channel.
; ------------------------------------------------------
BUILD_FTP_COMMAND
		LD	HL,CMD_BUFF
		CALL	APPEND_STR
		CALL	APPEND_IX_STR
		LD	DE,CMD_CRLF
		CALL	APPEND_STR
		JR	SET_CMD_LEN

BUILD_SIMPLE_COMMAND
		LD	HL,CMD_BUFF
		CALL	APPEND_STR
SET_CMD_LEN
		LD	DE,CMD_BUFF
		OR	A
		SBC	HL,DE
		LD	(CMD_LEN),HL
		RET

BUILD_LIST_COMMAND
		LD	A,(LIST_MODE)
		AND	A
		JR	NZ,.NLST
		LD	A,(PATH_BUFF)
		AND	A
		JR	NZ,.LIST_PATH
		LD	DE,FTP_LIST
		JP	BUILD_SIMPLE_COMMAND
.LIST_PATH
		LD	DE,FTP_LIST_PREFIX
		LD	IX,PATH_BUFF
		JP	BUILD_FTP_COMMAND
.NLST
		LD	A,(PATH_BUFF)
		AND	A
		JR	NZ,.NLST_PATH
		LD	DE,FTP_NLST
		JP	BUILD_SIMPLE_COMMAND
.NLST_PATH
		LD	DE,FTP_NLST_PREFIX
		LD	IX,PATH_BUFF
		JP	BUILD_FTP_COMMAND

BUILD_RETR_COMMAND
		LD	DE,FTP_RETR_PREFIX
		LD	IX,PATH_BUFF
		JP	BUILD_FTP_COMMAND

BUILD_SIZE_COMMAND
		LD	DE,FTP_SIZE_PREFIX
		LD	IX,PATH_BUFF
		JP	BUILD_FTP_COMMAND

BUILD_STOR_COMMAND
		LD	DE,FTP_STOR_PREFIX
		LD	IX,OUT_FILE
		JP	BUILD_FTP_COMMAND

; Build "REST <DATA_TOTAL>\r\n" into CMD_BUFF for an FTP restart/resume.
BUILD_REST_COMMAND
		LD	HL,CMD_BUFF
		LD	DE,FTP_REST_PREFIX
		CALL	APPEND_STR
		CALL	APPEND_DATA_TOTAL_DEC
		LD	DE,CMD_CRLF
		CALL	APPEND_STR
		JP	SET_CMD_LEN

; Append DATA_TOTAL (32-bit LE) as decimal text at HL. Out: HL past digits.
APPEND_DATA_TOTAL_DEC
		PUSH	HL
		LD	HL,DATA_TOTAL
		LD	DE,U32_WORK
		LD	BC,4
		LDIR
		POP	HL
		LD	IX,U32_DIGITS
		LD	C,0				; digit count
.GEN
		PUSH	HL
		PUSH	IX
		CALL	DIV32_WORK_BY_10		; A = next least-significant digit
		POP	IX
		POP	HL
		ADD	A,'0'
		LD	(IX+0),A
		INC	IX
		INC	C
		LD	A,(U32_WORK)			; loop until the value is zero
		PUSH	HL
		LD	HL,U32_WORK+1
		OR	(HL)
		INC	HL
		OR	(HL)
		INC	HL
		OR	(HL)
		POP	HL
		JR	NZ,.GEN
.OUT
		DEC	IX				; emit collected digits most-significant first
		LD	A,(IX+0)
		LD	(HL),A
		INC	HL
		DEC	C
		JR	NZ,.OUT
		RET

; U32_WORK /= 10; returns remainder (0..9) in A. Trashes IX,B,HL.
DIV32_WORK_BY_10
		XOR	A				; running remainder
		LD	IX,U32_WORK+3			; most-significant byte first
		LD	B,4
.BL
		LD	H,A
		LD	L,(IX+0)			; HL = remainder*256 + byte
		PUSH	BC
		CALL	DIV_HL_10			; L = quotient byte, A = remainder
		POP	BC
		LD	(IX+0),L
		DEC	IX
		DJNZ	.BL
		RET

; HL /= 10; quotient in HL, remainder in A. Preserves BC,DE.
DIV_HL_10
		PUSH	BC
		XOR	A
		LD	B,16
.DL
		ADD	HL,HL
		RLA
		CP	10
		JR	C,.DS
		SUB	10
		INC	L
.DS
		DJNZ	.DL
		POP	BC
		RET

; Open a fresh PASV data connection: request PASV, parse the endpoint, open the
; data link. Exits the program on any error. Returns with DATA_OPEN=1.
; ESP bring-up shared by the initial connect and in-run reconnect: verify the
; AT link (non-destructive retry probe), echo off, enable
; UART flow control, and select multi-connection mode. After the peer closes a
; data link mid-transfer the ESP can stop answering control traffic; running
; this before re-login is what lets an in-run auto-resume recover the same way
; a fresh re-run of the utility does.
; ESP_SOFT_RECOVER / ESP_DRAIN_RX are cold (only run on a mid-transfer wedge) and
; never touch RECV_BUFFER, so they live in the WIN2 cold overlay to keep WIN1
; free for the hot path. See OVL_ESP_SOFT_RECOVER below; the auto-resume path
; invokes them via CALL_OVERLAY and reads the SOFT_RECOVER_OK result byte.

ESP_PRELUDE
		LD	HL,CMD_AT
		CALL	SEND_CMD_RECOVER
		LD	HL,CMD_ECHO_OFF
		CALL	SEND_CMD
		; NETUP owns the ESP UART configuration. This utility only applies
		; NET_BAUD/NET_ESP_FLOW to its local 16550 and verifies the AT link.
		CALL	WCOMMON.SETUP_UART_FLOW
		AND	A
		JP	NZ,NET_ERROR_EXIT
		CALL	WCOMMON.CLEAN_ESP_LINKS		; drop any link a prior run left open
		LD	HL,CMD_CIPMUX_1
		CALL	SEND_CMD
		XOR	A
		CALL	TCP.SET_PASSIVE_RECEIVE
		; A prior FTP build may have exited with ESP still in passive mode. The
		; control greeting would then be a length-only +IPD which the active
		; pre-login parser cannot consume. Always establish a known active state
		; before CIPSTART; passive is enabled later by ENABLE_PASSIVE_RECEIVE.
		IFDEF	ESP_AT_FORCE_221
		RET
		ELSE
		IFNDEF	ESP_AT_FORCE_222
		LD	A,(WCOMMON.UART_ESP_PROFILE)
		CP	UART_RX_PROFILE_222
		RET	NZ
		ENDIF
		LD	HL,CMD_CIPRECVMODE_0
		CALL	SEND_CMD
		ENDIF
		RET

; Enter passive receive only in an explicitly forced ESP-AT 2.2.2 build.
; Universal FTP retains active +IPD on both firmwares until passive control
; replies have been fully hardware-qualified.
ENABLE_PASSIVE_RECEIVE
		IFDEF	ESP_AT_FORCE_222
		; Do not let CIPRECVMODE/CIPDINFO change ESP NVS settings when FTP is
		; invoked independently of NETUP. All failures are a local fallback,
		; never a connection failure.
		LD	HL,CMD_SYSSTORE_VOLATILE
		CALL	SEND_CMD_IGNORE
		LD	HL,CMD_CIPRECVMODE_1
		CALL	SEND_CMD_IGNORE
		AND	A
		RET	NZ
		LD	HL,CMD_CIPDINFO_0
		CALL	SEND_CMD_IGNORE
		AND	A
		RET	NZ
		LD	A,1
		CALL	TCP.SET_PASSIVE_RECEIVE
		ENDIF
		RET

; Open the control connection and complete the FTP login (USER/PASS) plus
; TYPE I. Returns normally on success; jumps to an error exit on failure.
; Used both for the initial connect and to re-establish a clean control
; channel for an in-run auto-resume.
LOGIN_SEQUENCE
		PRINT MSG_CONNECTING
		PRINT HOST_BUFF
		PRINT MSG_COLON
		PRINT PORT_BUFF
		PRINT WCOMMON.LINE_END

		LD	A,CONTROL_LINK
		LD	HL,HOST_BUFF
		LD	DE,PORT_BUFF
		CALL	TCP.OPEN_LINK
		JP	C,NET_ERROR_EXIT
		LD	A,1
		LD	(CONTROL_OPEN),A

		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_REPLY_POSITIVE
		JP	C,FTP_ERROR_EXIT

		PRINTLN MSG_LOGIN
		LD	DE,FTP_USER_PREFIX
		LD	IX,USER_BUFF
		CALL	BUILD_FTP_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_USER_REPLY
		JP	C,FTP_ERROR_EXIT

		LD	A,(REPLY_FIRST)
		CP	'3'
		JR	NZ,.NO_PASS
		LD	DE,FTP_PASS_PREFIX
		LD	IX,PASS_BUFF
		CALL	BUILD_FTP_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_REPLY_POSITIVE
		JP	C,FTP_ERROR_EXIT

.NO_PASS
		PRINTLN MSG_BINARY
		LD	DE,FTP_TYPE_I
		CALL	BUILD_SIMPLE_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	CHECK_REPLY_POSITIVE
		JP	C,FTP_ERROR_EXIT
		CALL	ENABLE_PASSIVE_RECEIVE
		RET

; ------------------------------------------------------
; Query the remote file's complete size with FTP SIZE. This is intentionally
; performed only before the first RETR: automatic REST retries must keep the
; original expected length, not reinterpret a partial 150 reply. A 5xx SIZE
; reply is non-fatal because some FTP servers do not implement SIZE; the 150
; parser remains the compatibility fallback.
; Out: CF=1 only on ESP/control-channel communication failure.
; ------------------------------------------------------
QUERY_REMOTE_SIZE
		LD	A,(DATA_EXPECTED_SEEN)
		AND	A
		RET	NZ
		CALL	BUILD_SIZE_COMMAND
		CALL	SEND_CONTROL
		RET	C
		CALL	RECV_CONTROL_REPLY
		RET	C
		LD	A,(REPLY_CODE_1)
		CP	'2'
		JR	NZ,.UNAVAILABLE
		LD	A,(REPLY_CODE_2)
		CP	'1'
		JR	NZ,.UNAVAILABLE
		LD	A,(REPLY_CODE_3)
		CP	'3'
		JR	NZ,.UNAVAILABLE
		; "213 <decimal-size>". Skip the reply code and its required space.
		LD	HL,LINE_BUFF+4
		CALL	PARSE_EXPECTED_SIZE_AT_HL
		JR	NC,.DONE
		; Malformed 213 must not poison the later 150 fallback.
		XOR	A
		LD	(DATA_EXPECTED_SEEN),A
.UNAVAILABLE
		XOR	A
		RET
.DONE
		XOR	A
		RET

DO_PASV_OPEN
		PRINTLN	MSG_PASV
		LD	DE,FTP_PASV
		CALL	BUILD_SIMPLE_COMMAND
		CALL	SEND_CONTROL
		JP	C,NET_ERROR_EXIT
		CALL	RECV_CONTROL_REPLY
		JP	C,NET_ERROR_EXIT
		CALL	PARSE_PASV_ENDPOINT
		JP	C,FTP_ERROR_EXIT
		PRINT	MSG_PASV_ENDPOINT
		PRINT	PASV_HOST_BUFF
		PRINT	MSG_COLON
		PRINT	PASV_PORT_BUFF
		PRINT	WCOMMON.LINE_END
		PRINT	MSG_OPEN_DATA
		PRINT	PASV_HOST_BUFF
		PRINT	MSG_COLON
		PRINT	PASV_PORT_BUFF
		PRINT	WCOMMON.LINE_END
		LD	A,DATA_LINK
		LD	HL,PASV_HOST_BUFF
		LD	DE,PASV_PORT_BUFF
		CALL	TCP.OPEN_LINK
		JP	C,NET_ERROR_EXIT
		LD	A,1
		LD	(DATA_OPEN),A
		RET

; CF=1 iff DATA_TOTAL (32-bit) is non-zero. Trashes A,HL.
DATA_TOTAL_NONZERO
		LD	A,(DATA_TOTAL)
		LD	HL,DATA_TOTAL+1
		OR	(HL)
		INC	HL
		OR	(HL)
		INC	HL
		OR	(HL)
		RET	Z				; all zero -> CF=0
		SCF
		RET

; Z=1 iff the download is complete (DATA_TOTAL >= DATA_EXPECTED), or the size is
; unknown (then treat as done so auto-resume cannot loop forever). Trashes A,B,DE,HL.
DOWNLOAD_COMPLETE
		LD	A,(DATA_EXPECTED_SEEN)
		AND	A
		JR	Z,.YES
		LD	HL,DATA_EXPECTED+3
		LD	DE,DATA_TOTAL+3
		LD	B,4
.CMP
		LD	A,(DE)
		CP	(HL)
		JR	C,.NO				; total < expected
		JR	NZ,.YES				; total > expected
		DEC	DE
		DEC	HL
		DJNZ	.CMP
.YES
		XOR	A
		RET
.NO
		OR	0xFF
		RET

; Report transfer speed over the bytes fetched this run (DATA_TOTAL-SESSION_BASE).
REPORT_SESSION_SPEED
		OR	A
		LD	HL,(DATA_TOTAL)
		LD	DE,(SESSION_BASE)
		SBC	HL,DE
		PUSH	HL				; session low
		LD	HL,(DATA_TOTAL+2)
		LD	DE,(SESSION_BASE+2)
		SBC	HL,DE				; session high
		EX	DE,HL				; DE = high
		POP	HL				; HL = low
		JP	TPUT.REPORT

SEND_CONTROL
		LD	HL,CMD_BUFF
		LD	BC,(CMD_LEN)
		LD	A,CONTROL_LINK
		JP	TCP.SEND_BUFFER_LINK_NO_WAIT

RECV_CONTROL_REPLY_IGNORE
		CALL	RECV_CONTROL_REPLY
		RET

RECV_CONTROL_REPLY
		LD	DE,FTP_RECV_TIMEOUT
		JP	RECV_CONTROL_REPLY_TIMEOUT

RECV_CONTROL_REPLY_OPTIONAL
		LD	DE,FTP_FINAL_TIMEOUT
		JP	RECV_CONTROL_REPLY_TIMEOUT

RECV_CONTROL_REPLY_TIMEOUT
		LD	(CONTROL_TIMEOUT),DE
		CALL	RESET_REPLY_STATE
.READ
		CALL	WIFI.UART_RX_RESUME
		; Clear sticky LSR error bits before each RECEIVE so OE detection
		; below reflects only this iteration's UART status.
		XOR	A
		LD	(TCP.LSR_ACCUM),A
		LD	HL,RECV_BUFFER
		LD	BC,RECV_SIZE
		LD	DE,(CONTROL_TIMEOUT)
		CALL	TCP.RECEIVE_ANY_LINK
		PUSH	AF,BC
		CALL	WIFI.UART_RX_PAUSE
		POP	BC,AF
		JR	C,.ERROR
		; UART overrun/parity/framing error during RECEIVE means the +IPD
		; payload is misaligned. TCP can't recover lost bytes, so propagate
		; as a fatal error rather than processing corrupt control bytes.
		LD	A,(TCP.LSR_ACCUM)
		AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
		JR	NZ,.UART_ERROR
		LD	A,B
		OR	C
		JR	Z,.READ
		LD	A,(TCP.LAST_IPD_LINK)
		CP	CONTROL_LINK
		JR	Z,.CONTROL
		CP	DATA_LINK
		JR	NZ,.READ
			; Data link bytes arrived before the control reply. Pause RX for
			; the slow console/file output path — same rationale as in
			; RECV_DATA_TRANSFER.
			LD	A,1
			LD	(DATA_BYTES_SEEN),A
			; Size still unknown (150 not parsed): suppress the progress
			; render so it doesn't print "?KB" and glue the 150 reply onto
			; the dots. Cleared right after; RECV_DATA_TRANSFER renders real
			; progress once PARSE_EXPECTED_SIZE has run.
			LD	(PROGRESS_SUPPRESS),A
			LD	HL,RECV_BUFFER
			CALL	HANDLE_DATA_BUFFER
			PUSH	AF			; HANDLE_DATA_BUFFER CF = file error
			XOR	A
			LD	(PROGRESS_SUPPRESS),A
			POP	AF
			JR	NC,.DATA_HANDLED
			CALL	WIFI.UART_RX_RESUME
			JP	FILE_ERROR_EXIT
.DATA_HANDLED
			CALL	WIFI.UART_RX_RESUME
			JR	.READ
.CONTROL
		; FEED_CONTROL_BYTES calls FINISH_LINE → PRINTLN on every CR/LF.
		; RX is already paused immediately after RECEIVE_ANY_LINK.
		LD	HL,RECV_BUFFER
		CALL	FEED_CONTROL_BYTES_MAYBE_DEFERRED
		CALL	WIFI.UART_RX_RESUME
		LD	A,(REPLY_DONE)
		AND	A
		JR	Z,.READ
		XOR	A
		RET

.ERROR
		PUSH	AF
		CALL	WIFI.UART_RX_RESUME
		POP	AF
		SCF
		RET

.UART_ERROR
		CALL	WIFI.UART_RX_RESUME
		CALL	PRINT_UART_OVERRUN
		LD	A,RES_RS_TIMEOUT
		SCF
		RET

RESET_REPLY_STATE
		XOR	A
		LD	(REPLY_DONE),A
		LD	(REPLY_FIRST),A
		LD	(REPLY_CODE_1),A
		LD	(REPLY_CODE_2),A
		LD	(REPLY_CODE_3),A
		LD	(LINE_LEN),A
		RET

FEED_CONTROL_BYTES
		LD	A,B
		OR	C
		RET	Z
.NEXT
		LD	A,(HL)
		INC	HL
		DEC	BC
		CP	13
		JR	Z,.CHECK
		CP	10
		JR	Z,.LINE
		PUSH	BC,HL
		CALL	APPEND_LINE_CHAR
		POP	HL,BC
		JR	.CHECK
.LINE
		PUSH	BC,HL
		CALL	FINISH_LINE
		POP	HL,BC
.CHECK
		LD	A,(REPLY_DONE)
		AND	A
		JR	Z,.MORE
		; A small LIST may carry both 150 and 226 in one control +IPD.
		; When printing is deferred, consume the rest so the terminal reply
		; replaces the preliminary one instead of being lost or printed early.
		LD	A,(CONTROL_PRINT_SUPPRESS)
		AND	A
		RET	Z
.MORE
		LD	A,B
		OR	C
		JR	NZ,.NEXT
		RET

APPEND_LINE_CHAR
		LD	C,A
		LD	A,(LINE_LEN)
		CP	LINE_SIZE-1
		RET	NC
		LD	E,A
		LD	D,0
		LD	HL,LINE_BUFF
		ADD	HL,DE
		LD	(HL),C
		LD	A,(LINE_LEN)
		INC	A
		LD	(LINE_LEN),A
		RET

FINISH_LINE
		LD	A,(LINE_LEN)
		AND	A
		JR	Z,.RESET
		LD	E,A
		LD	D,0
		LD	HL,LINE_BUFF
		ADD	HL,DE
		XOR	A
		LD	(HL),A
		LD	A,(CONTROL_PRINT_SUPPRESS)
		AND	A
		JR	NZ,.DEFER_PRINT
		PRINTLN	LINE_BUFF
		JR	.PARSE
.DEFER_PRINT
		CALL	STORE_DEFERRED_CONTROL_LINE
.PARSE
		CALL	PARSE_REPLY_LINE
.RESET
		XOR	A
		LD	(LINE_LEN),A
		RET

STORE_DEFERRED_CONTROL_LINE
		LD	HL,LINE_BUFF
		LD	DE,DEFERRED_CONTROL_LINE
		LD	B,LINE_SIZE
.COPY
		LD	A,(HL)
		LD	(DE),A
		INC	HL
		INC	DE
		AND	A
		JR	Z,.DONE
		DJNZ	.COPY
		XOR	A
		LD	(DE),A
.DONE
		LD	A,1
		LD	(DEFERRED_CONTROL_SEEN),A
		RET

PRINT_DEFERRED_CONTROL
		LD	A,(DEFERRED_CONTROL_SEEN)
		AND	A
		RET	Z
		XOR	A
		LD	(DEFERRED_CONTROL_SEEN),A
		; End the progress-dots line first so the deferred reply (e.g.
		; "226 Transfer complete") prints on its own line, not glued to dots.
		PRINT	WCOMMON.LINE_END
		PRINTLN	DEFERRED_CONTROL_LINE
		RET

PARSE_REPLY_LINE
		LD	HL,LINE_BUFF
		CALL	IS_DIGIT_AT_HL
		RET	C
		LD	A,(HL)
		LD	(REPLY_CODE_1),A
		LD	(REPLY_FIRST),A
		INC	HL
		CALL	IS_DIGIT_AT_HL
		RET	C
		LD	A,(HL)
		LD	(REPLY_CODE_2),A
		INC	HL
		CALL	IS_DIGIT_AT_HL
		RET	C
		LD	A,(HL)
		LD	(REPLY_CODE_3),A
		INC	HL
		LD	A,(HL)
		CP	' '
		RET	NZ
		LD	A,1
		LD	(REPLY_DONE),A
		RET

IS_DIGIT_AT_HL
		LD	A,(HL)
		CP	'0'
		JR	C,.ERR
		CP	'9'+1
		JR	NC,.ERR
		OR	A
		RET
.ERR
		SCF
		RET

CHECK_REPLY_POSITIVE
		LD	A,(REPLY_FIRST)
		CP	'2'
		RET	Z
		CP	'3'
		RET	Z
		SCF
		RET

CHECK_USER_REPLY
		LD	A,(REPLY_FIRST)
		CP	'2'
		RET	Z
		CP	'3'
		RET	Z
		SCF
		RET

PARSE_PASV_ENDPOINT
		LD	A,(REPLY_CODE_1)
		CP	'2'
		JR	NZ,.ERR
		LD	A,(REPLY_CODE_2)
		CP	'2'
		JR	NZ,.ERR
		LD	A,(REPLY_CODE_3)
		CP	'7'
		JR	NZ,.ERR
		LD	HL,LINE_BUFF
.FIND_OPEN
		LD	A,(HL)
		AND	A
		JR	Z,.ERR
		CP	'('
		JR	Z,.PARSE
		INC	HL
		JR	.FIND_OPEN
.PARSE
		INC	HL
		CALL	PARSE_DEC_BYTE
		JR	C,.ERR
		LD	(PASV_H1),A
		CALL	EXPECT_COMMA
		JR	C,.ERR
		CALL	PARSE_DEC_BYTE
		JR	C,.ERR
		LD	(PASV_H2),A
		CALL	EXPECT_COMMA
		JR	C,.ERR
		CALL	PARSE_DEC_BYTE
		JR	C,.ERR
		LD	(PASV_H3),A
		CALL	EXPECT_COMMA
		JR	C,.ERR
		CALL	PARSE_DEC_BYTE
		JR	C,.ERR
		LD	(PASV_H4),A
		CALL	EXPECT_COMMA
		JR	C,.ERR
		CALL	PARSE_DEC_BYTE
		JR	C,.ERR
		LD	(PASV_P1),A
		CALL	EXPECT_COMMA
		JR	C,.ERR
		CALL	PARSE_DEC_BYTE
		JR	C,.ERR
		LD	(PASV_P2),A
		CALL	BUILD_PASV_ENDPOINT
		XOR	A
		RET
.ERR
		SCF
		RET

EXPECT_COMMA
		LD	A,(HL)
		CP	','
		JR	NZ,.ERR
		INC	HL
		XOR	A
		RET
.ERR
		SCF
		RET

PARSE_DEC_BYTE
		LD	E,0
		LD	B,0
.NEXT
		LD	A,(HL)
		CP	'0'
		JR	C,.DONE
		CP	'9'+1
		JR	NC,.DONE
		SUB	'0'
		LD	C,A
		LD	A,E
		ADD	A,A
		LD	D,A
		ADD	A,A
		ADD	A,A
		ADD	A,D
		ADD	A,C
		LD	E,A
		INC	HL
		INC	B
		JR	.NEXT
.DONE
		LD	A,B
		AND	A
		JR	Z,.ERR
		LD	A,E
		OR	A
		RET
.ERR
		SCF
		RET

PARSE_EXPECTED_SIZE
		LD	A,(DATA_EXPECTED_SEEN)
		AND	A
		RET	NZ				; SIZE already supplied the full remote length
		XOR	A
		LD	(DATA_EXPECTED_SEEN),A
		LD	A,(LIST_FLAG)
		AND	A
		RET	NZ
		LD	(DATA_EXPECTED),A
		LD	(DATA_EXPECTED+1),A
		LD	(DATA_EXPECTED+2),A
		LD	(DATA_EXPECTED+3),A
		LD	HL,LINE_BUFF
.FIND_OPEN
		LD	A,(HL)
		AND	A
		RET	Z
		CP	'('
		JR	Z,.CHECK_DIGIT
		INC	HL
		JR	.FIND_OPEN
.CHECK_DIGIT
		INC	HL
		JP	PARSE_EXPECTED_SIZE_AT_HL

; Parse an unsigned decimal size at HL into DATA_EXPECTED. This is shared by
; legacy 150 "(...bytes...)" replies and the standard "213 <size>" SIZE
; response. CF=0 on at least one digit; CF=1 otherwise.
PARSE_EXPECTED_SIZE_AT_HL
		XOR	A
		LD	(DATA_EXPECTED_SEEN),A
		LD	(DATA_EXPECTED),A
		LD	(DATA_EXPECTED+1),A
		LD	(DATA_EXPECTED+2),A
		LD	(DATA_EXPECTED+3),A
		LD	(SIZE_DIGITS),A
.CHECK_DIGIT
		LD	A,(HL)
		CP	'0'
		JR	C,.ERR
		CP	'9'+1
		JR	NC,.ERR
.PARSE
		LD	A,(HL)
		CP	'0'
		JR	C,.DONE
		CP	'9'+1
		JR	NC,.DONE
		SUB	'0'
		PUSH	HL
		LD	(U32_DIGIT),A
		CALL	U32_MUL10_EXPECTED
		LD	A,(U32_DIGIT)
		CALL	U32_ADD_A_EXPECTED
		POP	HL
		INC	HL
		LD	A,(SIZE_DIGITS)
		INC	A
		LD	(SIZE_DIGITS),A
		JR	.PARSE
.DONE
		LD	A,(SIZE_DIGITS)
		AND	A
		JR	Z,.ERR
		LD	A,1
		LD	(DATA_EXPECTED_SEEN),A
		OR	A
		RET
.ERR
		SCF
		RET

U32_MUL10_EXPECTED
		CALL	U32_COPY_EXPECTED_TO_TMP
		CALL	U32_SHL1_EXPECTED
		CALL	U32_SHL1_TMP
		CALL	U32_SHL1_TMP
		CALL	U32_SHL1_TMP
		JP	U32_ADD_TMP_TO_EXPECTED

U32_COPY_EXPECTED_TO_TMP
		LD	HL,DATA_EXPECTED
		LD	DE,U32_TMP
		LD	BC,4
		JR	U32_COPY4

U32_COPY4
		LD	A,(HL)
		LD	(DE),A
		INC	HL
		INC	DE
		DEC	BC
		LD	A,B
		OR	C
		JR	NZ,U32_COPY4
		RET

U32_SHL1_EXPECTED
		LD	HL,DATA_EXPECTED
		JR	U32_SHL1_AT_HL

U32_SHL1_TMP
		LD	HL,U32_TMP

U32_SHL1_AT_HL
		SLA	(HL)
		INC	HL
		RL	(HL)
		INC	HL
		RL	(HL)
		INC	HL
		RL	(HL)
		RET

U32_ADD_TMP_TO_EXPECTED
		LD	HL,DATA_EXPECTED
		LD	DE,U32_TMP
		LD	A,(DE)
		ADD	A,(HL)
		LD	(HL),A
		INC	HL
		INC	DE
		LD	A,(DE)
		ADC	A,(HL)
		LD	(HL),A
		INC	HL
		INC	DE
		LD	A,(DE)
		ADC	A,(HL)
		LD	(HL),A
		INC	HL
		INC	DE
		LD	A,(DE)
		ADC	A,(HL)
		LD	(HL),A
		RET

U32_ADD_A_EXPECTED
		LD	HL,DATA_EXPECTED
		ADD	A,(HL)
		LD	(HL),A
		RET	NC
		INC	HL
		INC	(HL)
		RET	NZ
		INC	HL
		INC	(HL)
		RET	NZ
		INC	HL
		INC	(HL)
		RET

CHECK_LIST_PRELIM_REPLY
		LD	A,(REPLY_FIRST)
		CP	'1'
		RET	Z
		CP	'2'
		RET	Z
		SCF
		RET

RECV_DATA_TRANSFER
			XOR	A
			LD	(FINAL_REPLY_SEEN),A
			LD	(DATA_CLOSE_SEEN),A
			LD	(HOLD_MODE),A
			LD	(HOLD_LEN),A
			LD	(HOLD_LEN+1),A
			INC	A
			LD	(TRANSFER_ACTIVE),A
		; Note: DATA_BYTES_SEEN may already be set by an earlier
		; RECV_CONTROL_REPLY that received data-link bytes while
		; waiting for the 150 reply. Don't clear it here.
		CALL	RESET_REPLY_STATE
.READ
		CALL	WIFI.UART_RX_RESUME
		; Clear sticky LSR error bits before each RECEIVE — see same
		; rationale in RECV_CONTROL_REPLY_TIMEOUT.
		XOR	A
		LD	(TCP.LSR_ACCUM),A
		; Enter retain-tail mode before the read once the file is within
		; FTP_HOLD_TAIL_MARGIN of completion (see FTP_UPDATE_HOLD_MODE).
		CALL	FTP_UPDATE_HOLD_MODE
		CALL	FTP_SETUP_RECV_DEST
		LD	HL,(RECV_DEST)
		LD	BC,(RECV_CAP)
		; Once the control link has delivered the final "226 Transfer complete"
		; the server is done; if the ESP then stops short of the announced size
		; (its FIN-time +IPD drop) wait only a short grace instead of the full
		; data timeout, so a truncated transfer no longer hangs ~20-30 s.
		LD	DE,FTP_DATA_TIMEOUT
		LD	A,(FINAL_REPLY_SEEN)
		AND	A
		JR	Z,.HAVE_TIMEOUT
		LD	DE,FTP_FINAL_TIMEOUT
.HAVE_TIMEOUT
		CALL	TCP.RECEIVE_ANY_LINK
		PUSH	AF,BC
		CALL	WIFI.UART_RX_PAUSE
		POP	BC,AF
		JR	C,.ERROR
		; UART error during data-link receive: bytes are misaligned and
		; TCP cannot retransmit lost UART bytes. Treat as end-of-listing
		; if anything has been received already; otherwise propagate.
		LD	A,(TCP.LSR_ACCUM)
		AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
		JR	NZ,.UART_ERROR
		LD	A,B
		OR	C
		JR	Z,.READ
		LD	A,(TCP.LAST_IPD_LINK)
		CP	DATA_LINK
		JR	Z,.DATA
		CP	CONTROL_LINK
		JR	NZ,.READ
		; Treat any control IPD as evidence the transfer is in
		; progress. Without this, a UART overrun that corrupts the
		; link-id digit ('1' lost in "+IPD,1,N:") would silently
		; route directory bytes through FEED_CONTROL_BYTES and
		; leave DATA_BYTES_SEEN=0, producing a false #4 timeout.
		LD	A,1
		LD	(DATA_BYTES_SEEN),A
		LD	HL,(RECV_DEST)
		; Defer "226 Transfer complete" until the data loop ends so it prints
		; after the progress dots, not interleaved mid-transfer.
		CALL	FEED_CONTROL_BYTES_MAYBE_DEFERRED
		LD	A,(REPLY_DONE)
		AND	A
		JR	Z,.READ
		LD	A,1
		LD	(FINAL_REPLY_SEEN),A
		JR	.READ
.DATA
		LD	A,1
		LD	(DATA_BYTES_SEEN),A
			; In retain-tail mode each +IPD is held as-is (no burst
			; accumulation), so the final bytes never sit behind a slow
			; DSS_WRITE while the data link is closing.
			LD	A,(HOLD_MODE)
			AND	A
			JR	NZ,.DATA_NOBURST
			CALL	ACCUMULATE_DATA_BURST
			JR	C,.UART_ERROR
.DATA_NOBURST
			; Keep the common receive guard around the slow console/file path.
			; Both firmware paths explicitly lower RTS here: auto-only AFE on
			; 2.2.2 still overran during real +IPD directory listings.
			LD	HL,(RECV_DEST)
			CALL	HANDLE_DATA_BUFFER
			JR	NC,.DATA_HANDLED
			CALL	WIFI.UART_RX_RESUME
			JP	FILE_ERROR_EXIT
.DATA_HANDLED
			; In retain-tail mode there is no DSS_WRITE or progress rendering here.
			; Keep RTS deasserted while we inspect the completed block and any
			; deferred control reply. The next .READ resumes it immediately before
			; the next UART drain; this removes the unprotected gap between tail
			; blocks and the data-link FIN.
			LD	A,(HOLD_MODE)
			AND	A
			JR	NZ,.TAIL_STILL_PAUSED
			CALL	WIFI.UART_RX_RESUME
.TAIL_STILL_PAUSED
			CALL	PROCESS_PENDING_CONTROL
			LD	A,(DATA_CLOSE_SEEN)
		AND	A
		JR	NZ,.CLOSED
		JP	.READ
.ERROR
		PUSH	AF
		CALL	WIFI.UART_RX_RESUME
		POP	AF
		; Never turn a receive timeout or a parser error into a successful list.
		; Doing so left the still-buffered UART tail to be consumed by QUIT and
		; printed it as garbage. Only an explicit ESP link-close ends a transfer.
		CP	RES_NOT_CONN
		JR	Z,.CLOSED
		SCF
		RET
.UART_ERROR
			; OE/PE/FE means an AT header or file byte was lost. The current
			; output can no longer be repaired by REST from DATA_TOTAL: that
			; offset is after potentially corrupt bytes. Fail this run instead
			; of treating it as a clean close / auto-resume opportunity.
			CALL	WIFI.UART_RX_RESUME
			XOR	A
			LD	(TRANSFER_ACTIVE),A
			CALL	PRINT_UART_OVERRUN
			LD	A,RES_RS_TIMEOUT
			SCF
			RET
.CLOSED
		CALL	WIFI.UART_RX_RESUME
		XOR	A
		LD	(TRANSFER_ACTIVE),A
		; Persist the retained tail now that the data link has closed and all
		; +IPD bytes have been drained into RECV_BUFFER.
		CALL	FTP_FLUSH_HOLD
		JP	C,FILE_ERROR_EXIT
		XOR	A
		LD	(DATA_OPEN),A
		; Reset TCP receive state. Without this a partially-read
		; +IPD chunk leaves PAYLOAD_LEFT non-zero and LAST_IPD_LINK
		; pointing at the data link, so the next RECEIVE_ANY_LINK
		; (e.g. waiting for the QUIT reply) skips WAIT_IPD_HEADER
		; and consumes "0,SEND OK\r\n+IPD,0,N:..." as stale payload,
		; printing it through PRINT_BUFFER.
		LD	HL,0
		LD	(TCP.PAYLOAD_LEFT),HL
		LD	A,0xFF
		LD	(TCP.LAST_IPD_LINK),A
		CALL	PRINT_DEFERRED_CONTROL
			PRINT WCOMMON.LINE_END
			RET

SEND_DATA_TRANSFER
		XOR	A
		LD	(FINAL_REPLY_SEEN),A
		LD	(DATA_CLOSE_SEEN),A
.READ
		CALL	WIFI.UART_RX_PAUSE
		LD	A,(OUT_FH)
		LD	HL,RECV_BUFFER
		LD	DE,FTP_PUT_READ_SIZE
		LD	C,DSS_READ_FILE
		RST	DSS
		PUSH	AF,DE
		CALL	WIFI.UART_RX_RESUME
		POP	DE,AF
		JP	C,FILE_ERROR_EXIT
		LD	A,D
		OR	E
		JR	Z,.DONE
		LD	(DATA_ACCUM_LEN),DE
		LD	HL,RECV_BUFFER
		LD	(BURST_DEST),HL
.SEND
		LD	HL,(DATA_ACCUM_LEN)
		LD	A,H
		OR	L
		JR	Z,.READ
		LD	DE,FTP_PUT_CHUNK
		PUSH	HL
		OR	A
		SBC	HL,DE
		POP	HL
		JR	C,.TAIL
		LD	BC,FTP_PUT_CHUNK
		JR	.SEND_CHUNK
.TAIL
		LD	B,H
		LD	C,L
.SEND_CHUNK
		LD	HL,(BURST_DEST)
		PUSH	BC
		LD	A,DATA_LINK
		CALL	TCP.SEND_BUFFER_LINK
		POP	BC
		RET	C
		CALL	ADD_DATA_TOTAL
		LD	HL,(BURST_DEST)
		ADD	HL,BC
		LD	(BURST_DEST),HL
		LD	HL,(DATA_ACCUM_LEN)
		OR	A
		SBC	HL,BC
		LD	(DATA_ACCUM_LEN),HL
		CALL	PROGRESS_TICK
		JR	.SEND
.DONE
		PRINT	WCOMMON.LINE_END
		XOR	A
		RET

; ------------------------------------------------------
; PROGRESS_TICK: per-write progress output for the data loops.
; Default: repaint the in-place "<KB>KB / <KB>KB" counter.
; Under -d: one dot and nothing else — the output FTP had before the counter
; existed. The counter is drawn through the DSS console with RX paused, so -d
; is what makes its cost measurable against the same transfer.
; Must return CF=0: callers propagate CF as success/fail.
; ------------------------------------------------------
PROGRESS_TICK
		LD	A,(DOTS_FLAG)
		AND	A
		JR	NZ,.DOT
		LD	HL,DATA_TOTAL
		LD	DE,DATA_EXPECTED
		JP	TPUT.PROGRESS
.DOT
		LD	A,'.'
		CALL	PUT_CHAR
		OR	A			; CF=0 (success)
		RET

HANDLE_DATA_BUFFER
			LD	A,(LIST_FLAG)
			AND	A
			JP	NZ,PRINT_BUFFER
			JP	WRITE_DATA_BUFFER

ACCUMULATE_DATA_BURST
			LD	(DATA_ACCUM_LEN),BC
			XOR	A
			LD	(PENDING_CONTROL_SEEN),A
.LOOP
			; Ceiling is RECV_CAP, not RECV_SIZE: in stream mode it is clamped
			; so the burst never crosses into the final retain-tail bytes.
			LD	HL,(RECV_CAP)
			LD	DE,(DATA_ACCUM_LEN)
			OR	A
			SBC	HL,DE
			JR	C,.DONE
			LD	A,H
			OR	L
			JR	Z,.DONE
			; Limit every accumulation pass. Previously this only compared the
			; capacity and still passed the whole RECV_CAP to RECEIVE_ANY_LINK,
			; allowing a large directory listing to become one oversized burst.
			LD	DE,FTP_ACTIVE_IPD_MAX
			OR	A
			SBC	HL,DE
			JR	C,.CAP_SMALLER
			LD	BC,FTP_ACTIVE_IPD_MAX
			JR	.HAVE_CAP
.CAP_SMALLER
			ADD	HL,DE
			LD	B,H
			LD	C,L
.HAVE_CAP
			LD	HL,(RECV_DEST)
			LD	DE,(DATA_ACCUM_LEN)
			ADD	HL,DE
			LD	(BURST_DEST),HL
			LD	DE,FTP_BURST_TIMEOUT
			CALL	WIFI.UART_RX_RESUME
			CALL	TCP.RECEIVE_ANY_LINK
			PUSH	AF,BC
			CALL	WIFI.UART_RX_PAUSE
			POP	BC,AF
			; LSR_ACCUM belongs to the whole outer receive iteration. Do not
			; discard an overrun from a follow-up burst by returning success and
			; letting the next .READ clear it.
			LD	A,(TCP.LSR_ACCUM)
			AND	LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
			JR	NZ,.UART_ERROR
			JR	NC,.RECEIVED
			; A normal data-link close may be received while draining a burst.
			; Preserve the data already collected, but do not lose the close and
			; wait the full FTP_DATA_TIMEOUT on the next outer receive.
			CP	RES_NOT_CONN
			JR	NZ,.DONE
			LD	A,1
			LD	(DATA_CLOSE_SEEN),A
			JR	.DONE
.RECEIVED
			LD	A,B
			OR	C
			JR	Z,.LOOP
			LD	A,(TCP.LAST_IPD_LINK)
			CP	DATA_LINK
			JR	Z,.DATA
			CP	CONTROL_LINK
			JR	NZ,.DONE
			LD	HL,(BURST_DEST)
			LD	(PENDING_CONTROL_PTR),HL
			LD	(PENDING_CONTROL_LEN),BC
			LD	A,1
			LD	(PENDING_CONTROL_SEEN),A
			JR	.DONE
.DATA
			LD	HL,(DATA_ACCUM_LEN)
			ADD	HL,BC
			LD	(DATA_ACCUM_LEN),HL
			JR	.LOOP
.DONE
			LD	BC,(DATA_ACCUM_LEN)
			XOR	A
			RET
.UART_ERROR
			LD	A,RES_RS_TIMEOUT
			SCF
			RET

PROCESS_PENDING_CONTROL
			LD	A,(PENDING_CONTROL_SEEN)
			AND	A
			RET	Z
			XOR	A
			LD	(PENDING_CONTROL_SEEN),A
			LD	HL,(PENDING_CONTROL_PTR)
			LD	BC,(PENDING_CONTROL_LEN)
			CALL	FEED_CONTROL_BYTES_MAYBE_DEFERRED
			LD	A,(REPLY_DONE)
			AND	A
			RET	Z
			LD	A,1
			LD	(FINAL_REPLY_SEEN),A
			RET

FEED_CONTROL_BYTES_MAYBE_DEFERRED
			; SHOULD_DEFER_CONTROL_PRINT (DATA_TOTAL_BELOW_EXPECTED) clobbers
			; HL/BC, which FEED_CONTROL_BYTES needs as its source pointer/length.
			; Preserve them so direct callers can pass HL/BC straight through.
			PUSH	HL
			PUSH	BC
			CALL	SHOULD_DEFER_CONTROL_PRINT
			POP	BC
			POP	HL
			JR	NC,.NORMAL
			LD	A,1
			LD	(CONTROL_PRINT_SUPPRESS),A
			CALL	FEED_CONTROL_BYTES
			XOR	A
			LD	(CONTROL_PRINT_SUPPRESS),A
			RET
.NORMAL
			JP	FEED_CONTROL_BYTES

SHOULD_DEFER_CONTROL_PRINT
		LD	A,(LIST_FLAG)
		AND	A
		JR	Z,.NOT_LIST
		; During LIST/NLST, 226 can overtake queued data-link +IPD blocks.
		; The data link is already open while waiting for 150, therefore use
		; DATA_OPEN as well as TRANSFER_ACTIVE. This covers an immediate
		; 150+226 control burst before RECV_DATA_TRANSFER starts.
		LD	A,(TRANSFER_ACTIVE)
		AND	A
		JR	NZ,.DEFER
		LD	A,(DATA_OPEN)
		AND	A
		JR	Z,.NOT_LIST
.DEFER
		SCF
			RET
.NOT_LIST
			LD	A,(DATA_EXPECTED_SEEN)
			AND	A
			RET	Z
			JP	DATA_TOTAL_BELOW_EXPECTED

DATA_TOTAL_BELOW_EXPECTED
			LD	HL,DATA_EXPECTED+3
			LD	DE,DATA_TOTAL+3
			LD	B,4
.CMP
			LD	A,(DE)
			CP	(HL)
			RET	NZ
			DEC	DE
			DEC	HL
			DJNZ	.CMP
			OR	A
			RET

; ------------------------------------------------------
; Print FTP data as console text.
; In: HL - data, BC - length.
; ------------------------------------------------------
PRINT_BUFFER
		LD	A,B
		OR	C
		RET	Z
		CALL	MATCH_DATA_CLOSED_TOKEN
		JR	C,.NOT_CLOSED
		LD	A,1
		LD	(DATA_CLOSE_SEEN),A
		RET
.NOT_CLOSED
		LD	A,(HL)
		INC	HL
		DEC	BC
		CP	13
		JR	Z,PRINT_BUFFER
		CP	10
		JR	NZ,.CHAR
		LD	A,13
		CALL	PUT_CHAR
		LD	A,10
		JR	.PUT
.CHAR
		CP	32
		JR	NC,.PUT
		LD	A,'.'
.PUT
		CALL	PUT_CHAR
		JR	PRINT_BUFFER

WRITE_DATA_BUFFER
		LD	A,B
		OR	C
		RET	Z
		CALL	MATCH_DATA_CLOSED_TOKEN
		JR	C,.WRITE
		LD	A,1
		LD	(DATA_CLOSE_SEEN),A
		RET
.WRITE
		CALL	CLAMP_WRITE_LEN
		LD	A,B
		OR	C
		RET	Z
		LD	A,(HOLD_MODE)
		AND	A
		JR	NZ,.HOLD
		PUSH	BC
		LD	D,B
		LD	E,C
		LD	A,(OUT_FH)
		LD	C,DSS_WRITE
		RST	DSS
		POP	BC
		RET	C
		CALL	ADD_DATA_TOTAL
		; Early data handled during the control-reply wait: size unknown, so
		; skip the render (would show "?KB" and the 150 reply would glue onto
		; it). Bytes are still written/counted; progress resumes once the size
		; is known in RECV_DATA_TRANSFER.
		LD	A,(PROGRESS_SUPPRESS)
		AND	A
		JR	NZ,.NO_PROGRESS
		CALL	PROGRESS_TICK
.NO_PROGRESS
		XOR	A
		RET
.HOLD
		; Retain-tail: bytes are already at RECV_BUFFER+HOLD_LEN (HL==RECV_DEST).
		; Account them and defer the DSS_WRITE to FTP_FLUSH_HOLD after close.
		LD	HL,(HOLD_LEN)
		ADD	HL,BC
		LD	(HOLD_LEN),HL
		CALL	ADD_DATA_TOTAL
		; No progress render in retain-tail mode: TPUT.PROGRESS would drop RTS
		; for the render, and this last-margin window must keep RTS asserted so
		; the ESP delivers every +IPD before the FIN (tail-drop avoidance).
		XOR	A
		RET

; ------------------------------------------------------
; Enter retain-tail (hold) mode once a file download is within
; FTP_HOLD_TAIL_MARGIN bytes of the server-announced size. Called at the loop
; top before the read so the final bytes are accumulated, never written under
; an RTS-off pause. Latches HOLD_MODE; never clears it mid-transfer. No-op for
; directory listings or when the size is unknown.
; ------------------------------------------------------
FTP_UPDATE_HOLD_MODE
		LD	A,(HOLD_MODE)
		AND	A
		RET	NZ
		LD	A,(LIST_FLAG)
		AND	A
		RET	NZ
		LD	A,(DATA_EXPECTED_SEEN)
		AND	A
		RET	Z
		CALL	FTP_DATA_REMAINING
		RET	NZ				; remaining >= 65536 or already over
		LD	A,H
		OR	L
		RET	Z				; remaining 0 -> done
		EX	DE,HL				; DE = remaining
		LD	HL,FTP_HOLD_TAIL_MARGIN
		OR	A
		SBC	HL,DE				; MARGIN - remaining; CF=1 -> MARGIN < remaining
		RET	C
		LD	A,1
		LD	(HOLD_MODE),A
		LD	HL,0
		LD	(HOLD_LEN),HL
		RET

; ------------------------------------------------------
; remaining = DATA_EXPECTED - DATA_TOTAL (32-bit).
; Out: if high word 0 and EXPECTED>=TOTAL: Z=1, HL=remaining low word.
;      otherwise NZ. Trashes A,BC,DE.
; ------------------------------------------------------
FTP_DATA_REMAINING
		OR	A
		LD	HL,(DATA_EXPECTED)
		LD	DE,(DATA_TOTAL)
		SBC	HL,DE
		PUSH	HL
		LD	HL,(DATA_EXPECTED+2)
		LD	DE,(DATA_TOTAL+2)
		SBC	HL,DE
		JR	C,.NEG
		LD	A,H
		OR	L
		POP	HL
		RET
.NEG
		POP	HL
		OR	1
		RET

; ------------------------------------------------------
; Compute RECV_DEST / RECV_CAP for the next RECEIVE_ANY_LINK. In hold mode data
; is appended at RECV_BUFFER+HOLD_LEN. In stream mode it overwrites from the
; start, but the capacity is clamped so neither the first read nor
; ACCUMULATE_DATA_BURST crosses into the final FTP_HOLD_TAIL_MARGIN bytes.
; ------------------------------------------------------
FTP_SETUP_RECV_DEST
		LD	A,(HOLD_MODE)
		AND	A
		JR	Z,.STREAM
		LD	HL,RECV_BUFFER
		LD	DE,(HOLD_LEN)
		ADD	HL,DE
		LD	(RECV_DEST),HL
		EX	DE,HL
		LD	HL,RECV_BUFFER+RECV_SIZE
		OR	A
		SBC	HL,DE
		LD	(RECV_CAP),HL
		RET
.STREAM
		LD	HL,RECV_BUFFER
		LD	(RECV_DEST),HL
		LD	HL,RECV_SIZE
		LD	(RECV_CAP),HL
		LD	A,(LIST_FLAG)
		AND	A
		RET	NZ
		LD	A,(DATA_EXPECTED_SEEN)
		AND	A
		RET	Z
		CALL	FTP_DATA_REMAINING
		RET	NZ				; remaining >= 65536 -> full buffer
		LD	DE,FTP_HOLD_TAIL_MARGIN
		OR	A
		SBC	HL,DE
		RET	C				; remaining < MARGIN -> next loop holds
		RET	Z				; remaining == MARGIN -> next loop holds
		; allowed = HL = remaining - MARGIN; cap = min(RECV_SIZE, allowed)
		LD	DE,RECV_SIZE
		PUSH	HL
		OR	A
		SBC	HL,DE
		POP	HL				; HL = allowed
		RET	NC				; allowed >= buffer -> keep full cap
		LD	(RECV_CAP),HL
		RET

; ------------------------------------------------------
; Write any retained tail (HOLD_LEN bytes from RECV_BUFFER) to the output file
; and leave hold mode. CF=1 on a DSS_WRITE error.
; ------------------------------------------------------
FTP_FLUSH_HOLD
		LD	A,(HOLD_MODE)
		AND	A
		RET	Z
		LD	BC,(HOLD_LEN)
		LD	A,B
		OR	C
		JR	Z,.CLEAR
		LD	HL,RECV_BUFFER
		LD	D,B
		LD	E,C
		LD	A,(OUT_FH)
		LD	C,DSS_WRITE
		RST	DSS
		RET	C
.CLEAR
		XOR	A
		LD	(HOLD_MODE),A
		LD	HL,0
		LD	(HOLD_LEN),HL
		XOR	A
		RET

CLAMP_WRITE_LEN
		LD	A,(DATA_EXPECTED_SEEN)
		AND	A
		RET	Z
		PUSH	DE,HL
		LD	HL,(DATA_EXPECTED)
		LD	DE,(DATA_TOTAL)
		OR	A
		SBC	HL,DE
		LD	(DATA_REMAIN),HL
		LD	HL,(DATA_EXPECTED+2)
		LD	DE,(DATA_TOTAL+2)
		SBC	HL,DE
		LD	(DATA_REMAIN+2),HL
		JR	C,.NONE
		LD	A,H
		OR	L
		JR	NZ,.DONE
		LD	HL,(DATA_REMAIN)
		LD	A,H
		OR	L
		JR	Z,.NONE
		PUSH	HL
		OR	A
		SBC	HL,BC
		POP	HL
		JR	C,.TRUNCATE
		JR	Z,.EXACT
		JR	.DONE
.TRUNCATE
		LD	B,H
		LD	C,L
.EXACT
		LD	A,1
		LD	(DATA_CLOSE_SEEN),A
		JR	.DONE
.NONE
		LD	BC,0
		LD	A,1
		LD	(DATA_CLOSE_SEEN),A
.DONE
		POP	HL,DE
		RET

ADD_DATA_TOTAL
			LD	HL,(DATA_TOTAL)
			ADD	HL,BC
			LD	(DATA_TOTAL),HL
			RET	NC
			LD	HL,(DATA_TOTAL+2)
			INC	HL
			LD	(DATA_TOTAL+2),HL
			RET

VERIFY_DATA_SIZE
			LD	A,(LIST_FLAG)
			AND	A
			RET	NZ
			LD	A,(DATA_EXPECTED_SEEN)
			AND	A
			RET	Z
			LD	HL,DATA_EXPECTED
			LD	DE,DATA_TOTAL
			LD	B,4
.CMP
			LD	A,(DE)
			CP	(HL)
			JR	NZ,.MISMATCH
			INC	DE
			INC	HL
			DJNZ	.CMP
			XOR	A
			RET
.MISMATCH
			PRINT	WCOMMON.LINE_END
			PRINTLN	MSG_INCOMPLETE
			LD	A,RES_RS_TIMEOUT
			SCF
			RET

MATCH_DATA_CLOSED_TOKEN
		PUSH	HL
		PUSH	BC
		LD	A,B
		AND	A
		JR	NZ,.NO
		LD	A,C
		CP	DATA_CLOSED_LEN
		JR	NZ,.NO
		LD	DE,DATA_CLOSED_TOKEN
		LD	B,DATA_CLOSED_LEN
.NEXT
		LD	A,(DE)
		CP	(HL)
		JR	NZ,.NO
		INC	DE
		INC	HL
		DJNZ	.NEXT
		POP	BC
		POP	HL
		AND	A
		RET
.NO
		POP	BC
		POP	HL
		SCF
		RET

BUILD_PASV_ENDPOINT
		LD	HL,PASV_HOST_BUFF
		LD	A,(PASV_H1)
		CALL	APPEND_U8_TO_HL
		LD	A,'.'
		CALL	APPEND_CHAR_HL
		LD	A,(PASV_H2)
		CALL	APPEND_U8_TO_HL
		LD	A,'.'
		CALL	APPEND_CHAR_HL
		LD	A,(PASV_H3)
		CALL	APPEND_U8_TO_HL
		LD	A,'.'
		CALL	APPEND_CHAR_HL
		LD	A,(PASV_H4)
		CALL	APPEND_U8_TO_HL
		XOR	A
		LD	(HL),A

		LD	A,(PASV_P1)
		LD	L,A
		LD	H,0
		ADD	HL,HL
		ADD	HL,HL
		ADD	HL,HL
		ADD	HL,HL
		ADD	HL,HL
		ADD	HL,HL
		ADD	HL,HL
		ADD	HL,HL
		LD	A,(PASV_P2)
		LD	E,A
		LD	D,0
		ADD	HL,DE
		LD	DE,PASV_PORT_BUFF
		CALL	UTIL.UTOA
		RET

OPEN_INPUT_FILE
		PRINT MSG_INPUT_FILE
		PRINT PATH_BUFF
		PRINT WCOMMON.LINE_END
		LD	HL,PATH_BUFF
		LD	A,FM_READ
		LD	C,DSS_OPEN_FILE
		RST	DSS
		RET	C
		LD	(OUT_FH),A
		; Capture the file size into DATA_EXPECTED so SEND_DATA_TRANSFER can
		; render KB/KB upload progress (same as download). Seek to end for the
		; size, then rewind to the start before the first read.
		LD	B,SEEK_END
		LD	HL,0
		LD	IX,0
		LD	C,DSS_MOVE_FP
		RST	DSS				; HL:IX = size (HL high, IX low)
		LD	(DATA_EXPECTED),IX
		LD	(DATA_EXPECTED+2),HL
		LD	A,1
		LD	(DATA_EXPECTED_SEEN),A
		LD	A,(OUT_FH)
		LD	B,0				; whence 0 = SEEK_SET -> rewind
		LD	HL,0
		LD	IX,0
		LD	C,DSS_MOVE_FP
		RST	DSS
		XOR	A
		LD	(OUTPUT_ABORTED),A
		RET

OPEN_OUTPUT_FILE
		XOR	A
		LD	(RESUME_MODE),A
		PRINT MSG_OUTPUT_FILE
		PRINT OUT_FILE
		PRINT WCOMMON.LINE_END
		LD	HL,OUT_FILE
		LD	A,FA_READONLY
		LD	C,DSS_OPEN_FILE
		RST	DSS
		JR	C,.CREATE			; does not exist -> fresh download
		LD	C,DSS_CLOSE_FILE
		RST	DSS
		LD	A,(FORCE_OVERWRITE)
		AND	A
		JR	NZ,.DELETE			; -y/-f forces overwrite
		LD	A,(FORCE_RESUME)
		AND	A
		JR	NZ,.RESUME			; -r forces resume (append)
		CALL	CONFIRM_EXISTING		; A = 'R' / 'O' / 'C'
		CP	'R'
		JR	Z,.RESUME
		CP	'O'
		JR	Z,.DELETE
		JR	.ABORT				; cancel
.RESUME
		; Reopen read/write, seek to end, seed DATA_TOTAL with the current size.
		LD	HL,OUT_FILE
		LD	A,0				; FileMode RW
		LD	C,DSS_OPEN_FILE
		RST	DSS
		JR	C,.CREATE			; cannot reopen -> fresh
		LD	(OUT_FH),A
		LD	A,(OUT_FH)
		LD	B,SEEK_END
		LD	HL,0
		LD	IX,0
		LD	C,DSS_MOVE_FP
		RST	DSS				; HL:IX = size (HL high, IX low)
		LD	(DATA_TOTAL),IX
		LD	(DATA_TOTAL+2),HL
		LD	A,1
		LD	(RESUME_MODE),A
		XOR	A
		LD	(OUTPUT_ABORTED),A
		RET
.DELETE
		LD	HL,OUT_FILE
		LD	C,DSS_DELETE
		RST	DSS
.CREATE
		LD	HL,OUT_FILE
		LD	A,FA_ARCHIVE
		LD	C,DSS_CREATE_OVERWRITE
		RST	DSS
		RET	C
		LD	(OUT_FH),A
		XOR	A
		LD	(OUTPUT_ABORTED),A
		RET
.ABORT
		LD	A,1
		LD	(OUTPUT_ABORTED),A
		SCF
		RET

; Ask about an existing output file. Returns A = 'R' resume / 'O' overwrite /
; 'C' cancel. Y=overwrite, N/Esc=cancel for familiarity.
CONFIRM_EXISTING
		PRINT	MSG_OVERWRITE_PRE
		PRINT	OUT_FILE
		PRINT	MSG_OVERWRITE_POST
.ASK
		; Drop the Enter that launched the command so WAITKEY blocks for a
		; fresh choice instead of consuming the leftover.
		LD	C,DSS_KCLEAR
		RST	DSS
		LD	C,DSS_WAITKEY
		RST	DSS
		PUSH	AF
		LD	C,DSS_PUTCHAR
		RST	DSS
		LD	A,13
		LD	C,DSS_PUTCHAR
		RST	DSS
		LD	A,10
		LD	C,DSS_PUTCHAR
		RST	DSS
		POP	AF
		CP	'R'
		JR	Z,.RES
		CP	'r'
		JR	Z,.RES
		CP	'O'
		JR	Z,.OVR
		CP	'o'
		JR	Z,.OVR
		CP	'Y'
		JR	Z,.OVR
		CP	'y'
		JR	Z,.OVR
		CP	'C'
		JR	Z,.CAN
		CP	'c'
		JR	Z,.CAN
		CP	'N'
		JR	Z,.CAN
		CP	'n'
		JR	Z,.CAN
		CP	0x1B
		JR	Z,.CAN
		JR	.ASK
.RES
		LD	A,'R'
		RET
.OVR
		LD	A,'O'
		RET
.CAN
		LD	A,'C'
		RET

CLOSE_OUTPUT_FILE
		LD	A,(OUT_FH)
		CP	NO_HANDLE
		RET	Z
		LD	C,DSS_CLOSE_FILE
		RST	DSS
		RET	C
		LD	A,NO_HANDLE
		LD	(OUT_FH),A
		XOR	A
		RET

CLOSE_OUTPUT_FILE_IGNORE
		CALL	CLOSE_OUTPUT_FILE
		XOR	A
		RET

APPEND_U8_TO_HL
		PUSH	HL
		LD	L,A
		LD	H,0
		; PASV_PORT_BUFF is not assigned until BUILD_PASV_ENDPOINT finishes
		; assembling the host, so it can be used as UTOA's short scratch here.
		LD	DE,PASV_PORT_BUFF
		CALL	UTIL.UTOA
		POP	HL
		LD	DE,PASV_PORT_BUFF
		JP	APPEND_STR

APPEND_CHAR_HL
		LD	(HL),A
		INC	HL
		RET

CLEANUP_TCP
		CALL	CLOSE_OUTPUT_FILE_IGNORE
		LD	A,(DATA_OPEN)
		AND	A
		JR	Z,.CONTROL
		LD	A,DATA_LINK
		CALL	TCP.CLOSE_LINK
		XOR	A
		LD	(DATA_OPEN),A
.CONTROL
		LD	A,(CONTROL_OPEN)
		AND	A
		RET	Z
		LD	A,CONTROL_LINK
		CALL	TCP.CLOSE_LINK
		XOR	A
		LD	(CONTROL_OPEN),A
		RET

SEND_CMD
		LD	DE,WIFI.RS_BUFF
		LD	BC,DEFAULT_TIMEOUT
		CALL	WIFI.UART_TX_CMD
		AND	A
		RET	Z
		ADD	A,'0'
		LD	(MSG_ERROR_NO),A
		PRINTLN MSG_COMM_ERROR
		LD	B,3
		JP	WCOMMON.EXIT

SEND_CMD_IGNORE
		LD	DE,WIFI.RS_BUFF
		LD	BC,DEFAULT_TIMEOUT
		CALL	WIFI.UART_TX_CMD
		RET

SEND_CMD_RECOVER
		PUSH	HL
		CALL	WCOMMON.SYNC_ESP_COMMAND
		POP	HL
		JP	SEND_CMD

APPEND_STR
		LD	A,(DE)
		AND	A
		RET	Z
		LD	(HL),A
		INC	HL
		INC	DE
		JR	APPEND_STR

APPEND_IX_STR
		LD	A,(IX+0)
		AND	A
		RET	Z
		LD	(HL),A
		INC	HL
		INC	IX
		JR	APPEND_IX_STR

PUT_CHAR
		PUSH	BC,HL
		LD	C,DSS_PUTCHAR
		RST	DSS
		POP	HL,BC
		RET

; Print the exact UART error latch as well as the friendly explanation. This
; distinguishes a real OE (bit 1) from PE/FE/BI or FIFO error (bit 7) on the
; next real-hardware report instead of collapsing every condition to "overrun".
PRINT_UART_OVERRUN
		LD	A,(TCP.LSR_ACCUM)
		LD	C,A
		LD	DE,MSG_UART_LSR_ACC_HEX
		CALL	UTIL.HEXB
		LD	A,(TCP.LAST_LSR)
		LD	C,A
		LD	DE,MSG_UART_LSR_LAST_HEX
		CALL	UTIL.HEXB
		PRINTLN MSG_UART_LSR
		LD	A,(TCP.LSR_ACCUM)
		AND	LSR_OE
		JR	NZ,.OVERRUN
		LD	A,(TCP.LSR_ACCUM)
		AND	LSR_PE | LSR_FE | LSR_BI
		JR	NZ,.FRAMING
		PRINTLN MSG_UART_RX_ERROR
		RET
.OVERRUN
		PRINTLN MSG_UART_OVERRUN
		RET
.FRAMING
		PRINTLN MSG_UART_FRAMING
		RET

CLEAR_BSS
		LD	HL,FTP_BSS_BASE
		LD	DE,FTP_BSS_BASE+1
		LD	BC,FTP_BSS_END-FTP_BSS_BASE-1
		; LDIR with BC=0 wraps and copies 65536 bytes on Z80. FTP keeps its
		; large runtime strings in WIN2, so the remaining WIN1 BSS can be empty.
		LD	A,B
		OR	C
		RET	Z
		XOR	A
		LD	(HL),A
		LDIR
		RET

INIT_RUNTIME_PAGE
		; Two pages from one block: logical 0 -> WIN2 (RECV_BUFFER, hot path),
		; logical 1 -> the cold overlay. Map the overlay page in first and copy
		; the overlay image (loaded in WIN1 right past the code) into it, then
		; map the buffer page for the hot path. GETMEM returns block id in A.
		LD	B,2
		LD	C,DSS_GETMEM
		RST	DSS
		RET	C
		LD	(RUNTIME_BLOCK),A
		LD	B,1
		LD	C,DSS_SETWIN2
		RST	DSS			; WIN2 = overlay page
		LD	HL,OVERLAY_SRC
		LD	DE,OVERLAY_RUN
		LD	BC,OVERLAY_SIZE
		LDIR				; load the cold overlay into its page
		LD	A,(RUNTIME_BLOCK)
		LD	B,0
		LD	C,DSS_SETWIN2
		RST	DSS			; WIN2 = RECV_BUFFER page (hot default)
		OR	A			; CF=0
		RET

; ------------------------------------------------------
; Run a cold routine from the WIN2 overlay page.
;   In: HL = overlay routine address (OVERLAY_RUN-based).
; Saves the current WIN2 page (RECV_BUFFER), maps the overlay, calls the
; routine (which returns with RET), then restores WIN2 to the buffer page.
; The overlay routine must NOT touch RECV_BUFFER and must copy out any data
; the caller still needs after return (WIN2 reverts to the buffer page).
; ------------------------------------------------------
CALL_OVERLAY
		IN	A,(PAGE2)		; save current WIN2 MMU page (buffer)
		PUSH	AF
		PUSH	HL
		LD	A,(RUNTIME_BLOCK)
		LD	B,1
		LD	C,DSS_SETWIN2		; WIN2 = overlay page
		RST	DSS
		POP	HL
		LD	DE,.DONE
		PUSH	DE			; return address for the overlay routine
		JP	(HL)
.DONE
		POP	AF
		OUT	(PAGE2),A		; restore WIN2 = buffer page
		RET

RUNTIME_BLOCK	DB 0
; Result of OVL_ESP_SOFT_RECOVER (run via CALL_OVERLAY, which cannot return a
; value in registers). 1 = ESP responsive, 0 = AT never answered. Code-segment
; var (not WIN2 BSS) so the overlay routine can write it and the caller read it.
SOFT_RECOVER_OK	DB 0

INIT_MEMORY_ERROR
		LD	B,3
		LD	C,DSS_EXIT
		RST	DSS

MSG_START
		DB "FTP "
		PACKAGE_VERSION_TAG
		DB " - passive FTP client for SprinterESP"
		DB 0
		; MSG_USAGE moved to the WIN2 cold overlay (see OVL_MSG_USAGE below).
MSG_WIFI_FOUND
		DB "Sprinter-WiFi found in ISA#"
MSG_SLOT_NO
		DB "n slot.",0
MSG_WIFI_NOT_FOUND
		DB "Sprinter-WiFi not found!",0
MSG_UART_READY
		DB "UART initialized.",0
MSG_CONNECTING
		DB "Connecting to ",0
MSG_COLON
		DB ":",0
MSG_LOGIN
		DB "Logging in.",0
MSG_BINARY
		DB "Setting binary transfer mode.",0
MSG_PASV
		DB "Requesting passive endpoint.",0
MSG_PASV_ENDPOINT
		DB "Passive endpoint: ",0
MSG_OPEN_DATA
		DB "Opening data link to ",0
MSG_LIST
		DB "Requesting directory listing.",0
MSG_LISTING
		DB "Directory listing:",0
MSG_RETR
		DB "Requesting file download.",0
MSG_STOR
		DB "Requesting file upload.",0
MSG_DOWNLOADING
		DB "Downloading to ",0
MSG_UPLOADING
		DB "Uploading ",0
MSG_OUTPUT_FILE
		DB "Output file: ",0
MSG_INPUT_FILE
		DB "Input file: ",0
MSG_DONE
		DB "FTP done.",0
MSG_COMM_ERROR
		DB "ESP communication error #"
MSG_ERROR_NO
		DB "n!",0
MSG_NET_ERROR
		DB "Network/ESP error #"
MSG_NET_ERROR_NO
		DB "n!",0
; Plain-language hints for the RES_* codes, printed under "Network/ESP error #N".
; Indexed by code; a 0 entry means "no hint for this code".
NET_REASON_COUNT	EQU 7
NET_REASON_TABLE
		DW 0			; 0 RES_OK (not an error)
		DW MSG_NETR_ERR		; 1 RES_ERROR
		DW MSG_NETR_FAIL	; 2 RES_FAIL
		DW MSG_NETR_TXTO	; 3 RES_TX_TIMEOUT
		DW MSG_NETR_RXTO	; 4 RES_RS_TIMEOUT
		DW 0			; 5 RES_CONNECTED
		DW MSG_NETR_NOCONN	; 6 RES_NOT_CONN
MSG_NETR_ERR
		DB "Could not open the connection: host down or refused, wrong",13,10
		DB "address/DNS, or Wi-Fi not up (run NETUP).",0
MSG_NETR_FAIL
		DB "The network operation failed.",0
MSG_NETR_TXTO
		DB "Sprinter-WiFi (ESP) did not respond - check the card and cabling.",0
MSG_NETR_RXTO
		DB "No reply from the server - it may be down or too slow (timeout).",0
MSG_NETR_NOCONN
		DB "The connection was closed before the transfer finished.",0
MSG_FTP_ERROR
		DB "FTP server returned error: ",0
MSG_UART_OVERRUN
		DB "UART overrun. Try lower BAUD or check RTS/CTS flow control.",0
MSG_UART_FRAMING
		DB "UART framing/parity/break error. Check baud and UART session state.",0
MSG_UART_RX_ERROR
		DB "UART receiver FIFO error. Received block was discarded.",0
MSG_UART_LSR
		DB "UART LSR accumulated=0x"
MSG_UART_LSR_ACC_HEX
		DB "xx, last=0x"
MSG_UART_LSR_LAST_HEX
		DB "xx",0
MSG_FILE_ERROR
			DB "File create/read/write/close error.",0
MSG_ABORTED
			DB "Aborted by user.",0
MSG_OVERWRITE_PRE
			DB "Local file '",0
MSG_OVERWRITE_POST
			DB "' exists. [R]esume / [O]verwrite / [C]ancel? ",0
MSG_INCOMPLETE
			DB "Downloaded size does not match server size.",0
MSG_NO_REST
			DB "Server rejected REST; resume not supported. Re-run and choose Overwrite.",0
MSG_AUTO_RESUME
			DB "Data link closed early; resuming...",0

CMD_AT
		DB "AT",13,10,0
CMD_ECHO_OFF
		DB "ATE0",13,10,0
CMD_CIPMUX_1
		DB "AT+CIPMUX=1",13,10,0
		; Commands are emitted in the universal image but reached only after the
		; selected NET_ESP_FW profile proves ESP-AT 2.2.2 support.
CMD_SYSSTORE_VOLATILE
		DB "AT+SYSSTORE=0",13,10,0
CMD_CIPRECVMODE_1
		DB "AT+CIPRECVMODE=1",13,10,0
CMD_CIPRECVMODE_0
		DB "AT+CIPRECVMODE=0",13,10,0
CMD_CIPDINFO_0
		DB "AT+CIPDINFO=0",13,10,0
CMD_CRLF
		DB 13,10,0

DEFAULT_PORT
		DB "21",0
DEFAULT_USER
		DB "anonymous",0
DEFAULT_PASS
		DB "anonymous@",0
FTP_USER_PREFIX
		DB "USER ",0
FTP_PASS_PREFIX
		DB "PASS ",0
FTP_TYPE_I
		DB "TYPE I",13,10,0
FTP_PASV
		DB "PASV",13,10,0
FTP_LIST
		DB "LIST",13,10,0
FTP_NLST
		DB "NLST",13,10,0
FTP_LIST_PREFIX
		DB "LIST ",0
FTP_NLST_PREFIX
		DB "NLST ",0
FTP_RETR_PREFIX
		DB "RETR ",0
FTP_SIZE_PREFIX
		DB "SIZE ",0
FTP_STOR_PREFIX
		DB "STOR ",0
FTP_REST_PREFIX
		DB "REST ",0
FTP_QUIT
		DB "QUIT",13,10,0
DATA_CLOSED_TOKEN
		DB "1,CLOSED"

SWITCH_LIST_DASH
		DB "-l",0
SWITCH_LIST_SLASH
		DB "/l",0
SWITCH_NLST_DASH
		DB "-n",0
SWITCH_NLST_SLASH
		DB "/n",0
SWITCH_PUT
		DB "PUT",0
SWITCH_USER_DASH
		DB "-u",0
SWITCH_USER_SLASH
		DB "/u",0
SWITCH_PASS_DASH
		DB "-p",0
SWITCH_PASS_SLASH
		DB "/p",0
SWITCH_OUTPUT_DASH
		DB "-o",0
SWITCH_OUTPUT_SLASH
		DB "/o",0
SWITCH_YES_DASH
		DB "-y",0
SWITCH_YES_SLASH
		DB "/y",0
SWITCH_FORCE_DASH
		DB "-f",0
SWITCH_FORCE_SLASH
		DB "/f",0
SWITCH_RESUME_DASH
		DB "-r",0
SWITCH_RESUME_SLASH
		DB "/r",0
SWITCH_DOTS_DASH
		DB "-d",0
SWITCH_DOTS_SLASH
		DB "/d",0
SWITCH_HELP_Q_SLASH
		DB "/?",0
SWITCH_HELP_Q_DASH
		DB "-?",0
SWITCH_HELP_H_SLASH
		DB "/h",0
SWITCH_HELP_H_DASH
		DB "-h",0

ARG_LEN
		DB 0
HELP_REQUESTED
		DB 0
LIST_MODE
		DB 0
LIST_FLAG
		DB 0
PUT_MODE
		DB 0
USER_GIVEN
		DB 0
PASS_GIVEN
		DB 0
CONTROL_OPEN
			DB 0
DATA_OPEN
			DB 0
DATA_CLOSE_SEEN
			DB 0
DATA_BYTES_SEEN
			DB 0
FINAL_REPLY_SEEN
			DB 0
TRANSFER_ACTIVE
			DB 0
OUT_FH
		DB NO_HANDLE
CMDLINE_PTR
		DW 0				; arg buffer ptr captured from IX at entry
FORCE_OVERWRITE
		DB 0
FORCE_RESUME
		DB 0
DOTS_FLAG
		DB 0				; 1 = -d: one dot per write, no KB counter
OUTPUT_ABORTED
		DB 0
DATA_EXPECTED_SEEN
		DB 0
DATA_EXPECTED
		DD 0
DATA_TOTAL
		DD 0
DATA_REMAIN
		DD 0
; Retain-tail (hold) mode state for file downloads.
HOLD_MODE
		DB 0
HOLD_LEN
		DW 0
; FTP REST-resume state and 32-bit decimal scratch for the REST offset.
RESUME_MODE
		DB 0
RESUME_ATTEMPTS
		DB 0
SESSION_BASE
		DS 4,0
U32_WORK
		DS 4,0
U32_DIGITS
		DS 12,0
RECV_DEST
		DW 0
RECV_CAP
		DW 0
U32_DIGIT
		DB 0
SIZE_DIGITS
		DB 0
U32_TMP
		DD 0
DATA_ACCUM_LEN
		DW 0
BURST_DEST
		DW 0
PENDING_CONTROL_PTR
		DW 0
PENDING_CONTROL_LEN
		DW 0
PENDING_CONTROL_SEEN
		DB 0
CONTROL_PRINT_SUPPRESS
		DB 0
; Set while RECV_CONTROL_REPLY writes early data-link bytes (file bytes that
; beat the 150 reply). The transfer size is not yet known, so a progress render
; here would show a bogus "?KB" total and, lacking a trailing newline, glue the
; 150 reply onto it. WRITE_DATA_BUFFER skips PROGRESS_TICK when this is set,
; under -d as well: a dot there would land in front of the 150 reply too.
PROGRESS_SUPPRESS
		DB 0
DEFERRED_CONTROL_SEEN
		DB 0
CONTROL_TIMEOUT
		DW 0
CMD_LEN
			DW 0
LINE_LEN
		DB 0
REPLY_DONE
		DB 0
REPLY_FIRST
		DB 0
REPLY_CODE_1
		DB 0
REPLY_CODE_2
		DB 0
REPLY_CODE_3
		DB 0
PASV_H1
		DB 0
PASV_H2
		DB 0
PASV_H3
		DB 0
PASV_H4
		DB 0
PASV_P1
		DB 0
PASV_P2
		DB 0

		ENDMODULE

		; FTP reads NET_BAUD/NET_ESP_* from the NETUP environment and never
		; loads NET.CFG. Do not reserve a dead 1.5 KiB parser buffer in WIN1.
		DEFINE	NETCFG_SESSION_ONLY
		INCLUDE "netcfg_lib.asm"
		DEFINE WCOMMON_USE_NETCFG
		INCLUDE "wcommon.asm"
		INCLUDE "dss_error.asm"
		INCLUDE "isa.asm"
		INCLUDE "esp_tcp.asm"
		INCLUDE "esp_tcp_multi.asm"
		INCLUDE "tput_lib.asm"
		; esplib.asm MUST be last: it ends with the RS_BUFF label that anchors
		; the runtime receive buffer and all BSS. Any include after it would be
		; overlaid by the ESP receive buffer.
		; Universal/2.2.1 FTP uses the field-proven active trigger-8 transport.
		; A forced 2.2.2 build retains its trigger-4/passive receive backend.
		IFNDEF	ESP_AT_FORCE_222
		DEFINE	WIFI_STABLE_ACTIVE_RX
		ENDIF
		INCLUDE "esplib.asm"

		MODULE MAIN

; ------------------------------------------------------
; Cold WIN2 overlay image. Emitted here (DSS loads it into WIN1 just past the
; code) but assembled to RUN at OVERLAY_RUN (0x8000). INIT_RUNTIME_PAGE copies
; it into the overlay page before CLEAR_BSS, after which this WIN1 area is
; reused as BSS. Only rarely-used (cold) code/data belongs here so WIN1 stays
; free for the hot path; the receive/flush path never maps the overlay.
; ------------------------------------------------------
OVERLAY_SRC
		DISP	OVERLAY_RUN
OVL_BASE
OVL_SHOW_HELP
		PRINTLN OVL_MSG_USAGE
		RET
OVL_MSG_USAGE
		DB "Usage: FTP host[:port] [file | PUT local | path] [opts]",13,10
		DB "  -o name   out (get) / remote (put) name",13,10
		DB "  -u user -p pass  login",13,10
		DB "  -y, -f    overwrite",13,10
		DB "  -r        resume (append)",13,10
		DB "  -l, -n    list (LIST / NLST)",13,10
		DB "  -d        dot progress instead of the KB counter",13,10
		DB "  /?        help",0

; Quiet recovery after a mid-transfer error, WITHOUT a hardware reset (which
; would drop the Wi-Fi join and force a manual NETUP). The truncated transfer
; leaves async backlog (tail +IPD, CLOSED, "busy") in the UART that buries the
; AT reply, so a naive AT probe times out and looks "dead". Steps:
;   1. drain the UART to idle so the next reply is clean;
;   2. probe AT (short timeout) with drain+delay between tries;
;   3. once it answers: restore CIPMUX=1 and close the stale sockets.
; The caller then re-logins. If Wi-Fi was actually lost, that re-login's
; CIPSTART returns #1 and NET_ERROR_EXIT already prints the "...Wi-Fi not up
; (run NETUP)" hint - so no separate Wi-Fi probe is needed here.
; Cold-only and RECV_BUFFER-free, so it runs from the WIN2 overlay; CALL_OVERLAY
; clobbers A/flags on return, so the result is passed back in SOFT_RECOVER_OK
; (1 = ESP responsive, caller re-logins; 0 = AT never answered, caller exits).
OVL_ESP_SOFT_RECOVER
		LD	B,FTP_SOFT_AT_RETRIES
.AT_LOOP
		PUSH	BC
		CALL	ESP_DRAIN_RX
		LD	HL,CMD_AT
		LD	DE,WIFI.RS_BUFF
		LD	BC,FTP_SOFT_AT_TIMEOUT
		CALL	WIFI.UART_TX_CMD
		POP	BC
		AND	A
		JR	Z,.ALIVE
		PUSH	BC
		LD	HL,FTP_SOFT_AT_DELAY
		CALL	UTIL.DELAY
		POP	BC
		DJNZ	.AT_LOOP
		XOR	A
		LD	(SOFT_RECOVER_OK),A		; 0 -> never answered, report failure
		RET
.ALIVE
		; Command interface is back. Restore the expected mode and clear any
		; half-open sockets the wedge left behind (errors ignored - the link
		; may already be gone).
		LD	HL,CMD_CIPMUX_1
		CALL	SEND_CMD_IGNORE
		IFDEF	ESP_AT_FORCE_222
		LD	HL,CMD_CIPRECVMODE_1
		CALL	SEND_CMD_IGNORE
		LD	HL,CMD_CIPDINFO_0
		CALL	SEND_CMD_IGNORE
		ENDIF
		LD	A,DATA_LINK
		CALL	TCP.CLOSE_LINK
		LD	A,CONTROL_LINK
		CALL	TCP.CLOSE_LINK
		CALL	ESP_DRAIN_RX			; swallow the CLOSED/OK replies
		LD	A,1
		LD	(SOFT_RECOVER_OK),A		; 1 -> recovered, caller re-logins
		RET

; Drain pending UART RX bytes to idle so a following command sees a clean reply.
; Asserts RTS (UART_RX_RESUME) so the ESP releases whatever it was holding, then
; reads+discards until no byte arrives within FTP_DRAIN_IDLE_MS (or the byte cap
; is hit), and resets the hardware FIFO. Trashes A,BC,DE,HL.
ESP_DRAIN_RX
		CALL	WIFI.UART_RX_RESUME
		LD	DE,FTP_DRAIN_MAX_BYTES
.LOOP
		LD	BC,FTP_DRAIN_IDLE_MS
		CALL	WIFI.UART_WAIT_RS		; CF=1 -> idle (no byte in window)
		JR	C,.DONE
		LD	HL,REG_RBR
		CALL	WIFI.UART_READ			; consume one byte, discard
		DEC	DE
		LD	A,D
		OR	E
		JR	NZ,.LOOP
.DONE
		CALL	WIFI.UART_EMPTY_RS
		RET
OVL_END
		ENT
OVERLAY_SIZE	EQU OVL_END - OVL_BASE

		ASSERT	$ < STACK_TOP - 0x0100

FTP_BSS_BASE	EQU NETCFG.NETCFG_BSS_END
; All long-lived FTP strings live in the unused tail of the DSS-allocated WIN2
; page, not in WIN1 below the stack. They are populated before use, so unlike
; state variables they require no startup clear.
FTP_WIN2_SCRATCH	EQU RECV_BUFFER + RECV_SIZE
HOST_BUFF	EQU FTP_WIN2_SCRATCH
PORT_BUFF	EQU HOST_BUFF + HOST_SIZE
USER_BUFF	EQU PORT_BUFF + PORT_SIZE
PASS_BUFF	EQU USER_BUFF + USER_SIZE
PATH_BUFF	EQU PASS_BUFF + PASS_SIZE
OUT_FILE	EQU PATH_BUFF + PATH_SIZE
ARG_BUFF	EQU OUT_FILE + OUT_SIZE
; ARG_BUFF is only used while parsing the command line; after parsing, the
; same memory becomes the FTP control command buffer.
CMD_BUFF	EQU ARG_BUFF
LINE_BUFF	EQU CMD_BUFF + CMD_SIZE
; These values are needed while no data receive is active. Keep them after the
; command-line/control strings in the WIN2 tail: starting them at FTP_WIN2_SCRATCH
; would overlap HOST_BUFF and corrupt the target while opening the control link.
DEFERRED_CONTROL_LINE	EQU LINE_BUFF + LINE_SIZE
PASV_HOST_BUFF	EQU DEFERRED_CONTROL_LINE + LINE_SIZE
PASV_PORT_BUFF	EQU PASV_HOST_BUFF + 16
; Keep CLEAR_BSS valid while all actual large buffers are in WIN2.
FTP_BSS_END	EQU FTP_BSS_BASE + 1
RECV_BUFFER	EQU WIN2_BASE
	; FTP RECV_BUFFER feeds PRINT_BUFFER/DSS_WRITE and uses allocated WIN2.
	; Stack stays at #8000 and grows downward in WIN1.
	ASSERT	FTP_BSS_END < STACK_TOP - 0x0100
		ASSERT	PASV_PORT_BUFF + 8 <= 0xC000

		ENDMODULE

		END MAIN.START
