; ======================================================
; NETUP for Sprinter ESP Network Kit
; Bring SprinterESP Wi-Fi connection up from NET.CFG.
; ======================================================

EXE_VERSION		EQU 1
DEFAULT_TIMEOUT		EQU 2000
JOIN_TIMEOUT		EQU 30000
UART_SWITCH_SETTLE	EQU 300
UART_VERIFY_RETRIES	EQU 6		; AT attempts after a baud switch before giving up
NETUP_BUSY_RETRIES	EQU 10		; command retries while the ESP answers "busy p..."
NETUP_BUSY_DELAY	EQU 500		; ms between busy retries
NETUP_IP_RETRIES	EQU 30		; AT+CIFSR polls while the DHCP lease is pending
NETUP_IP_DELAY		EQU 500		; ms between CIFSR polls
EXE_DIR_SIZE		EQU 272		; APPINFO path (up to 256) + "NET.CFG",0

; NETUP normally determines the profile with AT+SYSSTORE?. The package-wide
; ESP_AT_FORCE_221 / ESP_AT_FORCE_222 defines make a profile-specific build.
; Retain the older NETUP_FORCE_AT* aliases for existing diagnostic commands.
	IFDEF	NETUP_FORCE_AT221
	DEFINE	ESP_AT_FORCE_221
	ENDIF
	IFDEF	NETUP_FORCE_AT222
	DEFINE	ESP_AT_FORCE_222
	ENDIF
ESP_FW_221		EQU 1
ESP_FW_222		EQU 2

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
	; Do not let a failed NETUP leave the success marker or stale addresses from
	; an earlier run visible to consumers.  The complete NET_* set is published
	; again only after the new association has been verified below.
	CALL	CLEAR_NET_ENV

	CALL	LOAD_CONFIG_FROM_EXE_DIR
	JR	NC,.CFG_LOADED
	CP	E_FILE_NOT_FOUND
	JR	NZ,.DSS_ERROR
	PRINTLN MSG_NO_CFG
	LD	B,4
	JP	WCOMMON.EXIT

.DSS_ERROR
	CALL	PRINT_CONFIG_DSS_ERROR
	LD	B,4
	JP	WCOMMON.EXIT

.CFG_LOADED
	LD	A,(NETCFG.CFG_SSID)
	AND	A
	JR	NZ,.HAVE_SSID
	PRINTLN MSG_NO_SSID
	LD	B,4
	JP	WCOMMON.EXIT

.HAVE_SSID
	CALL	WIFI.UART_FIND
	JP	C,NO_WIFI

	; ESP reset/default power-up UART is 115200. Start there even when
	; NET.CFG requests a different BAUD; APPLY_UART_SETTING will command the
	; ESP to switch first, then switch the local 16550 and verify.
	CALL	INIT_UART_DEFAULT
	PRINTLN MSG_UART_READY

	CALL	SEND_AT_STARTUP

	LD	HL,CMD_ECHO_OFF
	CALL	SEND_CMD

	CALL	DETECT_ESP_FIRMWARE
	CALL	PREPARE_ESP_SESSION

	PRINTLN MSG_SETUP_UART
	CALL	APPLY_UART_SETTING
	CALL	PRINT_UART_CONFIG_OPTIONAL

	PRINTLN MSG_STATION
	CALL	SET_STATION_MODE

	PRINTLN MSG_NO_SLEEP
	LD	HL,CMD_SLEEP_OFF
	CALL	SEND_CMD

	CALL	APPLY_IP_MODE

	PRINT MSG_JOINING
	PRINT NETCFG.CFG_SSID
	PRINT WCOMMON.LINE_END
	CALL	BUILD_CWJAP_CMD
	LD	HL,CMD_BUFF
	LD	BC,JOIN_TIMEOUT
	CALL	SEND_CMD_TIMEOUT

	PRINTLN MSG_IP_INFO
	CALL	QUERY_STATION_INFO

	; Apply optional network settings only after CIFSR/CIPSTA proved that the
	; station and DHCP route are ready.
	CALL	APPLY_DNS_OPTIONAL

	PRINTLN MSG_PUBLISH_ENV
	CALL	PUBLISH_NET_ENV

	PRINTLN MSG_DONE
	LD	B,0
	JP	WCOMMON.EXIT

NO_WIFI
	PRINTLN MSG_WIFI_NOT_FOUND
	LD	B,2
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; NETUP may be invoked through PATH from any current directory. DSS APPINFO
; returns the directory of the loaded EXE, so open NET.CFG beside NETUP.EXE
; instead of resolving a bare name against the caller's current directory.
; Some DSS versions reject APPINFO when the EXE was launched by a bare name;
; then the current directory is necessarily the EXE directory, so use it.
; Out: CF/A as NETCFG.LOAD or NETCFG.LOAD_PATH.
; ------------------------------------------------------
LOAD_CONFIG_FROM_EXE_DIR
	LD	HL,NETUP_CFG_PATH
	LD	B,APPINFO_EXE_HOMEDIR
	LD	C,DSS_APPINFO
	RST	DSS
	JR	C,.FALLBACK

	LD	HL,NETUP_CFG_PATH
	LD	BC,EXE_DIR_SIZE-8		; reserve NET.CFG plus zero terminator
.FIND_END
	LD	A,(HL)
	OR	A
	JR	Z,.HAVE_END
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.FIND_END
	JR	.FALLBACK			; malformed/too-long APPINFO result
.HAVE_END
	LD	A,(NETUP_CFG_PATH)
	OR	A
	JR	Z,.FALLBACK
	DEC	HL
	LD	A,(HL)
	INC	HL
	CP	92			; '\\'
	JR	Z,.APPEND_NAME
	CP	'/'
	JR	Z,.APPEND_NAME
	LD	A,92			; '\\'
	LD	(HL),A
	INC	HL
.APPEND_NAME
	LD	DE,NETUP_CFG_NAME
.COPY_NAME
	LD	A,(DE)
	LD	(HL),A
	INC	DE
	INC	HL
	OR	A
	JR	NZ,.COPY_NAME
	LD	HL,NETUP_CFG_PATH
	JP	NETCFG.LOAD_PATH
.FALLBACK
	JP	NETCFG.LOAD			; bare name in the EXE's current directory

; ------------------------------------------------------
; Print NET.CFG DSS load error without letting DSS_ERROR.EPRINT choose the exit
; status. NETUP uses status 4 for all configuration problems.
; In: A - DSS error code.
; ------------------------------------------------------
PRINT_CONFIG_DSS_ERROR
	PUSH	AF
	PRINT	MSG_CFG_DSS_ERROR
	POP	AF
	CALL	DSS_ERROR.GET_ERR_MSG
	PRINTLN_HL
	RET

; ------------------------------------------------------
; Select an ESP-AT command profile once for this NETUP run.
; AT+SYSSTORE? is the generation probe: a normal ERROR identifies the
; 2.2.1-compatible profile, while a transport failure remains a hard error.
; ESP_AT_FORCE_221 / ESP_AT_FORCE_222 are diagnostic build overrides.
; ------------------------------------------------------
DETECT_ESP_FIRMWARE
	IFDEF	ESP_AT_FORCE_221
	JR	.FW221
	ELSE
	IFDEF	ESP_AT_FORCE_222
	JR	.FW222
	ELSE
	LD	HL,CMD_SYSSTORE_QUERY
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT		; previous command may still be finishing
	AND	A
	JR	Z,.FW222
	CP	RES_ERROR
	JR	Z,.FW221
	JP	COMMAND_ERROR_EXIT
	ENDIF
	ENDIF
.FW221
	LD	A,ESP_FW_221
	LD	(ESP_FW_PROFILE),A
	CALL	WIFI.UART_SET_RX_PROFILE
	PRINTLN MSG_ESP_FW_221
	RET
.FW222
	LD	A,ESP_FW_222
	LD	(ESP_FW_PROFILE),A
	CALL	WIFI.UART_SET_RX_PROFILE
	PRINTLN MSG_ESP_FW_222
	RET

; ------------------------------------------------------
; Keep all 2.2.2 configuration changes in the current session. SYSLOG is
; deliberately best-effort: it improves firmware diagnostics but must not
; prevent a connection if a vendor build does not implement it.
; ------------------------------------------------------
PREPARE_ESP_SESSION
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	RET	NZ
	LD	HL,CMD_SYSSTORE_VOLATILE
	CALL	SEND_CMD
	LD	HL,CMD_SYSLOG_ON
	JP	SEND_CMD_OPTIONAL

; ------------------------------------------------------
; Apply station mode using the profile selected at startup.
; ------------------------------------------------------
SET_STATION_MODE
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	HL,CMD_CWMODE_221
	JR	NZ,.SEND
	LD	HL,CMD_CWMODE_222
.SEND
	JP	SEND_CMD

; ------------------------------------------------------
; Return HL = the station-information query for the selected profile.
; ------------------------------------------------------
GET_CIPSTA_QUERY_CMD
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	HL,CMD_CIPSTA_221_QUERY
	RET	NZ
	LD	HL,CMD_CIPSTA_222_QUERY
	RET

; ------------------------------------------------------
; Apply DHCP or static station IP mode using the selected profile.
; ------------------------------------------------------
APPLY_IP_MODE
	LD	A,(NETCFG.CFG_DHCP)
	CP	'0'
	JR	Z,.STATIC

	PRINTLN MSG_DHCP
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	HL,CMD_DHCP_221
	JR	NZ,.SEND
	LD	HL,CMD_DHCP_222
.SEND
	JP	SEND_CMD

.STATIC
	PRINTLN MSG_STATIC
	CALL	BUILD_CIPSTA_CMD
	LD	HL,CMD_BUFF
	JP	SEND_CMD

; ------------------------------------------------------
; Apply DNS if DNS1 is configured. The selected profile already fixes the
; command form, so there is no per-command fallback.
; ------------------------------------------------------
APPLY_DNS_OPTIONAL
	LD	A,(NETCFG.CFG_DNS1)
	AND	A
	RET	Z
	PRINTLN MSG_DNS
	CALL	BUILD_CIPDNS_CMD
	LD	HL,CMD_BUFF
	CALL	SEND_CMD_OPTIONAL
	RET

; ------------------------------------------------------
; Send command in HL with default timeout.
; ------------------------------------------------------
INIT_UART_CONFIGURED
	CALL	WIFI.UART_FLOW_OFF
	CALL	NETCFG.APPLY_UART_BAUD
	JP	WIFI.UART_INIT

; Flow=0 fallback: the ESP UART is still at the configured baud, but RTS/CTS
; pins are not negotiated. Do not leave the TL16C550 in AFE mode because an
; inactive/floating CTS can block every following AT command.
INIT_UART_CONFIGURED_NO_FLOW
	CALL	WIFI.UART_FLOW_OFF
	CALL	NETCFG.APPLY_UART_BAUD
	JP	WIFI.UART_INIT

INIT_UART_DEFAULT
	CALL	WIFI.UART_FLOW_OFF
	CALL	WIFI.UART_SET_DEFAULT_DIVISOR
	JP	WIFI.UART_INIT

SEND_AT_STARTUP
	LD	HL,CMD_AT
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	Z

	PRINTLN MSG_RESETTING_ESP
	CALL	WIFI.ESP_RESET
	CALL	INIT_UART_DEFAULT
	LD	HL,CMD_AT
	JP	SEND_CMD

APPLY_UART_SETTING
	; Negotiate the ESP UART exactly once per NETUP session, including 115200.
	; Client programs subsequently read NET_BAUD and NET_ESP_FLOW and configure
	; only their local 16550; they must not repeat AT+UART_CUR or toggle AFE in
	; the middle of a live session. Both firmware profiles use the field-proven
	; flow=3 contract whenever the card wiring accepts it. With
	; flow=0 the ESP ignores CTS, so the manual RTS pauses used by every
	; download path stop working on the wire and the RX FIFO overruns at
	; higher bauds. Modules whose RTS/CTS pins are unusable still fall back
	; to the speed-only (flow=0) contract below.
	; Enable FULL hardware flow control (flow=3) when switching baud. This is
	; what gives the host's 16550 auto-flow a working CTS (so AT commands go
	; out) AND lets the ESP pause its TX under load — essential at higher bauds
	; (e.g. 230400) where the Z80 otherwise can't drain the RX FIFO and overruns.
	; The earlier flow=3 failures were the BUILD_UART_CMD bug (malformed command)
	; + a single too-soon verify, both fixed; the post-switch verify now retries.
	; Some ESP-AT 2.2.2 builds accept flow=3 without applying the RTS/CTS pin
	; mux at runtime. Keep high/low configured baud usable on those modules by
	; falling back to flow=0 and disabling local AFE as one matched contract.
	CALL	TRY_UART_WITH_FLOW
	AND	A
	JR	Z,.FLOW_OK

	; A syntactic ERROR/FAIL or persistent busy means AT+UART_CUR was rejected
	; before changing the UART, so it is safe to try the flow=0 form at the
	; current baud. Any other result may mean that ESP changed baud before its
	; final reply was received; do not reset a successfully associated module
	; or blindly send another command at an uncertain baud.
	LD	(UART_VERIFY_RESULT),A
	LD	A,(UART_SET_RESULT)
	CP	RES_ERROR
	JR	Z,.TRY_NO_FLOW
	CP	RES_FAIL
	JR	Z,.TRY_NO_FLOW
	CP	RES_BUSY
	JR	NZ,.SETTING_FAILED
.TRY_NO_FLOW
	PRINTLN	MSG_UART_RETRY_NOFLOW
	CALL	TRY_UART_NO_FLOW
	AND	A
	JR	Z,.SPEED_ONLY_OK

	LD	(UART_VERIFY_RESULT),A
.SETTING_FAILED
	LD	A,(UART_SET_RESULT)
	AND	A
	JR	NZ,.HAVE_ERROR
	LD	A,(UART_VERIFY_RESULT)
.HAVE_ERROR
	PUSH	AF
	CALL	PRINT_ESP_FAILURE
	POP	AF
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT
.FLOW_OK
	LD	A,'3'
	LD	(ESP_FLOW_MODE),A
	PRINTLN	MSG_UART_FLOW_OK
	RET
.SPEED_ONLY_OK
	LD	A,'0'
	LD	(ESP_FLOW_MODE),A
	PRINTLN	MSG_UART_SPEED_ONLY
	RET

TRY_UART_WITH_FLOW
	XOR	A
	LD	(UART_NO_FLOW_VERIFY),A
	CALL	WIFI.UART_FLOW_OFF
	CALL	BUILD_UART_CMD
	JR	TRY_UART_COMMAND

TRY_UART_NO_FLOW
	LD	A,1
	LD	(UART_NO_FLOW_VERIFY),A
	CALL	WIFI.UART_FLOW_OFF
	CALL	BUILD_UART_CMD_NO_FLOW

TRY_UART_COMMAND
	LD	HL,CMD_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT		; previous command may still be finishing
	LD	(UART_SET_RESULT),A
	; ERROR/FAIL means ESP did not accept this command and did not switch
	; baud. A persistent busy also means the command was dropped unexecuted.
	CP	RES_ERROR
	JR	Z,.NO_SWITCH
	CP	RES_FAIL
	JR	Z,.NO_SWITCH
	CP	RES_BUSY
	JR	Z,.NO_SWITCH

	; OK or timeout can both mean ESP accepted the command and changed baud
	; before the final line was received. Switch local UART and verify with AT.
	LD	A,(UART_NO_FLOW_VERIFY)
	AND	A
	JR	NZ,.INIT_NO_FLOW
	CALL	INIT_UART_CONFIGURED
	JR	.VERIFY
.INIT_NO_FLOW
	CALL	INIT_UART_CONFIGURED_NO_FLOW
.VERIFY
	; The ESP sends OK at the OLD baud, then reconfigures its UART to the new
	; speed; that reconfigure is not instantaneous. A single AT 300 ms later
	; can hit the ESP mid-switch and fail (in a terminal the human pause hides
	; this). Retry the AT a few times, settling between attempts, before giving
	; up and recovering to the default baud.
	LD	A,UART_VERIFY_RETRIES
	LD	(UART_VERIFY_LEFT),A
.VLOOP
	LD	HL,UART_SWITCH_SETTLE
	CALL	UTIL.DELAY
	CALL	WIFI.UART_EMPTY_RS
	LD	HL,CMD_AT
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	JR	NZ,.VERIFY_FAILED

	; A successful manual-RTS verification only proves that both UARTs changed
	; baud. For flow=3 builds, enable AFE and prove CTS can release host TX.
	LD	A,(UART_NO_FLOW_VERIFY)
	AND	A
	RET	NZ
	CALL	WIFI.UART_FLOW_ON
	LD	HL,UART_SWITCH_SETTLE
	CALL	UTIL.DELAY
	LD	HL,CMD_AT
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_STATUS_TIMEOUT
	AND	A
	RET	Z
	CALL	WIFI.UART_FLOW_OFF
.VERIFY_FAILED
	LD	(UART_VERIFY_RESULT),A
	LD	A,(UART_VERIFY_LEFT)
	DEC	A
	LD	(UART_VERIFY_LEFT),A
	JR	NZ,.VLOOP
	LD	A,(UART_VERIFY_RESULT)
	RET
.NO_SWITCH
	LD	(UART_VERIFY_RESULT),A
	RET

; CF=0 when NET.CFG BAUD is 115200.
IS_DEFAULT_BAUD
	LD	HL,NETCFG.BAUD_115200
	LD	DE,NETCFG.CFG_BAUD
	JP	UTIL.STRCMP

PRINT_UART_CONFIG_OPTIONAL
	PRINTLN MSG_UART_CONFIG
	LD	HL,CMD_UART_QUERY
	CALL	SEND_CMD_PRINT_STATUS
	AND	A
	RET	Z
	PUSH	AF
	CALL	PRINT_ESP_FAILURE
	POP	AF
	ADD	A,'0'
	LD	(MSG_WARN_NO),A
	PRINTLN MSG_OPTIONAL_WARN
	RET

SEND_CMD
	LD	BC,DEFAULT_TIMEOUT
	JP	SEND_CMD_TIMEOUT

SEND_CMD_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT
	AND	A
	RET	Z
	JP	COMMAND_ERROR_EXIT

; The busy-response retry loop is shared with its host-side Z80 harness.
	INCLUDE "netup_busy_retry.asm"

; ------------------------------------------------------
; Print the actual ESP response before exiting with a command error.
; In: A = RES_* result, WIFI.RS_BUFF = complete/partial response.
; ------------------------------------------------------
COMMAND_ERROR_EXIT
	PUSH	AF
	CALL	PRINT_ESP_FAILURE
	POP	AF
	ADD	A,'0'
	LD	(MSG_ERROR_NO),A
	PRINTLN MSG_COMM_ERROR
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL with timeout in BC.
; Out: A = ESP result code, 0 means OK.
; ------------------------------------------------------
SEND_CMD_STATUS_TIMEOUT
	LD	DE,WIFI.RS_BUFF
	CALL	WIFI.UART_TX_CMD
	RET

; ------------------------------------------------------
; Send non-critical command. Print a warning and continue on failure.
; ------------------------------------------------------
SEND_CMD_OPTIONAL
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT		; IP stack may answer busy post-join
	AND	A
	RET	Z
	PUSH	AF
	CALL	PRINT_ESP_FAILURE
	POP	AF
	ADD	A,'0'
	LD	(MSG_WARN_NO),A
	PRINTLN MSG_OPTIONAL_WARN
	RET

; ------------------------------------------------------
; Send command in HL and print response buffer.
; ------------------------------------------------------
SEND_CMD_PRINT
	CALL	SEND_CMD
	LD	HL,WIFI.RS_BUFF
	JP	PRINT_ESP_RESPONSE

; ------------------------------------------------------
; Verify the just-created Wi-Fi connection and collect the values that will be
; published by PUBLISH_NET_ENV.  AT+CWJAP ending in OK alone is not enough: a
; firmware can still have no station address.  AT+CIFSR and the selected
; AT+CIPSTA query are therefore mandatory here.  Any ESP error exits with B=3
; through SEND_CMD, before NET_* is published.
; ------------------------------------------------------
QUERY_STATION_INFO
	; CWJAP reports OK when the association is up, but the DHCP lease can
	; still be pending. Poll AT+CIFSR until a real station IP shows up instead
	; of failing on the first empty answer: busy replies return immediately
	; now, so nothing else paces this wait.
	LD	A,NETUP_IP_RETRIES
	LD	(IP_WAIT_LEFT),A
	JR	.IP_TRY
.NOT_READY
	LD	A,(IP_WAIT_LEFT)
	AND	A
	JP	Z,NETWORK_NOT_READY_EXIT
	DEC	A
	LD	(IP_WAIT_LEFT),A
	LD	A,(IP_WAIT_SHOWN)
	AND	A
	JR	NZ,.WAIT
	INC	A
	LD	(IP_WAIT_SHOWN),A
	PRINTLN	MSG_WAIT_IP
.WAIT
	LD	HL,NETUP_IP_DELAY
	CALL	UTIL.DELAY
.IP_TRY
	LD	HL,CMD_CIFSR
	LD	BC,DEFAULT_TIMEOUT
	CALL	SEND_CMD_BUSY_TIMEOUT
	AND	A
	JR	Z,.HAVE_RESP
	CP	RES_BUSY
	JR	Z,.NOT_READY			; still busy -> keep waiting
	JP	COMMAND_ERROR_EXIT
.HAVE_RESP
	LD	HL,PAT_STAIP
	LD	DE,NET_IP_BUF
	CALL	EXTRACT_QUOTED_FIELD
	JR	C,.NOT_READY
	LD	HL,LIT_ZERO_IP
	LD	DE,NET_IP_BUF
	CALL	UTIL.STRCMP
	JR	NC,.NOT_READY
	LD	HL,PAT_STAMAC
	LD	DE,NET_MAC_BUF
	CALL	EXTRACT_QUOTED_FIELD
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE

	CALL	GET_CIPSTA_QUERY_CMD
	CALL	SEND_CMD
	LD	HL,PAT_GATEWAY
	LD	DE,NET_GW_BUF
	CALL	EXTRACT_QUOTED_FIELD
	LD	HL,PAT_NETMASK
	LD	DE,NET_MASK_BUF
	CALL	EXTRACT_QUOTED_FIELD
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE
	RET

; AT+CIFSR replied OK but did not expose a usable station address.  This is a
; failed association, not an optional diagnostic failure.
NETWORK_NOT_READY_EXIT
	PRINTLN MSG_NO_STATION_IP
	CALL	PRINT_ESP_FAILURE
	LD	B,3
	JP	WCOMMON.EXIT

; ------------------------------------------------------
; Send command in HL and print response on success.
; Out: A = ESP result code, 0 means response was printed.
; ------------------------------------------------------
SEND_CMD_PRINT_STATUS
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	RET	NZ
.PRINT
	LD	HL,WIFI.RS_BUFF
	CALL	PRINT_ESP_RESPONSE
	XOR	A
	RET

; ------------------------------------------------------
; Send command in HL. If ESP does not answer, reset once and retry.
; ------------------------------------------------------
SEND_CMD_RECOVER
	PUSH	HL
	LD	DE,WIFI.RS_BUFF
	LD	BC,DEFAULT_TIMEOUT
	CALL	WIFI.UART_TX_CMD
	AND	A
	JR	Z,.OK

	PRINTLN MSG_RESETTING_ESP
	CALL	WIFI.ESP_RESET
	CALL	WIFI.UART_INIT
	POP	HL
	JP	SEND_CMD

.OK
	POP	HL
	RET

; ------------------------------------------------------
; Build AT+UART_CUR command from config.
; ------------------------------------------------------
BUILD_UART_CMD
	LD	HL,CMD_BUFF
	LD	DE,CMD_UART_PREFIX
	CALL	APPEND_STR
	; GET_UART_BAUD_TEXT returns HL = baud text and CLOBBERS HL (our CMD_BUFF
	; write position). Save the write position across the call, then load the
	; baud text into IX; otherwise the baud + suffix get written to the wrong
	; address and the command sent is just "AT+UART_CUR=" -> ESP ERROR.
	PUSH	HL
	CALL	NETCFG.GET_UART_BAUD_TEXT
	PUSH	HL
	POP	IX
	POP	HL
	CALL	APPEND_IX_STR
	LD	DE,CMD_UART_SUFFIX
	JP	APPEND_STR

BUILD_UART_CMD_NO_FLOW
	LD	HL,CMD_BUFF
	LD	DE,CMD_UART_PREFIX
	CALL	APPEND_STR
	PUSH	HL
	CALL	NETCFG.GET_UART_BAUD_TEXT
	PUSH	HL
	POP	IX
	POP	HL
	CALL	APPEND_IX_STR
	LD	DE,CMD_UART_SUFFIX_NO_FLOW
	JP	APPEND_STR

; ------------------------------------------------------
; Build the profile-selected AT+CWJAP command from config.
; 2.2.1 uses _CUR; 2.2.2 uses the plain form after SYSSTORE=0.
; ------------------------------------------------------
BUILD_CWJAP_CMD
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	DE,CMD_CWJAP_221_PREFIX
	JR	NZ,.PREFIX_READY
	LD	DE,CMD_CWJAP_222_PREFIX
.PREFIX_READY
	LD	HL,CMD_BUFF
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_SSID
	CALL	APPEND_IX_STR
	LD	DE,CMD_CWJAP_MIDDLE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_PASS
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ------------------------------------------------------
; Build the profile-selected AT+CIPSTA command from config.
; ------------------------------------------------------
BUILD_CIPSTA_CMD
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	DE,CMD_CIPSTA_221_PREFIX
	JR	NZ,.PREFIX_READY
	LD	DE,CMD_CIPSTA_222_PREFIX
.PREFIX_READY
	LD	HL,CMD_BUFF
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_IP
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_COMMA_QUOTE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_GATEWAY
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_COMMA_QUOTE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_NETMASK
	CALL	APPEND_IX_STR
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ------------------------------------------------------
; Build the profile-selected AT+CIPDNS command from config.
; ------------------------------------------------------
BUILD_CIPDNS_CMD
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	DE,CMD_CIPDNS_221_PREFIX
	JR	NZ,.PREFIX_READY
	LD	DE,CMD_CIPDNS_222_PREFIX
.PREFIX_READY
	LD	HL,CMD_BUFF
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_DNS1
	CALL	APPEND_IX_STR
	LD	A,(NETCFG.CFG_DNS2)
	AND	A
	JR	Z,.END
	LD	DE,CMD_QUOTE_COMMA_QUOTE
	CALL	APPEND_STR
	LD	IX,NETCFG.CFG_DNS2
	CALL	APPEND_IX_STR
.END
	LD	DE,CMD_QUOTE_CRLF
	JP	APPEND_STR

; ======================================================
; Publish verified connection parameters to DSS environment variables (NET_*),
; like the rtl8019as NETCFG -i feature, so other programs can read them via DSS
; ENVIRON (#46) after NETUP.  QUERY_STATION_INFO has already completed all ESP
; queries and verified NET_IP_BUF, so this routine cannot turn a failed ESP
; response into a false successful NET=WIFI publication.  An empty value writes
; "NAME=" which DELETES the variable.
;   NET      = WIFI            network-type marker
;   NET_ESP_FW = 2.2.1/2.2.2   selected ESP-AT firmware profile
;   NET_ESP_FLOW = 3/0         negotiated UART flow-control mode
;   NET_IP   = station IP      (AT+CIFSR STAIP)
;   NET_MAC  = station MAC      (AT+CIFSR STAMAC)
;   NET_GW   = gateway          (AT+CIPSTA gateway)
;   NET_MASK = netmask          (AT+CIPSTA netmask)
;   NET_DHCP = 1/0              (NET.CFG)
;   NET_BAUD = UART speed       (NET.CFG)
;   NET_SSID = SSID             (NET.CFG)
;   NET_NTP  = NTP server       (NET.CFG)
;   NET_TZ   = timezone         (NET.CFG)
; ======================================================
PUBLISH_NET_ENV
	LD	HL,N_NET
	LD	IX,LIT_WIFI
	CALL	SETENV_NAME_VAL

	; NET_ESP_HW = "<slot>/#<base>" - ISA slot + UART I/O base, same "S/#HHH"
	; form as the rtl8019as NET_RTL_HW variable. Slot is the raw ISA_SLOT (0/1)
	; used by ISA_OPEN; base is the card's COM3 I/O port.
	CALL	BUILD_ESP_HW
	LD	HL,N_NET_ESP_HW
	LD	IX,ESP_HW_BUF
	CALL	SETENV_NAME_VAL

	; NET_ESP_FW tells consumers whether this run selected the 2.2.1 or
	; 2.2.2 AT profile (and therefore whether 2.2.2-only commands may be used).
	LD	A,(ESP_FW_PROFILE)
	CP	ESP_FW_222
	LD	IX,V_ESP_FW_221
	JR	NZ,.FW_SET
	LD	IX,V_ESP_FW_222
.FW_SET
	LD	HL,N_NET_ESP_FW
	CALL	SETENV_NAME_VAL

	; Publish the negotiated ESP UART contract. Client executables are separate
	; processes and reinitialize the 16550, so they must reproduce this local
	; MCR mode without issuing AT+UART_CUR again.
	LD	A,(ESP_FLOW_MODE)
	CP	'3'
	LD	IX,V_ESP_FLOW_0
	JR	NZ,.FLOW_SET
	LD	IX,V_ESP_FLOW_3
.FLOW_SET
	LD	HL,N_NET_ESP_FLOW
	CALL	SETENV_NAME_VAL

	; Runtime values, collected after the mandatory association check.
	LD	HL,N_NET_IP
	LD	IX,NET_IP_BUF
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_MAC
	LD	IX,NET_MAC_BUF
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_GW
	LD	IX,NET_GW_BUF
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_MASK
	LD	IX,NET_MASK_BUF
	CALL	SETENV_NAME_VAL

	; NET_IP_SRC = STATIC or DHCP (rtl8019as convention; CFG_DHCP is '0'/'1').
	LD	A,(NETCFG.CFG_DHCP)
	CP	'0'
	JR	Z,.SRC_STATIC
	LD	IX,V_DHCP
	JR	.SRC_SET
.SRC_STATIC
	LD	IX,V_STATIC
.SRC_SET
	LD	HL,N_NET_IP_SRC
	CALL	SETENV_NAME_VAL

	; Config-derived values.
	LD	HL,N_NET_DNS1
	LD	IX,NETCFG.CFG_DNS1
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_DNS2
	LD	IX,NETCFG.CFG_DNS2
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_BAUD
	LD	IX,NETCFG.CFG_BAUD
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_SSID
	LD	IX,NETCFG.CFG_SSID
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_NTP
	LD	IX,NETCFG.CFG_NTP
	CALL	SETENV_NAME_VAL
	LD	HL,N_NET_TZ
	LD	IX,NETCFG.CFG_TZ
	CALL	SETENV_NAME_VAL
	RET

; ------------------------------------------------------
; Remove all variables owned by NETUP.  In particular, clear NET before any
; ESP setup begins: callers then cannot mistake a previous successful NETUP
; run for a current connection when this invocation exits with an error.
; Environment errors are deliberately ignored, as SETENV_NAME_VAL has always
; been best-effort and the original connection error must remain the exit code.
; ------------------------------------------------------
CLEAR_NET_ENV
	LD	HL,N_NET
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_ESP_HW
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_ESP_FW
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_ESP_FLOW
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_IP_SRC
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_IP
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_MASK
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_GW
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_MAC
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_DNS1
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_DNS2
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_NTP
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_TZ
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_BAUD
	CALL	CLEAR_ENV_NAME
	LD	HL,N_NET_SSID
	CALL	CLEAR_ENV_NAME
	RET

; In: HL = NET_* variable name.  Empty value removes it from DSS ENVIRON.
CLEAR_ENV_NAME
	LD	IX,LIT_EMPTY
	JP	SETENV_NAME_VAL

; ------------------------------------------------------
; SETENV_NAME_VAL: set env var NAME (HL ASCIIZ) = value (IX ASCIIZ).
; Builds "NAME=VALUE",0 in ENV_BUF, then DSS ENVIRON ENV_SET. Empty value ->
; "NAME=",0 which deletes the variable. Trashes A,BC,DE,HL,IX.
; ------------------------------------------------------
SETENV_NAME_VAL
	PUSH	HL				; name ptr
	LD	HL,ENV_BUF
	POP	DE				; DE = name source
	CALL	APPEND_STR			; copy name; HL -> after name
	LD	A,'='
	LD	(HL),A
	INC	HL
	CALL	APPEND_IX_STR			; copy value; HL -> after value
	LD	(HL),0
	LD	HL,ENV_BUF
	LD	B,ENV_SET
	LD	C,DSS_ENVIRON
	RST	DSS
	RET

; ------------------------------------------------------
; EXTRACT_QUOTED_FIELD: find the ASCIIZ keyword at HL inside WIFI.RS_BUFF, then
; copy the first double-quoted token after it on the same line into DE (ASCIIZ).
; Handles separators between keyword and value (e.g. STAIP,"x" or gateway:"x").
; No match -> dest set empty. Out: CF=0 found, CF=1 not. Trashes A,BC,DE,HL.
; ------------------------------------------------------
EXTRACT_QUOTED_FIELD
	LD	(EXT_PAT),HL
	LD	(EXT_DEST),DE
	LD	DE,WIFI.RS_BUFF
.SCAN
	LD	A,(DE)
	AND	A
	JR	Z,.NOTFOUND
	LD	HL,(EXT_PAT)
	PUSH	DE
.CMP
	LD	A,(HL)
	AND	A
	JR	Z,.MATCHED			; whole keyword matched
	LD	B,A
	LD	A,(DE)
	CP	B
	JR	NZ,.MISMATCH
	INC	HL
	INC	DE
	JR	.CMP
.MISMATCH
	POP	DE
	INC	DE
	JR	.SCAN
.MATCHED
	POP	AF				; drop saved scan position
.FINDQ
	LD	A,(DE)
	AND	A
	JR	Z,.NOTFOUND
	CP	13
	JR	Z,.NOTFOUND
	CP	10
	JR	Z,.NOTFOUND
	CP	'"'
	JR	Z,.GOTQ
	INC	DE
	JR	.FINDQ
.GOTQ
	INC	DE				; past opening quote
	LD	HL,(EXT_DEST)
.COPY
	LD	A,(DE)
	AND	A
	JR	Z,.COPYEND
	CP	'"'
	JR	Z,.COPYEND
	LD	(HL),A
	INC	HL
	INC	DE
	JR	.COPY
.COPYEND
	LD	(HL),0
	OR	A				; CF=0
	RET
.NOTFOUND
	LD	HL,(EXT_DEST)
	LD	(HL),0
	SCF
	RET

; ------------------------------------------------------
; BUILD_ESP_HW: format "<slot>/#<base>" into ESP_HW_BUF (e.g. "1/#3E8").
; Slot is the raw ISA_SLOT (0/1); base is the fixed COM3 UART I/O port.
; ------------------------------------------------------
BUILD_ESP_HW
	LD	A,(ISA.ISA_SLOT)
	ADD	A,'0'
	LD	(ESP_HW_BUF),A
	LD	HL,ESP_HW_BASE
	LD	DE,ESP_HW_BUF+1
.LP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.LP
	RET

	ASSERT PORT_UART == 0x03E8		; keep ESP_HW_BASE digits in sync
ESP_HW_BASE	DB "/#3E8",0

; Variable names match the rtl8019as package (NET_IP_SRC/IP/MASK/GW/MAC/DNS1/
; DNS2/NTP/TZ) so programs read the same vars on either card. NET=WIFI is this
; package's network-type marker, NET_ESP_HW is the slot/I/O-base in the same
; "S/#HHH" form as rtl8019as NET_RTL_HW, NET_ESP_FW is the selected
; 2.2.1/2.2.2 AT profile, and NET_ESP_FLOW is the negotiated ESP UART
; flow-control mode. NET_BAUD and NET_SSID are Wi-Fi-specific additions.
NET_ENV_NAMES
N_NET		DB "NET",0
N_NET_ESP_HW	DB "NET_ESP_HW",0
N_NET_ESP_FW	DB "NET_ESP_FW",0
N_NET_ESP_FLOW	DB "NET_ESP_FLOW",0
N_NET_IP_SRC	DB "NET_IP_SRC",0
N_NET_IP	DB "NET_IP",0
N_NET_MASK	DB "NET_MASK",0
N_NET_GW	DB "NET_GW",0
N_NET_MAC	DB "NET_MAC",0
N_NET_DNS1	DB "NET_DNS1",0
N_NET_DNS2	DB "NET_DNS2",0
N_NET_NTP	DB "NET_NTP",0
N_NET_TZ	DB "NET_TZ",0
N_NET_BAUD	DB "NET_BAUD",0
N_NET_SSID	DB "NET_SSID",0
LIT_WIFI	DB "WIFI",0
LIT_EMPTY	DB 0
LIT_ZERO_IP	DB "0.0.0.0",0
V_ESP_FW_221	DB "2.2.1",0
V_ESP_FW_222	DB "2.2.2",0
V_ESP_FLOW_0	DB "0",0
V_ESP_FLOW_3	DB "3",0
V_STATIC	DB "STATIC",0
V_DHCP		DB "DHCP",0
PAT_STAIP	DB "STAIP",0
PAT_STAMAC	DB "STAMAC",0
PAT_GATEWAY	DB "gateway",0
PAT_NETMASK	DB "netmask",0

; Shared with the host-side command-builder harness. Every append copies its
; trailing zero, so UART_TX_STRING cannot run past a dynamic command into dirty
; runtime BSS and feed a second line to ESP while the first is still executing.
	INCLUDE "asciiz_append.asm"

; ------------------------------------------------------
; Print ESP response buffer with LF -> CRLF conversion.
; ------------------------------------------------------
PRINT_ESP_FAILURE
	PRINTLN MSG_ESP_RESPONSE
	LD	HL,WIFI.RS_BUFF
	JP	PRINT_ESP_RESPONSE

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

MSG_START
	DB "NETUP "
	PACKAGE_VERSION_TAG
	DB " - bring SprinterESP network up"
	DB 0
MSG_NO_CFG
	DB "NET.CFG not found. Run NETCFG /W first.",0
MSG_NO_SSID
	DB "SSID is empty. Run NETCFG /W first.",0
MSG_CFG_DSS_ERROR
	DB "NET.CFG error: ",0
MSG_WIFI_NOT_FOUND
	DB "Sprinter-WiFi not found!",0
MSG_UART_READY
	DB "UART initialized.",0
MSG_ESP_FW_221
	DB "ESP firmware profile: 2.2.1.",0
MSG_ESP_FW_222
	DB "ESP firmware profile: 2.2.2.",0
MSG_RESETTING_ESP
	DB "ESP did not answer, resetting module.",0
MSG_SETUP_UART
	DB "Setting ESP UART speed/flow control.",0
MSG_UART_CONFIG
	DB "ESP UART config:",0
MSG_UART_DEFAULT
	DB "Using default ESP UART speed.",0
MSG_UART_RETRY_NOFLOW
	DB "RTS/CTS setup failed, retrying speed-only.",0
MSG_UART_FLOW_OK
	DB "UART speed set with RTS/CTS flow control.",0
MSG_UART_SPEED_ONLY
	DB "UART speed set WITHOUT flow control.",0
MSG_STATION
	DB "Setting station mode.",0
MSG_NO_SLEEP
	DB "Disabling ESP sleep.",0
MSG_DHCP
	DB "Enabling DHCP.",0
MSG_STATIC
	DB "Applying static IP settings.",0
MSG_DNS
	DB "Applying DNS settings (optional).",0
MSG_JOINING
	DB "Connecting to SSID: ",0
MSG_IP_INFO
	DB "IP information:",0
MSG_NO_STATION_IP
	DB "ESP has no station IP; Wi-Fi connection is not ready.",0
MSG_WAIT_IP
	DB "Waiting for station IP (DHCP)...",0
MSG_PUBLISH_ENV
	DB "Publishing NET_* environment variables.",0
MSG_DONE
	DB "NETUP done.",0
MSG_COMM_ERROR
	DB "ESP communication error #"
MSG_ERROR_NO
	DB "n!",0
MSG_ESP_RESPONSE
	DB "ESP response:",0
MSG_OPTIONAL_WARN
	DB "Optional ESP command failed #"
MSG_WARN_NO
	DB "n, continuing.",0

UART_SET_RESULT
	DB 0
UART_VERIFY_RESULT
	DB 0
UART_NO_FLOW_VERIFY
	DB 0
ESP_FLOW_MODE
	DB '0'
UART_VERIFY_LEFT
	DB 0
IP_WAIT_LEFT
	DB 0
IP_WAIT_SHOWN
	DB 0

CMD_AT
	DB "AT",13,10,0
CMD_ECHO_OFF
	DB "ATE0",13,10,0
CMD_SYSSTORE_QUERY
	DB "AT+SYSSTORE?",13,10,0
CMD_SYSSTORE_VOLATILE
	DB "AT+SYSSTORE=0",13,10,0
CMD_SYSLOG_ON
	DB "AT+SYSLOG=1",13,10,0
CMD_UART_PREFIX
	DB "AT+UART_CUR=",0
CMD_UART_SUFFIX
	DB ",8,1,0,3",13,10,0
CMD_UART_SUFFIX_NO_FLOW
	DB ",8,1,0,0",13,10,0
CMD_UART_QUERY
	DB "AT+UART_CUR?",13,10,0
CMD_CWMODE_221
	DB "AT+CWMODE_CUR=1",13,10,0
CMD_CWMODE_222
	DB "AT+CWMODE=1,0",13,10,0
CMD_SLEEP_OFF
	DB "AT+SLEEP=0",13,10,0
CMD_DHCP_221
	DB "AT+CWDHCP_CUR=1,1",13,10,0
CMD_DHCP_222
	DB "AT+CWDHCP=1,1",13,10,0
CMD_CIFSR
	DB "AT+CIFSR",13,10,0
CMD_CIPSTA_221_QUERY
	DB "AT+CIPSTA_CUR?",13,10,0
CMD_CIPSTA_222_QUERY
	DB "AT+CIPSTA?",13,10,0

CMD_CWJAP_221_PREFIX
	DB "AT+CWJAP_CUR=",34,0
CMD_CWJAP_222_PREFIX
	DB "AT+CWJAP=",34,0
CMD_CWJAP_MIDDLE
	DB 34,",",34,0
CMD_CIPSTA_221_PREFIX
	DB "AT+CIPSTA_CUR=",34,0
CMD_CIPSTA_222_PREFIX
	DB "AT+CIPSTA=",34,0
CMD_CIPDNS_221_PREFIX
	DB "AT+CIPDNS_CUR=1,",34,0
CMD_CIPDNS_222_PREFIX
	DB "AT+CIPDNS=1,",34,0
CMD_QUOTE_COMMA_QUOTE
	DB 34,",",34,0
CMD_QUOTE_CRLF
	DB 34,13,10,0
NETUP_CFG_NAME
	DB "NET.CFG",0

	ENDMODULE

	INCLUDE "wcommon.asm"
	INCLUDE "dss_error.asm"
	INCLUDE "isa.asm"
	DEFINE NETCFG_ENABLE_LOAD_PATH
	INCLUDE "netcfg_lib.asm"
	INCLUDE "esplib.asm"

	MODULE MAIN

CMD_BUFF	EQU NETCFG.NETCFG_BSS_END
ENV_BUF		EQU CMD_BUFF + 256		; "NAME=VALUE",0 scratch for ENV_SET
NET_IP_BUF	EQU ENV_BUF + 96		; parsed station IP (ASCIIZ)
NET_MAC_BUF	EQU NET_IP_BUF + 24		; parsed station MAC
NET_GW_BUF	EQU NET_MAC_BUF + 24		; parsed gateway
NET_MASK_BUF	EQU NET_GW_BUF + 24		; parsed netmask
EXT_PAT		EQU NET_MASK_BUF + 24		; EXTRACT_QUOTED_FIELD: keyword ptr
EXT_DEST	EQU EXT_PAT + 2			; EXTRACT_QUOTED_FIELD: dest ptr
ESP_HW_BUF	EQU EXT_DEST + 2		; "<slot>/#<base>" (NET_ESP_HW)
ESP_FW_PROFILE	EQU ESP_HW_BUF + 16	; ESP_FW_221 / ESP_FW_222 selected at startup
NETUP_CFG_PATH	EQU ESP_FW_PROFILE + 1	; DSS APPINFO executable directory + NET.CFG
NETUP_BSS_END	EQU NETUP_CFG_PATH + EXE_DIR_SIZE
	ASSERT	NETUP_BSS_END < 0xC000

	ENDMODULE

	END MAIN.START
