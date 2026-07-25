; ======================================================
; Common code for Sprinter-WiFi utilities
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; License: BSD 3-Clause
; ======================================================
	IFNDEF	_WCOMMON
	DEFINE	_WCOMMON

; The normal package build defines neither profile and uses only the ESP-AT
; features shared by 2.2.1 and 2.2.2. Forced builds must name one dialect.
	IFDEF	ESP_AT_FORCE_221
	IFDEF	ESP_AT_FORCE_222
	ASSERT	0
	ENDIF
	ENDIF

ENABLE_RTS_CTR	EQU 1
ESP_SYNC_RETRIES	EQU 6
ESP_SYNC_DELAY		EQU 300
ESP_CLEAN_DELAY		EQU 150

; NETCFG is often included after this common source. Such programs define
; WCOMMON_USE_NETCFG before including WCOMMON so the forward NETCFG references
; below are emitted. Small tools without NET.CFG (NETRESET) keep the fixed
; 115200 flow-control command instead.
	IFDEF	_NETCFG
	IFNDEF	_WCOMMON_NETCFG
	DEFINE	_WCOMMON_NETCFG
	ENDIF
	ENDIF
	IFDEF	WCOMMON_USE_NETCFG
	IFNDEF	_WCOMMON_NETCFG
	DEFINE	_WCOMMON_NETCFG
	ENDIF
	ENDIF

	MODULE WCOMMON

; ------------------------------------------------------
; Check UART result (A=RES_*): print message and exit when A is non-zero.
; UART_TX_CMD also mirrors this state in Carry, but testing A keeps this
; handler correct for callers which preserve only the documented result code.
; ------------------------------------------------------
	;;IFUSED CHECK_ERROR
CHECK_ERROR
	OR		A
	RET		Z
	ADD		A,'0'
	LD		(COMM_ERROR_NO), A
	PRINTLN	MSG_COMM_ERROR
	IFDEF	TRACE
	CALL	DUMP_UART_REGS
	ENDIF
	LD		B,3
	POP		HL											; ret addr reset
	;;ENDIF

; ------------------------------------------------------
;	Program exit point
; ------------------------------------------------------
EXIT
	CALL	REST_VMODE
    DSS_EXEC	DSS_EXIT
; ------------------------------------------------------
; Search Sprinter WiFi card
; ------------------------------------------------------
	;;IFUSED FIND_SWF
FIND_SWF
	; Find Sprinter-WiFi
	CALL    @WIFI.UART_FIND
	JP		C, NO_TL_FOUND
	LD		A,(ISA.ISA_SLOT)
	ADD		A,'1'
	LD      (MSG_SLOT_NO),A
	PRINTLN	MSG_SWF_FOUND
	RET

NO_TL_FOUND
	POP 	BC
	PRINTLN MSG_SWF_NOF
	LD		B,2
	JP		EXIT
	;;ENDIF

; ------------------------------------------------------
; Dump all UTL16C550 registers to screen for debug
; ------------------------------------------------------
	;;IFUSED DUMP_UART_REGS
	IFDEF	TRACE
DUMP_UART_REGS
	; Dump, DLAB=0 registers
	LD		BC, 0x0800
	CALL	DUMP_REGS

	; Dump, DLAB=1 registers
	LD		HL, REG_LCR
	LD		E, LCR_DLAB | LCR_WL8
	CALL	WIFI.UART_WRITE

	LD		BC, 0x0210
	CALL	DUMP_REGS

	LD		HL, REG_LCR
	LD		E, LCR_WL8
	JP		WIFI.UART_WRITE
	;CALL	WIFI.UART_WRITE
	;RET

DUMP_REGS
	LD		HL, PORT_UART_A

DR_NEXT
	LD		DE,MSG_DR_RN
	CALL	@UTIL.HEXB
	INC		C

	CALL    WIFI.UART_READ
	PUSH    BC
	LD		C,A
	LD		DE,MSG_DR_RV
	CALL	@UTIL.HEXB
	PUSH 	HL

	PRINTLN MSG_DR

	POP		HL,BC
	INC		HL
	DJNZ	DR_NEXT
	RET
	ENDIF
	;;ENDIF

; ------------------------------------------------------
; Non-blocking check for user cancel: Esc (E=0x1B / 0x07) or Ctrl+Z (E=0x1A
; with any Ctrl modifier held). Calls DSS_SCANKEY and consumes the matching
; key from the buffer. On cancel sets WCOMMON.CANCELLED so callers nested
; inside UART/ISA loops can propagate up via existing error paths and the
; top-level error handler can redirect to CANCEL_EXIT.
; Out: CF=1 - cancel pressed, CF=0 - no cancel.
; Preserves A, BC, DE, HL.
; Caller must NOT have ISA window open; SCANKEY may switch memory pages.
; ------------------------------------------------------
	;;IFUSED CHECK_CANCEL
CHECK_CANCEL
	PUSH	AF,BC,DE,HL
	DSS_EXEC	DSS_SCANKEY
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	CP	0x07
	JR	Z,.CANCEL
	CP	0x1A
	JR	NZ,.NO_KEY
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	POP	HL,DE,BC,AF
	SCF
	RET
.NO_KEY
	POP	HL,DE,BC,AF
	AND	A
	RET
	;;ENDIF

; ------------------------------------------------------
; Same as CHECK_CANCEL but allowed to be called while ISA window is open.
; Closes ISA, polls keyboard, reopens ISA.
; Out: CF=1 if cancel pressed.
; Preserves all registers including A.
; ------------------------------------------------------
CHECK_CANCEL_IN_ISA
	PUSH	AF,BC,DE,HL
	CALL	@ISA.ISA_CLOSE
	DSS_EXEC	DSS_SCANKEY
	JR	Z,.NO_KEY
	LD	A,E
	CP	0x1B
	JR	Z,.CANCEL
	CP	0x07
	JR	Z,.CANCEL
	CP	0x1A
	JR	NZ,.NO_KEY
	LD	A,B
	AND	KB_CTRL | KB_L_CTRL | KB_R_CTRL
	JR	Z,.NO_KEY
.CANCEL
	LD	A,1
	LD	(CANCELLED),A
	CALL	@ISA.ISA_OPEN
	POP	HL,DE,BC,AF
	SCF
	RET
.NO_KEY
	; Optional idle callback (e.g. a clock tick), run here while ISA is CLOSED so
	; the callback may use DSS/BIOS safely. Zero by default -> no-op for apps that
	; don't set it. The callback must return with a plain RET and may clobber
	; registers (we restore them below).
	LD	HL,(IDLE_CB)
	LD	A,H
	OR	L
	CALL	NZ,.CALL_CB
	CALL	@ISA.ISA_OPEN
	POP	HL,DE,BC,AF
	AND	A
	RET
.CALL_CB
	JP	(HL)			; call IDLE_CB (it RETs to the CALL NZ site)

; Cancellation flag. Set by CHECK_CANCEL when Esc/Ctrl+Z detected.
; Top-level error handlers in apps check this and redirect to CANCEL_EXIT.
CANCELLED	DB 0
; Idle callback pointer, invoked from CHECK_CANCEL_IN_ISA while ISA is closed
; (so it can call DSS/BIOS). Apps set it to a routine; 0 = none.
IDLE_CB		DW 0

; ------------------------------------------------------
; Store old video mode and set 80x32 without clearing the console.
; ------------------------------------------------------
	;;IFUSED INIT_VMODE
INIT_VMODE
	PUSH	BC,DE,HL
	; Store previous vmode
	LD		C,DSS_GETVMOD
	RST		DSS
	LD		(SAVE_VMODE),A
	CP		DSS_VMOD_T80
	; Set vmode 80x32
	JR		Z, IVM_ALRDY_80
	LD		C,DSS_SETVMOD
	LD		A,DSS_VMOD_T80
	RST		DSS
IVM_ALRDY_80
	; Show the selected target in every forced-profile utility banner. Auto
	; builds intentionally stay quiet because they support both dialects.
	IFDEF	ESP_AT_FORCE_221
	PRINTLN	MSG_ESP_AT_BUILD_221
	ENDIF
	IFDEF	ESP_AT_FORCE_222
	PRINTLN	MSG_ESP_AT_BUILD_222
	ENDIF
	POP		HL,DE,BC
	RET
	;;ENDIF
; ------------------------------------------------------
; Restore saved video mode
; ------------------------------------------------------
	;;IFUSED	REST_VMODE
REST_VMODE
	PUSH	BC
	LD		A,(SAVE_VMODE)
	CP		DSS_VMOD_T80
	JR		Z, RVM_SAME
	; Restore mode
	PRINTLN MSG_PRESS_AKEY

	LD		C, DSS_WAITKEY
	RST		DSS

	LD		C,DSS_SETVMOD
	RST		DSS
RVM_SAME
	POP		BC
	RET
	;;ENDIF

; ------------------------------------------------------
; Init basic parameters of ESP
; ------------------------------------------------------
	;;IFUSED INIT_ESP
INIT_ESP
	PUSH	BC, DE
	LD		DE, @WIFI.RS_BUFF
	LD		BC, DEFAULT_TIMEOUT

   	TRACELN	MSG_ECHO_OFF
	SEND_CMD CMD_ECHO_OFF

   	TRACELN MSG_STATIOJN_MODE
	SEND_CMD CMD_STATION_MODE

   	TRACELN MSG_NO_SLEEP
	SEND_CMD CMD_NO_SLEEP

	IF ENABLE_RTS_CTR
   		TRACELN MSG_SET_UART
		IFDEF	_WCOMMON_NETCFG
		CALL	SETUP_UART_FLOW
		CALL	CHECK_ERROR
		ELSE
		SEND_CMD CMD_SET_SPEED
		ENDIF
	ENDIF

   	TRACELN MSG_SET_OPT
	SEND_CMD CMD_CWLAP_OPT
	POP		DE,BC
	RET
	;;ENDIF
	IFDEF	_WCOMMON_NETCFG
UART_FLOW_VERIFY_CMD
	DB	"AT",13,10,0

; ------------------------------------------------------
; Verify the UART contract NETUP published in NET_ESP_FLOW. REQUIRE_NET_UP has
; already selected the matching local MCR mode before UART_INIT. Do not resend
; AT+UART_CUR or toggle AFE here: doing so in a live session caused the next
; delayed response burst to lose its prefix ("+PING:109" became "G:109").
; Out: A=0 on success, A=non-zero ESP result on communication failure.
; ------------------------------------------------------
SETUP_UART_FLOW
	PUSH	BC,DE,HL
	CALL	UART_FLOW_VERIFY
	POP		HL,DE,BC
	RET

UART_FLOW_VERIFY
	LD		HL,UART_FLOW_VERIFY_CMD
	LD		DE,@WIFI.RS_BUFF
	LD		BC,DEFAULT_TIMEOUT
	JP		@WIFI.UART_TX_CMD

; ------------------------------------------------------
; Session UART baud for client utilities. NET.CFG belongs to NETUP/NETCFG
; (beside NETUP.EXE); utilities never read the file and take the baud from
; env NET_BAUD, published by NETUP - the authoritative record of what the ESP
; UART is actually running. Without a NET_BAUD (fresh boot, NETUP not run)
; the ESP is at its power-up 115200, so the default matches.
; SEED_NET_BAUD fills NETCFG.CFG_BAUD (plain BSS, garbage until seeded);
; APPLY_NET_BAUD additionally switches the local divisor.
; Trashes A,BC,DE,HL.
; ------------------------------------------------------
APPLY_NET_BAUD
	CALL	SEED_NET_BAUD
	JP	@NETCFG.APPLY_UART_BAUD

SEED_NET_BAUD
	LD	HL,@NETCFG.DEFAULT_BAUD
	LD	DE,@NETCFG.CFG_BAUD
	LD	B,NETCFG.CFG_BAUD_SIZE
	CALL	@NETCFG.COPY_ASCIIZ
	LD	HL,N_BAUD_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	RET	Z				; NET_BAUD not set -> 115200 default
	LD	A,(ENV_VAL_BUF)
	OR	A
	RET	Z				; empty value -> 115200 default
	LD	HL,ENV_VAL_BUF
	LD	DE,@NETCFG.CFG_BAUD
	LD	B,NETCFG.CFG_BAUD_SIZE
	JP	@NETCFG.COPY_ASCIIZ

N_BAUD_KEY	DB "NET_BAUD",0
	ENDIF

; ------------------------------------------------------
; Non-destructively synchronize with the ESP command interpreter.
;
; A previous socket command may finish asynchronously and leave a late ERROR,
; FAIL or CLOSED line in the UART. UART_TX_CMD correctly treats the first
; terminal line as the result of its command, so a single AT probe can consume
; that stale result instead of its own OK. Retry plain AT after a short drain
; interval. Never reset ESP here: NETUP configures Wi-Fi for the current
; session, and a hardware reset would invalidate the published NET_* state.
;
; Out: A=RES_OK/CF=0 on success; last RES_*/CF=1 after all retries.
; Trashes BC,DE,HL.
; ------------------------------------------------------
SYNC_ESP_COMMAND
	LD		B,ESP_SYNC_RETRIES
.TRY
	PUSH	BC
	CALL	@WIFI.UART_RX_RESUME
	LD		HL,CMD_SYNC_AT
	LD		DE,@WIFI.RS_BUFF
	LD		BC,DEFAULT_TIMEOUT
	CALL	@WIFI.UART_TX_CMD
	POP		BC
	AND		A
	RET		Z
	; Right after NETUP's join the ESP can answer "busy p..." while its IP
	; stack finishes coming up; those probes now fail fast (RES_BUSY), so a
	; settle interval is what actually lets the retries bridge that window.
	PUSH	BC
	LD		HL,ESP_SYNC_DELAY
	CALL	@UTIL.DELAY
	POP		BC
	DJNZ	.TRY
	SCF
	RET

CMD_SYNC_AT
	DB	"AT",13,10,0

; ------------------------------------------------------
; Set DHCP mode
; Out: CF=1 if error
; ------------------------------------------------------
	;;IFUSED SET_DHCP_MODE
SET_DHCP_MODE
	PUSH	BC,DE
	LD		DE, WIFI.RS_BUFF
	LD		BC, DEFAULT_TIMEOUT
	TRACELN MSG_SET_DHCP
	SEND_CMD CMD_SET_DHCP
	POP		DE,BC
	RET
	;;ENDIF

; ------------------------------------------------------
; Close any TCP/UDP connection a previous (possibly aborted or crashed) run
; left open and flush stale UART bytes. ESP-AT rejects AT+CIPMUX while a
; connection is still established. Every command result is intentionally
; ignored because "no such connection" is an expected ERROR. Call only while
; ESP is believed to be in command mode. Trashes A,BC,DE,HL; returns A=0/CF=0.
; ------------------------------------------------------
; Compact: send close-all, then fall through to send close-one. UART_TX_CMD
; already empties the RX FIFO before each send, so the next command (AT+CIPMUX)
; starts clean without an explicit flush here.
CLEAN_ESP_LINKS
	LD	HL,CMD_CIPCLOSE_ALL		; close all links (id 5) - multi-conn mode
	CALL	.tx
	LD	HL,CMD_CIPCLOSE_ONE		; close the single connection - single mode
	CALL	.tx
	; Link teardown and CLOSED notifications are asynchronous.  Let them reach
	; the UART, then discard the tail before the caller changes CIPMUX/CIPMODE.
	LD	HL,ESP_CLEAN_DELAY
	CALL	@UTIL.DELAY
	CALL	@WIFI.UART_EMPTY_RS
	XOR	A
	RET
.tx
	LD	DE,@WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	JP	@WIFI.UART_TX_CMD

CMD_CIPCLOSE_ALL
	DB	"AT+CIPCLOSE=5",13,10,0
CMD_CIPCLOSE_ONE
	DB	"AT+CIPCLOSE",13,10,0

; ------------------------------------------------------
; Require that NETUP has brought the network up: env NET must equal "WIFI" and
; NET_ESP_HW must be set (both published by NETUP). On failure print a hint and
; exit with B=4 (config error). Network-dependent tools call this before any
; ESP/TCP operation. Reads env via DSS ENVIRON (#46/#01).
; ------------------------------------------------------
REQUIRE_NET_UP
	LD	HL,N_NET_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.FAIL				; NET not set
	LD	HL,ENV_VAL_BUF
	LD	DE,V_WIFI
	CALL	.STRMATCH
	JR	NZ,.FAIL			; NET != WIFI
	LD	HL,N_ESP_HW_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.FAIL				; NET_ESP_HW not set
	LD	A,(ENV_VAL_BUF)
	OR	A
	JR	Z,.FAIL				; NET_ESP_HW empty
	; The universal executable selects its UART receive implementation from
	; NET_ESP_FW published by the successful NETUP run. Do not issue a second
	; ESP firmware probe here: it would make the active connection state part of
	; a local UART choice. A forced image has only one algorithm compiled.
	IFDEF	ESP_AT_FORCE_221
	LD	A,UART_RX_PROFILE_221
	LD	(UART_ESP_PROFILE),A
	CALL	@WIFI.UART_SET_RX_PROFILE
	JR	.READ_FLOW
	ELSE
	IFDEF	ESP_AT_FORCE_222
	LD	A,UART_RX_PROFILE_222
	LD	(UART_ESP_PROFILE),A
	CALL	@WIFI.UART_SET_RX_PROFILE
	JR	.READ_FLOW
	ELSE
	LD	HL,N_ESP_FW_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.PROFILE_FAIL
	LD	HL,ENV_VAL_BUF
	LD	DE,V_ESP_FW_221
	CALL	.STRMATCH
	JR	Z,.FW221
	LD	HL,ENV_VAL_BUF
	LD	DE,V_ESP_FW_222
	CALL	.STRMATCH
	JR	NZ,.PROFILE_FAIL
	LD	A,2
	JR	.SET_PROFILE
.FW221
	LD	A,1
.SET_PROFILE
	LD		(UART_ESP_PROFILE),A
	CALL	@WIFI.UART_SET_RX_PROFILE
	ENDIF
	ENDIF
.READ_FLOW
	; NETUP may have fallen back to ESP flow=0 when CTS/RTS is unavailable.
	; Reproduce its actual mode before the caller initializes its local 16550;
	; guessing here is what made consecutive utilities intermittently disagree.
	LD	HL,N_ESP_FLOW_KEY
	LD	DE,ENV_VAL_BUF
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	OR	A
	JR	Z,.PROFILE_FAIL
	LD	A,(ENV_VAL_BUF)
	CP	'3'
	JR	Z,.FLOW3
	CP	'0'
	JR	NZ,.PROFILE_FAIL
	CALL	@WIFI.UART_FLOW_OFF
	RET
.FLOW3
	CALL	@WIFI.UART_FLOW_ON
	RET
.FAIL
	PRINTLN MSG_NET_NOT_UP
	LD	B,4
	JP	EXIT
.PROFILE_FAIL
	PRINTLN MSG_NET_NOT_UP
	LD	B,4
	JP	EXIT
; Compare ASCIIZ at HL and DE. Out: Z if equal. Trashes A,C,HL,DE.
.STRMATCH
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	CP	C
	RET	NZ
	OR	A
	RET	Z
	INC	HL
	INC	DE
	JR	.STRMATCH

N_NET_KEY	DB "NET",0
N_ESP_HW_KEY	DB "NET_ESP_HW",0
N_ESP_FW_KEY	DB "NET_ESP_FW",0
N_ESP_FLOW_KEY	DB "NET_ESP_FLOW",0
V_WIFI		DB "WIFI",0
V_ESP_FW_221	DB "2.2.1",0
V_ESP_FW_222	DB "2.2.2",0
MSG_NET_NOT_UP	DB "Network is not up - run NETUP first.",0
ENV_VAL_BUF	DS 32,0
UART_ESP_PROFILE DB UART_RX_PROFILE_222

; ------------------------------------------------------
; Messages
; ------------------------------------------------------
	;;IFUSED FIND_SWF
MSG_SWF_NOF
	DB "Sprinter-WiFi not found!",0
MSG_SWF_FOUND
	DB "Sprinter-WiFi found in ISA#"
MSG_SLOT_NO
	DB "n slot.",0
	;;ENDIF

MSG_COMM_ERROR
	DB "Error communication with Sprinter-WiFi #"

COMM_ERROR_NO
	DB "n!",0

MSG_PRESS_AKEY
	DB "Press any key to continue...",0

MSG_ESP_RESET
	DB "Reset ESP module.",0

MSG_UART_INIT
	DB "Reset UART.",0

	IFDEF	ESP_AT_FORCE_221
MSG_ESP_AT_BUILD_221
	DB "ESP-AT build profile: 2.2.1.",0
	ENDIF
	IFDEF	ESP_AT_FORCE_222
MSG_ESP_AT_BUILD_222
	DB "ESP-AT build profile: 2.2.2.",0
	ENDIF

LINE_END
	DB 13,10,0

	;;IFUSED INIT_VMODE
SAVE_VMODE
	DB 0
	;;ENDIF

; ------------------------------------------------------
; Debug messages
; ------------------------------------------------------
	IFDEF TRACE
MSG_DR
	DB	"Reg[0x"
MSG_DR_RN
	DB	"vv]=0x"
MSG_DR_RV
	DB	"vv",0

MSG_ECHO_OFF
	DB "Echo off",0

MSG_STATIOJN_MODE
	DB "Station mode",0

MSG_NO_SLEEP
	DB "No sleep",0

MSG_SET_UART
	DB "Setup uart",0

MSG_SET_OPT
	DB "Set options",0

MSG_SET_DHCP
	DB	"Set DHCP mode",0

	ENDIF

; ------------------------------------------------------
; Commands
; ------------------------------------------------------
; CMD_QUIT
;     DB "QUIT\r",0

CMD_VERSION
	DB "AT+GMR",13,10,0
	IFNDEF	_WCOMMON_NETCFG
CMD_SET_SPEED
	DB	"AT+UART_CUR=115200,8,1,0,3",13,10,0
	ENDIF
CMD_ECHO_OFF
	DB	"ATE0",13,10,0
CMD_STATION_MODE
	DB	"AT+CWMODE=1",13,10,0
CMD_NO_SLEEP
	DB	"AT+SLEEP=0",13,10,0
CMD_CHECK_CONN_AP
	DB	"AT+CWJAP?",13,10,0
CMD_CWLAP_OPT
	DB	"AT+CWLAPOPT=1,23",13,10,0
CMD_GET_AP_LIST
	DB "AT+CWLAP",13,10,0
CMD_GET_DHCP
	DB "AT+CWDHCP?",13,10,0
CMD_SET_DHCP
	DB	"AT+CWDHCP=1,1",13,10,0
CMD_GET_IP
	DB "AT+CIPSTA?",13,10,0


	ENDMODULE

	ENDIF
