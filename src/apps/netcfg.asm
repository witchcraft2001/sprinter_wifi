; ======================================================
; NETCFG for Sprinter ESP Network Kit
; Display parsed NET.CFG values.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000

; The Wi-Fi scan wizard needs the full AT+CWLAP listing, not just short
; OK/ERROR replies; override esplib's default 192-byte RS_BUFF the same way
; telnet.asm narrows it, just in the other direction (see esplib.asm's own
; comment at RS_BUFF_SIZE). This costs address space only, not .EXE bytes.
	DEFINE	RS_BUFF_SIZE_OVERRIDE
RS_BUFF_SIZE		EQU 2048

SCAN_TIMEOUT		EQU 15000
PROBE_TIMEOUT		EQU 1000
PROBE_TRIES		EQU 3
NETUP_BUSY_RETRIES	EQU 4
NETUP_BUSY_DELAY	EQU 500

OPT_WRITE		EQU 1
OPT_SCAN		EQU 2

WIZ_MANUAL		EQU 0			; SCAN_WIZARD/SELECT_AP result: manual SSID entry
WIZ_SSID_SET		EQU 1			; SSID chosen/kept, still prompt for PASS
WIZ_OPEN		EQU 2			; open network chosen, skip SSID and PASS prompts

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
	; DSS passes the command-line buffer pointer in IX at entry; capture it
	; before any CALL clobbers IX (load-#80 = 0x8080 is the default, not assumed).
	LD	(CMDLINE_PTR),IX
	CALL	WCOMMON.INIT_VMODE
	PRINTLN MSG_START

	CALL	NETCFG.LOAD
	JR	NC,.LOADED

	CP	E_FILE_NOT_FOUND
	JR	NZ,.DSS_ERROR
	PRINTLN MSG_NOT_FOUND
	JR	.DISPLAY

.DSS_ERROR
	CALL	DSS_ERROR.EPRINT

.LOADED
	PRINTLN MSG_LOADED

.DISPLAY
	CALL	PARSE_FLAGS
	LD	A,(OPT_FLAGS)
	AND	OPT_WRITE
	JP	NZ,WRITE_CONFIG
	LD	A,(OPT_FLAGS)
	AND	OPT_SCAN
	JP	NZ,SCAN_ONLY

DISPLAY_CONFIG
	PRINT MSG_SSID
	PRINT NETCFG.CFG_SSID
	PRINT WCOMMON.LINE_END

	PRINT MSG_PASS
	LD	A,(NETCFG.CFG_PASS)
	AND	A
	JR	Z,.PASS_EMPTY
	PRINT MSG_PASS_SET
	JR	.PASS_DONE
.PASS_EMPTY
	PRINT MSG_PASS_EMPTY
.PASS_DONE
	PRINT WCOMMON.LINE_END

	PRINT MSG_DHCP
	PRINT NETCFG.CFG_DHCP
	PRINT WCOMMON.LINE_END

	PRINT MSG_IP
	PRINT NETCFG.CFG_IP
	PRINT WCOMMON.LINE_END

	PRINT MSG_GATEWAY
	PRINT NETCFG.CFG_GATEWAY
	PRINT WCOMMON.LINE_END

	PRINT MSG_NETMASK
	PRINT NETCFG.CFG_NETMASK
	PRINT WCOMMON.LINE_END

	PRINT MSG_DNS1
	PRINT NETCFG.CFG_DNS1
	PRINT WCOMMON.LINE_END

	PRINT MSG_DNS2
	PRINT NETCFG.CFG_DNS2
	PRINT WCOMMON.LINE_END

	PRINT MSG_TZ
	PRINT NETCFG.CFG_TZ
	PRINT WCOMMON.LINE_END

	PRINT MSG_NTP
	PRINT NETCFG.CFG_NTP
	PRINT WCOMMON.LINE_END

	PRINT MSG_AUTOJOIN
	PRINT NETCFG.CFG_AUTOJOIN
	PRINT WCOMMON.LINE_END

	PRINT MSG_BAUD
	PRINT NETCFG.CFG_BAUD
	PRINT WCOMMON.LINE_END

	LD	B,0
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Scan the command line for /W, -W, /S, -S (case-insensitive, any order,
; combinable). Unknown flags/characters are silently ignored, same as before.
; Out: (OPT_FLAGS) set to the OPT_WRITE|OPT_SCAN bitmask found.
; ------------------------------------------------------
PARSE_FLAGS
	XOR	A
	LD	(OPT_FLAGS),A
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	AND	A
	RET	Z
	LD	B,A
	INC	HL
.NEXT
	LD	A,(HL)
	CP	'/'
	JR	Z,.MAYBE_FLAG
	CP	'-'
	JR	Z,.MAYBE_FLAG
.CONT
	INC	HL
	DJNZ	.NEXT
	RET
.MAYBE_FLAG
	INC	HL
	DEC	B
	JR	Z,.DONE
	LD	A,(HL)
	AND	0xDF				; fold ASCII letters to uppercase
	CP	'W'
	JR	NZ,.CHECK_S
	LD	A,(OPT_FLAGS)
	OR	OPT_WRITE
	LD	(OPT_FLAGS),A
	JR	.CONT
.CHECK_S
	CP	'S'
	JR	NZ,.CONT
	LD	A,(OPT_FLAGS)
	OR	OPT_SCAN
	LD	(OPT_FLAGS),A
	JR	.CONT
.DONE
	RET

; ------------------------------------------------------
; Interactive NET.CFG writer.
; ------------------------------------------------------
WRITE_CONFIG
	PRINTLN MSG_WRITE_MODE
	PRINTLN MSG_WRITE_WARN

	CALL	SCAN_WIZARD
	CP	WIZ_OPEN
	JR	Z,.SKIP_SSID_PASS
	CP	WIZ_SSID_SET
	JR	Z,.SKIP_SSID

	LD	HL,MSG_PROMPT_SSID
	LD	DE,NETCFG.CFG_SSID
	LD	B,NETCFG.CFG_SSID_SIZE
	CALL	READ_CONFIG_VALUE
	CALL	WARN_HASH_IN_SSID		; a scanned choice is warned about in SELECT_AP
.SKIP_SSID
	LD	HL,MSG_PROMPT_PASS
	LD	DE,NETCFG.CFG_PASS
	LD	B,NETCFG.CFG_PASS_SIZE
	CALL	READ_CONFIG_VALUE
.SKIP_SSID_PASS
	LD	HL,MSG_PROMPT_DHCP
	LD	DE,NETCFG.CFG_DHCP
	LD	B,NETCFG.CFG_FLAG_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_IP
	LD	DE,NETCFG.CFG_IP
	LD	B,NETCFG.CFG_ADDR_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_GATEWAY
	LD	DE,NETCFG.CFG_GATEWAY
	LD	B,NETCFG.CFG_ADDR_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_NETMASK
	LD	DE,NETCFG.CFG_NETMASK
	LD	B,NETCFG.CFG_ADDR_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_DNS1
	LD	DE,NETCFG.CFG_DNS1
	LD	B,NETCFG.CFG_ADDR_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_DNS2
	LD	DE,NETCFG.CFG_DNS2
	LD	B,NETCFG.CFG_ADDR_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_TZ
	LD	DE,NETCFG.CFG_TZ
	LD	B,NETCFG.CFG_TZ_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_NTP
	LD	DE,NETCFG.CFG_NTP
	LD	B,NETCFG.CFG_NTP_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_AUTOJOIN
	LD	DE,NETCFG.CFG_AUTOJOIN
	LD	B,NETCFG.CFG_FLAG_SIZE
	CALL	READ_CONFIG_VALUE

	LD	HL,MSG_PROMPT_BAUD
	LD	DE,NETCFG.CFG_BAUD
	LD	B,NETCFG.CFG_BAUD_SIZE
	CALL	READ_CONFIG_VALUE

	CALL	NETCFG.SAVE
	JP	C,DSS_ERROR.EPRINT

	PRINTLN MSG_SAVED
	JP	DISPLAY_CONFIG

; ------------------------------------------------------
; Prompt and read a line. Empty input keeps existing value.
; In: HL - prompt, DE - destination, B - destination size.
; ------------------------------------------------------
READ_CONFIG_VALUE
	PUSH	DE,BC
	PRINT_HL
	PRINT MSG_CURRENT_PREFIX
	POP	BC,DE
	PUSH	DE,BC
	EX	DE,HL
	PRINT_HL
	PRINT MSG_CURRENT_SUFFIX
	POP	BC,DE

	PUSH	DE,BC
	LD	HL,INPUT_BUFF
	LD	B,INPUT_BUFF_SIZE
	CALL	READ_LINE
	LD	A,(INPUT_BUFF)
	AND	A
	JR	Z,.KEEP
	POP	BC,DE
	LD	HL,INPUT_BUFF
	CALL	COPY_INPUT_TO_DEST
	RET
.KEEP
	POP	BC,DE
	RET

; ------------------------------------------------------
; Read line to HL, max B bytes including zero.
; ------------------------------------------------------
READ_LINE
	PUSH	HL
	POP	IX
	DEC	B
	LD	A,B
	LD	(INPUT_REMAIN),A
.NEXT
	LD	C,DSS_ECHOKEY
	RST	DSS
	CP	13
	JR	Z,.END
	CP	10
	JR	Z,.END
	LD	(IX+0),A
	INC	IX
	LD	HL,INPUT_REMAIN
	DEC	(HL)
	JR	NZ,.NEXT
.FLUSH
	LD	C,DSS_ECHOKEY
	RST	DSS
	CP	13
	JR	NZ,.FLUSH
.END
	XOR	A
	LD	(IX+0),A
	PRINT WCOMMON.LINE_END
	RET

; ------------------------------------------------------
; Copy input in HL to destination DE. B is destination size.
; ------------------------------------------------------
COPY_INPUT_TO_DEST
	DEC	B
.NEXT
	LD	A,(HL)
	AND	A
	JR	Z,.END
	LD	(DE),A
	INC	HL
	INC	DE
	DJNZ	.NEXT
.END
	XOR	A
	LD	(DE),A
	RET

; ------------------------------------------------------
; NETCFG /S: scan Wi-Fi networks and print the list, then exit.
; Exit status: 0 - ok (including an empty list); 2 - hardware not found;
; 3 - ESP/scan communication error.
; ------------------------------------------------------
SCAN_ONLY
	CALL	SCAN_BRINGUP
	JR	C,.EXIT_A
	CALL	SCAN_RUN
	AND	A
	JR	Z,.RUN_OK
	ADD	A,'0'
	LD	(MSG_SCAN_FAILED_NO),A
	PRINTLN	MSG_SCAN_FAILED
	LD	A,EXIT_NETWORK
	JR	.EXIT_A
.RUN_OK
	CALL	PRINT_AP_LIST
	XOR	A
.EXIT_A
	LD	B,A
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Bring the ESP up just enough to run AT+CWLAP: find the card, sync a plain
; UART baud (preferring the NETUP-negotiated one when a session looks live),
; then best-effort ATE0/CWMODE/CWLAPOPT. Never sends AT+UART_CUR and never
; calls WIFI.ESP_RESET - this must work whether or not NETUP ever ran.
; Out: CF=0 - ready. CF=1, A=EXIT_HARDWARE|EXIT_NETWORK - failed, a message
; has already been printed.
; ------------------------------------------------------
SCAN_BRINGUP
	CALL	ISA.ISA_RESET
	CALL	WIFI.UART_FIND
	JR	NC,.FOUND
	PRINTLN	WCOMMON.MSG_SWF_NOF
	LD	A,EXIT_HARDWARE
	SCF
	RET
.FOUND
	LD	A,(ISA.ISA_SLOT)
	ADD	A,'1'
	LD	(WCOMMON.MSG_SLOT_NO),A
	PRINTLN	WCOMMON.MSG_SWF_FOUND

	CALL	CHOOSE_BAUD_ORDER

	LD	HL,BAUD_TRY1_DIVISOR
	CALL	APPLY_UART_TRY
	JR	NC,.SYNCED
	LD	HL,BAUD_TRY2_DIVISOR
	CALL	APPLY_UART_TRY
	JR	C,.SILENT

.SYNCED
	; Best-effort setup; every result is ignored on purpose - a wizard must
	; still fall back to manual SSID entry, not abort, if any of these fail.
	LD	HL,WCOMMON.CMD_ECHO_OFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT
	LD	HL,WCOMMON.CMD_STATION_MODE
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT
	LD	HL,WCOMMON.CMD_CWLAP_OPT
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT
	XOR	A
	RET
.SILENT
	PRINTLN	MSG_ESP_SILENT
	LD	A,EXIT_NETWORK
	SCF
	RET

; ------------------------------------------------------
; Apply one UART attempt and probe it.
; In: HL - pointer to a divisor byte followed by a flow byte (0/1).
; Out: CF=0 - ESP answered at this setting; CF=1 - silent.
; ------------------------------------------------------
APPLY_UART_TRY
	LD	A,(HL)
	CALL	WIFI.UART_SET_DIVISOR
	INC	HL
	LD	A,(HL)
	AND	A
	JR	Z,.FLOW_OFF
	CALL	WIFI.UART_FLOW_ON
	JR	.INIT
.FLOW_OFF
	CALL	WIFI.UART_FLOW_OFF
.INIT
	CALL	WIFI.UART_INIT
	JP	PROBE_AT

; ------------------------------------------------------
; Pick the order of the two UART attempts. Both default to 115200/flow off.
; A published non-default NET_BAUD (with its NET_ESP_FLOW mode) is tried
; first when a NET=WIFI session is live, and second otherwise: after a
; failed NETUP the ESP may still sit at a stale NET_BAUD. With a live
; session the receive profile also follows NET_ESP_FW, as every client does.
; ------------------------------------------------------
CHOOSE_BAUD_ORDER
	LD	A,8
	LD	(BAUD_TRY1_DIVISOR),A
	LD	(BAUD_TRY2_DIVISOR),A
	XOR	A
	LD	(BAUD_TRY1_FLOW),A
	LD	(BAUD_TRY2_FLOW),A
	LD	(SESSION_LIVE),A

	CALL	WCOMMON.NET_SESSION_IS_WIFI
	JR	C,.READ_BAUD
	LD	A,1
	LD	(SESSION_LIVE),A

	LD	HL,WCOMMON.N_ESP_FW_KEY
	LD	DE,WCOMMON.ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.READ_BAUD
	LD	HL,WCOMMON.ENV_VAL_BUF
	LD	DE,WCOMMON.V_ESP_FW_221
	CALL	UTIL.STRCMP
	JR	C,.READ_BAUD
	LD	A,UART_RX_PROFILE_221
	CALL	WIFI.UART_SET_RX_PROFILE

.READ_BAUD
	LD	HL,N_BAUD_KEY
	LD	DE,WCOMMON.ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	RET	Z
	LD	A,(WCOMMON.ENV_VAL_BUF)
	AND	A
	RET	Z
	LD	DE,WCOMMON.ENV_VAL_BUF
	CALL	DIVISOR_FROM_TEXT
	RET	C
	CP	8
	RET	Z
	LD	C,A					; C = NET_BAUD divisor
	LD	B,0					; B = flow for that attempt
	PUSH	BC
	LD	HL,WCOMMON.N_ESP_FLOW_KEY
	LD	DE,WCOMMON.ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	POP	BC
	OR	A
	JR	Z,.FLOW_KNOWN
	LD	A,(WCOMMON.ENV_VAL_BUF)
	CP	'3'
	JR	NZ,.FLOW_KNOWN
	LD	B,1
.FLOW_KNOWN
	LD	A,(SESSION_LIVE)
	AND	A
	JR	Z,.SECOND
	LD	A,C
	LD	(BAUD_TRY1_DIVISOR),A
	LD	A,B
	LD	(BAUD_TRY1_FLOW),A
	RET
.SECOND
	LD	A,C
	LD	(BAUD_TRY2_DIVISOR),A
	LD	A,B
	LD	(BAUD_TRY2_FLOW),A
	RET

; ------------------------------------------------------
; In: DE - ASCIIZ baud text. Out: A - UART divisor; CF=1 - unrecognized text.
; ------------------------------------------------------
DIVISOR_FROM_TEXT
	LD	HL,NETCFG.BAUD_230400
	CALL	UTIL.STRCMP
	JR	NC,.D4
	LD	HL,NETCFG.BAUD_115200
	CALL	UTIL.STRCMP
	JR	NC,.D8
	LD	HL,NETCFG.BAUD_57600
	CALL	UTIL.STRCMP
	JR	NC,.D16
	LD	HL,NETCFG.BAUD_38400
	CALL	UTIL.STRCMP
	JR	NC,.D24
	LD	HL,NETCFG.BAUD_19200
	CALL	UTIL.STRCMP
	JR	NC,.D48
	LD	HL,NETCFG.BAUD_9600
	CALL	UTIL.STRCMP
	JR	NC,.D96
	SCF
	RET
.D4
	LD	A,4
	RET
.D8
	LD	A,8
	RET
.D16
	LD	A,16
	RET
.D24
	LD	A,24
	RET
.D48
	LD	A,48
	RET
.D96
	LD	A,96
	RET

; ------------------------------------------------------
; Probe a plain "AT" up to PROBE_TRIES times at the currently configured
; divisor/flow. Faster than WCOMMON.SYNC_ESP_COMMAND (6 tries at ~2.3s each,
; meant for a live session) so a silent ESP does not stall the wizard.
; Out: CF=0 - ESP answered; CF=1 - silent after all tries.
; ------------------------------------------------------
PROBE_AT
	LD	B,PROBE_TRIES
.TRY
	PUSH	BC
	CALL	WIFI.UART_RX_RESUME
	LD	HL,WCOMMON.CMD_SYNC_AT
	LD	DE,WIFI.RS_BUFF
	LD	BC,PROBE_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	POP	BC
	AND	A
	RET	Z
	PUSH	BC
	LD	HL,200
	CALL	UTIL.DELAY
	POP	BC
	DJNZ	.TRY
	SCF
	RET

; ------------------------------------------------------
; Run AT+CWLAP and leave its response in WIFI.RS_BUFF for the parser.
; Out: A - RES_* from WIFI.UART_TX_CMD (0 = ok).
; ------------------------------------------------------
SCAN_RUN
	PRINTLN	MSG_SCANNING
	LD	A,0xFF
	LD	(SCAN_SENTINEL),A
	LD	HL,WCOMMON.CMD_GET_AP_LIST
	LD	BC,SCAN_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT
	RET

; ------------------------------------------------------
; Print the parsed AT+CWLAP list (index, SSID, RSSI, channel, security).
; ------------------------------------------------------
PRINT_AP_LIST
	CALL	CWLAP_COUNT
	LD	(AP_LIST_COUNT),A
	LD	A,0				; keeps CF
	RLA				; A = 1 when CWLAP_COUNT capped the list
	LD	(LIST_CAPPED),A
	LD	A,(AP_LIST_COUNT)
	AND	A
	JR	NZ,.HAVE_LIST
	PRINTLN	MSG_NO_NETWORKS
	RET
.HAVE_LIST
	PRINTLN	MSG_AP_LIST_HEADER
	LD	B,1
.ROW
	; DSS console calls do not preserve BC/HL; keep the row counter safe.
	PUSH	BC
	LD	A,B
	CALL	PRINT_AP_ROW
	POP	BC
	INC	B
	LD	A,(AP_LIST_COUNT)
	CP	B
	JR	NC,.ROW
	; Say so when records were dropped: more than CWLAP_MAX_LIST visible
	; networks, or a response long enough to wrap WIFI.RS_BUFF (the sentinel
	; near its end was overwritten). AT+CWLAPOPT=1,... makes the ESP sort by
	; RSSI, so the networks that are shown are the strongest ones.
	LD	A,(LIST_CAPPED)
	AND	A
	JR	NZ,.INCOMPLETE
	LD	A,(SCAN_SENTINEL)
	CP	0xFF
	RET	Z
.INCOMPLETE
	PRINTLN	MSG_LIST_MAYBE_INCOMPLETE
	RET

; ------------------------------------------------------
; In: A - 1-based row index.
; ------------------------------------------------------
PRINT_AP_ROW
	PUSH	AF
	CALL	CWLAP_FIND
	JR	C,.MISS
	POP	AF
	PUSH	AF
	CP	10
	JR	NC,.TWO_DIGITS
	PRINT	MSG_SPACE			; right-align 1-9 under 10-20
.TWO_DIGITS
	POP	AF
	LD	L,A
	LD	H,0
	LD	DE,NUM_BUFF
	CALL	UTIL.UTOA
	PRINT	NUM_BUFF
	PRINT	MSG_ROW_SEP
	LD	HL,(AP_SSID)
	LD	A,(AP_SSID_LEN)
	LD	B,A
	CALL	PRINT_SSID_FIELD
	PRINT	MSG_ROW_MID
	LD	A,(AP_RSSI_NEG)
	AND	A
	JR	Z,.NO_MINUS
	PRINT	MSG_MINUS
.NO_MINUS
	LD	A,(AP_RSSI)
	LD	L,A
	LD	H,0
	LD	DE,NUM_BUFF
	CALL	UTIL.UTOA
	PRINT	NUM_BUFF
	PRINT	MSG_ROW_CHAN
	LD	A,(AP_CHAN)
	LD	L,A
	LD	H,0
	LD	DE,NUM_BUFF
	CALL	UTIL.UTOA
	PRINT	NUM_BUFF
	PRINT	MSG_ROW_SECTAG
	LD	A,(AP_ECN)
	CALL	CWLAP_SECURITY_NAME
	PRINT_HL
	PRINT	WCOMMON.LINE_END
	RET
.MISS
	POP	AF
	RET

; ------------------------------------------------------
; Print up to 32 raw bytes from HL (In: B - length), then pad with spaces to
; a fixed 32-column field. Avoids needing a NUL terminator inside RS_BUFF.
; ------------------------------------------------------
PRINT_SSID_FIELD
	LD	A,B
	CP	33
	JR	C,.LEN_OK
	LD	B,32
.LEN_OK
	LD	A,32
	SUB	B
	PUSH	AF
	LD	A,B
	AND	A
	JR	Z,.PAD
.CHARS
	LD	A,(HL)
	CALL	PUT_CHAR
	INC	HL
	DJNZ	.CHARS
.PAD
	POP	AF
	AND	A
	RET	Z
	LD	B,A
.PADLOOP
	LD	A,' '
	CALL	PUT_CHAR
	DJNZ	.PADLOOP
	RET

PUT_CHAR
	PUSH	BC,DE,HL
	DSS_EXEC	DSS_PUTCHAR
	POP	HL,DE,BC
	RET

; ------------------------------------------------------
; Ask to scan, run it, and let the user pick a network or fall back to
; manual entry. Any failure along the way prints a hint and returns
; WIZ_MANUAL instead of aborting NETCFG.
; Out: A - WIZ_MANUAL | WIZ_SSID_SET | WIZ_OPEN.
; ------------------------------------------------------
SCAN_WIZARD
	LD	A,(OPT_FLAGS)
	AND	OPT_SCAN
	JR	NZ,.DO_SCAN
	PRINT	MSG_ASK_SCAN
	LD	HL,INPUT_BUFF
	LD	B,INPUT_BUFF_SIZE
	CALL	READ_LINE
	LD	A,(INPUT_BUFF)
	AND	0xDF
	CP	'N'
	JR	NZ,.DO_SCAN
	LD	A,WIZ_MANUAL
	RET
.DO_SCAN
	CALL	SCAN_BRINGUP
	JR	NC,.BROUGHT_UP
	PRINTLN	MSG_SCAN_HINT_MANUAL
	LD	A,WIZ_MANUAL
	RET
.BROUGHT_UP
	CALL	SCAN_RUN
	AND	A
	JR	Z,.RUN_OK
	ADD	A,'0'
	LD	(MSG_SCAN_FAILED_NO),A
	PRINTLN	MSG_SCAN_FAILED
	PRINTLN	MSG_SCAN_HINT_MANUAL
	LD	A,WIZ_MANUAL
	RET
.RUN_OK
	CALL	PRINT_AP_LIST
	LD	A,(AP_LIST_COUNT)
	AND	A
	JR	NZ,SELECT_AP
	PRINTLN	MSG_SCAN_HINT_MANUAL
	LD	A,WIZ_MANUAL
	RET

; ------------------------------------------------------
; Prompt for a network number (0 = manual, Enter = keep current SSID).
; Out: A - WIZ_MANUAL | WIZ_SSID_SET | WIZ_OPEN.
; ------------------------------------------------------
SELECT_AP
	PRINT	MSG_SELECT_PROMPT_PRE
	LD	A,(AP_LIST_COUNT)
	LD	L,A
	LD	H,0
	LD	DE,NUM_BUFF
	CALL	UTIL.UTOA
	PRINT	NUM_BUFF
	LD	A,(NETCFG.CFG_SSID)
	AND	A
	JR	Z,.PROMPT_NO_KEEP
	PRINT	MSG_SELECT_PROMPT_MID
	PRINT	NETCFG.CFG_SSID
	PRINT	MSG_SELECT_PROMPT_POST
	JR	.PROMPT_DONE
.PROMPT_NO_KEEP
	PRINT	MSG_SELECT_PROMPT_NOKEEP
.PROMPT_DONE

	LD	HL,INPUT_BUFF
	LD	B,INPUT_BUFF_SIZE
	CALL	READ_LINE
	LD	A,(INPUT_BUFF)
	AND	A
	JR	Z,.KEEP
	CP	'0'
	JR	NZ,.PARSE_NUM
	LD	A,(INPUT_BUFF+1)
	AND	A
	JR	Z,.MANUAL

.PARSE_NUM
	LD	DE,INPUT_BUFF
	CALL	UTIL.ATOU
	LD	A,H
	AND	A
	JR	NZ,.BAD_NUM
	LD	A,L
	AND	A
	JR	Z,.BAD_NUM
	LD	B,A
	LD	A,(AP_LIST_COUNT)
	CP	B
	JR	C,.BAD_NUM
	LD	A,B
	CALL	CWLAP_APPLY_CHOICE
	JR	C,.BAD_NUM
	PUSH	AF
	PRINT	MSG_SELECTED_PRE
	PRINT	NETCFG.CFG_SSID
	PRINT	WCOMMON.LINE_END
	CALL	WARN_HASH_IN_SSID
	POP	AF
	AND	A
	JR	NZ,.NOT_OPEN
	PRINTLN	MSG_SELECTED_OPEN
	LD	A,WIZ_OPEN
	RET
.NOT_OPEN
	LD	A,WIZ_SSID_SET
	RET
.BAD_NUM
	PRINTLN	MSG_INVALID_NUMBER
	JP	SELECT_AP
.MANUAL
	LD	A,WIZ_MANUAL
	RET
.KEEP
	; Enter keeps the SSID already in NET.CFG. With nothing saved yet there is
	; nothing to keep: ask for the name instead of silently saving an empty one.
	LD	A,(NETCFG.CFG_SSID)
	AND	A
	JR	Z,.MANUAL
	LD	A,WIZ_SSID_SET
	RET

; ------------------------------------------------------
; Warn if NETCFG.CFG_SSID contains '#': NET.CFG treats it as a comment
; marker, so NETUP would read back a truncated name.
; ------------------------------------------------------
WARN_HASH_IN_SSID
	LD	A,'#'
	LD	HL,NETCFG.CFG_SSID
	CALL	UTIL.STRCHR
	RET	C
	PRINTLN	MSG_HASH_WARNING
	RET

MSG_START
	DB "NETCFG "
	PACKAGE_VERSION_TAG
	DB " - Sprinter ESP Network Kit configuration"
	DB 0
MSG_LOADED
	DB "Loaded NET.CFG.",0
MSG_NOT_FOUND
	DB "NET.CFG not found, showing defaults.",0

MSG_SSID	DB "SSID: ",0
MSG_PASS	DB "PASS: ",0
MSG_PASS_SET	DB "<set>",0
MSG_PASS_EMPTY	DB "<empty>",0
MSG_DHCP	DB "DHCP: ",0
MSG_IP		DB "IP: ",0
MSG_GATEWAY	DB "GATEWAY: ",0
MSG_NETMASK	DB "NETMASK: ",0
MSG_DNS1	DB "DNS1: ",0
MSG_DNS2	DB "DNS2: ",0
MSG_TZ		DB "TZ: ",0
MSG_NTP		DB "NTP: ",0
MSG_AUTOJOIN	DB "AUTOJOIN: ",0
MSG_BAUD	DB "BAUD: ",0

MSG_WRITE_MODE
	DB "Interactive write mode.",0
MSG_WRITE_WARN
	DB "Warning: Wi-Fi password will be saved as clear text.",0
MSG_SAVED
	DB "NET.CFG saved.",0
MSG_CURRENT_PREFIX
	DB " [",0
MSG_CURRENT_SUFFIX
	DB "]: ",0

MSG_PROMPT_SSID	DB "SSID",0
MSG_PROMPT_PASS	DB "PASS",0
MSG_PROMPT_DHCP	DB "DHCP",0
MSG_PROMPT_IP	DB "IP",0
MSG_PROMPT_GATEWAY	DB "GATEWAY",0
MSG_PROMPT_NETMASK	DB "NETMASK",0
MSG_PROMPT_DNS1	DB "DNS1",0
MSG_PROMPT_DNS2	DB "DNS2",0
MSG_PROMPT_TZ	DB "TZ",0
MSG_PROMPT_NTP	DB "NTP",0
MSG_PROMPT_AUTOJOIN	DB "AUTOJOIN",0
MSG_PROMPT_BAUD	DB "BAUD",0

MSG_ASK_SCAN
	DB "Scan for Wi-Fi networks? [Y/n]: ",0
MSG_SCANNING
	DB "Scanning for Wi-Fi networks (up to 15 s)...",0
MSG_SCAN_FAILED
	DB "Scan failed (error #"
MSG_SCAN_FAILED_NO
	DB "0).",0
MSG_SCAN_HINT_MANUAL
	DB "Enter the SSID manually.",0
MSG_ESP_SILENT
	DB "ESP does not respond - run NETRESET and retry, or enter SSID manually.",0
MSG_NO_NETWORKS
	DB "No networks found.",0
MSG_AP_LIST_HEADER
	DB "Networks found:",0
MSG_LIST_MAYBE_INCOMPLETE
	DB "List may be incomplete: too many networks in range. Move closer or enter the SSID manually.",0
MSG_ROW_SEP	DB ". ",0
MSG_SPACE	DB " ",0
MSG_ROW_MID	DB "  ",0
MSG_MINUS	DB "-",0
MSG_ROW_CHAN	DB "dBm  ch",0
MSG_ROW_SECTAG	DB "  ",0
MSG_SELECT_PROMPT_PRE
	DB "Network number 1-",0
MSG_SELECT_PROMPT_MID
	DB ", 0 = enter SSID manually, Enter = keep [",0
MSG_SELECT_PROMPT_POST
	DB "]: ",0
MSG_SELECT_PROMPT_NOKEEP
	DB ", 0 or Enter = enter SSID manually: ",0
MSG_INVALID_NUMBER
	DB "Invalid number.",0
MSG_SELECTED_PRE
	DB "Selected SSID: ",0
MSG_SELECTED_OPEN
	DB "Open network - password cleared.",0
MSG_HASH_WARNING
	DB "Warning: '#' in SSID starts a comment in NET.CFG; NETUP will read a shorter name.",0

N_BAUD_KEY	DB "NET_BAUD",0	; wcommon's own N_BAUD_KEY is compiled only
					; under WCOMMON_USE_NETCFG, which NETCFG does not define

INPUT_BUFF_SIZE	EQU 80
INPUT_REMAIN	DB 0
CMDLINE_PTR	DW 0			; arg buffer ptr captured from IX at entry
OPT_FLAGS	DB 0
AP_LIST_COUNT	DB 0
LIST_CAPPED	DB 0			; CWLAP_COUNT hit CWLAP_MAX_LIST with records left over
SESSION_LIVE	DB 0
; APPLY_UART_TRY reads each pair as adjacent divisor,flow bytes.
BAUD_TRY1_DIVISOR	DB 0
BAUD_TRY1_FLOW		DB 0
BAUD_TRY2_DIVISOR	DB 0
BAUD_TRY2_FLOW		DB 0
NUM_BUFF	DS 6,0

	ENDMODULE

	DEFINE	WCOMMON_NET_SESSION_QUERY	; scan wizard asks whether NETUP published a session
	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

	MODULE MAIN

	INCLUDE "netcfg_scan.asm"
	INCLUDE "netup_busy_retry.asm"

INPUT_BUFF	EQU NETCFG.NETCFG_BSS_END
NETCFG_APP_BSS_END	EQU INPUT_BUFF + INPUT_BUFF_SIZE
SCAN_SENTINEL	EQU WIFI.RS_BUFF + RS_BUFF_SIZE - 48

	ASSERT	NETCFG_APP_BSS_END < 0xC000

	ENDMODULE

	END MAIN.START
