; ======================================================
; RACETEST - hardware stress test for the SEND-during-race receive-defer path.
;
;   RACETEST [-d FILE.DLL] HOST [PORT]
;
; Loads a UNET DLL (default UNETESP.DLL) via libman, brings the link up, opens a
; TCP connection to a "race server" (tools/race_server.py) that continuously
; streams a known incrementing byte sequence, then repeatedly SENDs a dummy
; payload while draining RECV. Any peer bytes that arrive in the CIPSEND '>' /
; SEND OK window must be captured by the DLL's defer buffer and replayed to the
; next RECV in order. RACETEST verifies the WHOLE received stream is an unbroken
; increasing sequence: if the defer path dropped or reordered a byte, continuity
; breaks and the test FAILs, pinpointing the offset.
;
; This is a DEVELOPER tool. It is NOT part of the distribution (absent from
; tools/artifacts.sh); build it on demand with `make racetest`. Like UNETTEST it
; runs at ORG 0x8100 (window 2) so the DLL owns window 1.
;
; Exit codes: 0 PASS, 1 usage, 2 hardware/DLL load, 3 comm/protocol/FAIL,
;             4 network not configured.
; ======================================================

EXE_VERSION	EQU 1

; Test parameters. The loop is RECV-dominant: it drains SEND_EVERY blocks, then
; injects one SEND (the race window). Draining must dominate so the inbound
; stream never backs up in the ESP - otherwise each SEND's prompt/SEND-OK wait
; has to wade through a growing backlog byte-by-byte and the run wedges. Pair
; with a paced race_server.py (its rate must stay below the UART line rate so
; the client can stay ahead).
STOP_BYTES	EQU 32768		; stop once this many bytes have been verified
SEND_EVERY	EQU 4			; drain this many RECV blocks per SEND (race window)
SEND_SIZE	EQU 64			; dummy payload per SEND (widens the window)
RECV_TIMEOUT	EQU 2000

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"
	INCLUDE "unet.inc"

	MODULE MAIN

	ORG 0x8080

EXE_HEADER
	DB "EXE"
	DB EXE_VERSION
	DW 0x0080			; code file offset
	DW 0
	DW 0
	DW 0
	DW 0
	DW 0
	DW START			; load address
	DW START			; entry point
	DW STACK_TOP			; initial stack
	DS 106, 0

	ORG 0x8100

START
	LD	(CMDLINE_PTR),IX
	LD	SP,STACK_TOP

	LD	HL,MSG_BANNER
	CALL	PUTS_LN

	CALL	PARSE_ARGS

	; --- resolve + load the DLL into window 1 ---
	CALL	RESOLVE_DLL_PATH
	CALL	SAY_LOADING
	LD	A,1
	CALL	LIBMAN.l_load
	JR	NC,.LOADED
	LD	A,(USED_EXEDIR)
	OR	A
	JP	Z,ERR_LOAD
	LD	A,(LIBMAN.l_reason)
	CP	LIBMAN.LR_OPEN
	JP	NZ,ERR_LOAD
	LD	HL,DLL_NAME
	CALL	SAY_LOADING
	LD	A,1
	CALL	LIBMAN.l_load
	JP	C,ERR_LOAD
.LOADED
	LD	(HANDLE),HL

	; --- l_info: name + version ---
	LD	HL,(HANDLE)
	LD	DE,INFO_BUF
	CALL	LIBMAN.l_info
	JP	C,ERR_INFO
	LD	HL,MSG_DLL
	CALL	PUTS
	LD	HL,INFO_BUF + 16
	CALL	PUTS
	CALL	CRLF

	CALL	SNAPSHOT_DLL
	JP	C,ERR_SNAPSHOT

	; --- GETCAPS + ABI sanity (as UNETTEST) ---
	LD	B,UNET_FN_GETCAPS
	CALL	DO_CALL
	LD	(CAPS),DE
	PUSH	IX
	POP	HL
	LD	(ABI_VERSION),HL
	LD	A,(ABI_VERSION + 1)
	CP	HIGH UNET_ABI_VERSION
	JP	NZ,ERR_BAD_IMAGE
	LD	A,(CAPS)
	AND	UNET_CAP_TCP
	JP	Z,ERR_BAD_IMAGE

	; --- SETOPT CANCELKEYS=1 (Esc/Ctrl+Z aborts blocking calls) ---
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,1
	LD	B,UNET_FN_SETOPT
	CALL	DO_CALL

	; --- NETINIT ---
	LD	B,UNET_FN_NETINIT
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_NETINIT
	LD	HL,MSG_NETUP
	CALL	PUTS_LN

	; --- CONNECT host:port ---
	LD	HL,MSG_CONNECT
	CALL	PUTS
	LD	HL,HOST_BUFF
	CALL	PUTS
	LD	A,':'
	CALL	PUT_CHAR
	LD	HL,PORT_BUFF
	CALL	PUTS_LN
	XOR	A				; channel 0
	LD	DE,HOST_BUFF
	LD	IX,PORT_BUFF
	LD	B,UNET_FN_CONNECT
	CALL	DO_CALL
	OR	A
	JP	NZ,ERR_CONNECT

	CALL	RACE_LOOP			; runs the test, prints the verdict

	; --- CLOSE / NETDONE / free ---
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	B,UNET_FN_NETDONE
	CALL	DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_free

	LD	A,(FAIL_FLAG)
	AND	A
	JR	NZ,.verdict_fail
	LD	A,(NODATA_FLAG)
	AND	A
	JR	NZ,.verdict_nodata
	LD	HL,MSG_PASS
	CALL	PUTS_LN
	LD	B,0
	JP	EXIT
.verdict_fail
	LD	B,3
	JP	EXIT
.verdict_nodata
	LD	B,3
	JP	EXIT

; ======================================================
; Race loop: SEND a dummy payload, RECV, verify the received bytes continue the
; server's incrementing sequence. Prints the stats line and (on mismatch) the
; failure detail. Sets FAIL_FLAG / NODATA_FLAG for the caller's exit code.
; ======================================================
RACE_LOOP
	LD	HL,0
	LD	(TOTAL),HL
	LD	(ITERS),HL
	LD	(LOST_COUNT),HL
	LD	A,1
	LD	(NEED_ANCHOR),A
	XOR	A
	LD	(BLOCKS_SINCE),A
	LD	(FAIL_FLAG),A
	LD	(NODATA_FLAG),A
.loop
	LD	HL,(TOTAL)
	LD	DE,STOP_BYTES
	OR	A
	SBC	HL,DE
	JP	NC,.finish			; verified enough bytes

	; RECV one block (draining dominates so the stream never backs up)
	XOR	A				; channel 0
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,RECV_TIMEOUT
	LD	B,UNET_FN_RECV
	CALL	DO_CALL				; A=status, DE=got, IX=flags
	; count "data lost" (bit2) reports
	PUSH	AF
	PUSH	DE
	PUSH	IX
	POP	HL
	LD	A,L
	AND	4
	JR	Z,.nolost
	LD	HL,(LOST_COUNT)
	INC	HL
	LD	(LOST_COUNT),HL
.nolost
	POP	DE
	POP	AF

	CP	NERR_OK
	JR	Z,.ok
	CP	NERR_CLOSED
	JP	Z,.closed
	JP	.recv_bad
.ok
	LD	A,D
	OR	E
	JR	Z,.send				; nothing queued -> open a race window
	CALL	.consume
	LD	A,(BLOCKS_SINCE)
	INC	A
	LD	(BLOCKS_SINCE),A
	CP	SEND_EVERY
	JP	C,.loop				; keep draining
.send
	; One SEND: peer bytes arriving during its CIPSEND handshake must be
	; captured by the defer buffer and replayed by the next RECV in order.
	XOR	A
	LD	(BLOCKS_SINCE),A
	LD	A,'.'
	CALL	PUT_CHAR
	XOR	A				; channel 0
	LD	DE,SEND_BUF
	LD	IX,SEND_SIZE
	LD	B,UNET_FN_SEND
	CALL	DO_CALL
	OR	A
	JP	NZ,.send_bad
	LD	HL,(ITERS)
	INC	HL
	LD	(ITERS),HL
	JP	.loop
.closed
	LD	A,D
	OR	E
	JP	Z,.finish
	CALL	.consume
	JP	.finish

; Add DE bytes at RECV_BUF to TOTAL and verify continuity.
.consume
	LD	HL,(TOTAL)
	ADD	HL,DE
	LD	(TOTAL),HL
	LD	B,D
	LD	C,E				; BC = count
	LD	DE,RECV_BUF
	JP	CHECK_BYTES

.send_bad
	; NERR_CANCEL (user abort) is not a failure of the code under test.
	CP	NERR_CANCEL
	JR	Z,.finish
	LD	HL,MSG_SEND_ERR
	CALL	PUTS_LN
	JR	.finish
.recv_bad
	LD	HL,MSG_RECV_ERR
	CALL	PUTS_LN
	; fall through to finish

.finish
	CALL	CRLF				; close the progress-dots line
	; stats line: "race: <TOTAL> bytes in <ITERS> sends, lost=<LOST_COUNT>"
	LD	HL,MSG_STATS
	CALL	PUTS
	LD	HL,(TOTAL)
	CALL	PUT_DEC_HL
	LD	HL,MSG_STATS2
	CALL	PUTS
	LD	HL,(ITERS)
	CALL	PUT_DEC_HL
	LD	HL,MSG_STATS3
	CALL	PUTS
	LD	HL,(LOST_COUNT)
	CALL	PUT_DEC_HL
	CALL	CRLF

	LD	HL,(TOTAL)
	LD	A,H
	OR	L
	JR	NZ,.have_data
	LD	A,1
	LD	(NODATA_FLAG),A
	LD	HL,MSG_NODATA
	CALL	PUTS_LN
	RET
.have_data
	LD	A,(FAIL_FLAG)
	AND	A
	RET	Z				; PASS printed by the caller
	; mismatch detail
	LD	HL,MSG_FAIL
	CALL	PUTS
	LD	A,(FAIL_EXPECT)
	CALL	PUT_HEX8
	LD	HL,MSG_FAIL2
	CALL	PUTS
	LD	A,(FAIL_GOT)
	CALL	PUT_HEX8
	LD	HL,MSG_FAIL3
	CALL	PUTS
	LD	HL,(FAIL_AT)
	CALL	PUT_DEC_HL
	JP	CRLF

; ======================================================
; Verify BC bytes at (DE) continue the incrementing byte stream.
; First byte anchors EXPECT; each later byte must equal EXPECT, then
; EXPECT := (byte+1) & 0xFF (resync so one gap = one recorded mismatch).
; Records only the FIRST mismatch (FAIL_EXPECT/FAIL_GOT/FAIL_AT).
; ======================================================
CHECK_BYTES
	LD	A,B
	OR	C
	RET	Z
.loop
	LD	A,(DE)
	LD	L,A				; L = received byte
	LD	A,(NEED_ANCHOR)
	AND	A
	JR	Z,.check
	XOR	A
	LD	(NEED_ANCHOR),A
	JR	.resync
.check
	LD	A,(EXPECT)
	CP	L
	JR	Z,.resync
	; mismatch - record the first one only
	LD	A,(FAIL_FLAG)
	AND	A
	JR	NZ,.resync
	LD	A,1
	LD	(FAIL_FLAG),A
	LD	A,(EXPECT)
	LD	(FAIL_EXPECT),A
	LD	A,L
	LD	(FAIL_GOT),A
	; position = TOTAL - BC (BC still counts current byte)
	PUSH	HL
	LD	HL,(TOTAL)
	OR	A
	SBC	HL,BC
	LD	(FAIL_AT),HL
	POP	HL
.resync
	LD	A,L
	INC	A
	LD	(EXPECT),A			; EXPECT := (received+1) & 0xFF
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.loop
	RET

; ======================================================
; Error exits (trimmed copies of the UNETTEST diagnostics).
; ======================================================
ERR_LOAD
	LD	HL,MSG_ERR_LOAD
	CALL	PUTS_LN
	LD	A,(LIBMAN.l_reason)
	CP	LIBMAN.LR_OPEN
	JR	Z,.OPEN
	CP	LIBMAN.LR_FORMAT
	JR	Z,.FMT
	CP	LIBMAN.LR_INIT
	JR	Z,.INIT
	CP	LIBMAN.LR_MEMORY
	JR	Z,.MEM
	LD	HL,MSG_LOAD_IO
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.OPEN
	LD	HL,MSG_LOAD_OPEN
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.MEM
	LD	HL,MSG_LOAD_MEM
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
	JR	.OUT
.FMT
	LD	HL,MSG_LOAD_FMT
	CALL	PUTS_LN
	JR	.OUT
.INIT
	LD	HL,MSG_LOAD_INIT
	CALL	PUTS
	CALL	PRINT_LOAD_CODE
.OUT
	LD	B,2
	JP	EXIT

ERR_INFO
	LD	HL,MSG_ERR_INFO
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT

PRINT_LOAD_CODE
	LD	HL,MSG_LOAD_CODE
	CALL	PUTS
	LD	A,(LIBMAN.l_dsserr)
	CALL	PUT_DEC_A
	LD	A,')'
	CALL	PUT_CHAR
	JP	CRLF

ERR_SNAPSHOT
	LD	HL,MSG_ERR_SNAPSHOT
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT

ERR_BAD_IMAGE
	LD	HL,MSG_ERR_BAD_IMAGE
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT

ERR_NETINIT
	CP	NERR_NONET
	JR	Z,.cfg
	CP	NERR_HW
	JR	Z,.hw
	LD	HL,MSG_ERR_NETINIT
	CALL	PUTS_LN
	LD	B,3
	JP	EXIT
.cfg
	LD	HL,MSG_ERR_NONET
	CALL	PUTS_LN
	LD	B,4
	JP	EXIT
.hw
	LD	HL,MSG_ERR_HW
	CALL	PUTS_LN
	LD	B,2
	JP	EXIT

ERR_CONNECT
	LD	HL,MSG_ERR_CONNECT
	CALL	PUTS_LN
	CALL	FREE_AND_DONE
	LD	B,3
	JP	EXIT

USAGE_EXIT
	LD	HL,MSG_USAGE
	CALL	PUTS_LN
	LD	B,1
	JP	EXIT

FREE_AND_DONE
	XOR	A
	LD	B,UNET_FN_CLOSE
	CALL	DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_free
	RET

EXIT
	LD	C,DSS_EXIT
	RST	DSS

; ======================================================
; libman call helper (args in A/DE/IX/IY, B = function number).
; ======================================================
DO_CALL
	LD	HL,(HANDLE)
	CALL	LIBMAN.l_call
	RET	NC
	LD	HL,MSG_ERR_CALL
	CALL	PUTS
	LD	A,(LIBMAN.l_call_error)
	CALL	PUT_DEC_A
	CALL	CRLF
	LD	B,2
	JP	EXIT

; ======================================================
; Snapshot the first 256 bytes of the relocated DLL image (verbatim from
; UNETTEST: makes a damaged export table fail loudly rather than hang DSS).
; ======================================================
SNAPSHOT_DLL
	XOR	A
	LD	(SNAPSHOT_DSS_ERROR),A
	LD	HL,(HANDLE)
	LD	A,L
	ADD	A,A
	ADD	A,A
	LD	L,A
	LD	H,0
	LD	DE,LIBMAN.lib_table
	ADD	HL,DE
	LD	A,(HL)
	OR	A
	SCF
	RET	Z
	INC	HL
	LD	B,(HL)
	INC	HL
	LD	A,(HL)
	OR	0xC0
	LD	H,A
	LD	L,0
	IN	A,(0xE2)
	LD	(SNAPSHOT_OLD_WIN),A
	PUSH	HL
	LD	A,B
	LD	BC,0x003B			; DSS_SETWIN3, page 0
	RST	DSS
	POP	HL
	JR	C,.map_error
	LD	DE,DLL_PROBE
	LD	BC,DLL_PROBE_SIZE
	LDIR
	LD	A,(SNAPSHOT_OLD_WIN)
	OUT	(0xE2),A
	OR	A
	RET
.map_error
	LD	(SNAPSHOT_DSS_ERROR),A
	LD	A,(SNAPSHOT_OLD_WIN)
	OUT	(0xE2),A
	SCF
	RET

; ======================================================
; Command line:  [-d FILE.DLL] HOST [PORT]
; ======================================================
PARSE_ARGS
	LD	HL,DEF_DLL
	LD	DE,DLL_NAME
	CALL	STRCPY
	LD	HL,DEF_HOST
	LD	DE,HOST_BUFF
	CALL	STRCPY
	LD	HL,DEF_PORT
	LD	DE,PORT_BUFF
	CALL	STRCPY
	XOR	A
	LD	(DLL_ARG_FLAG),A
	LD	HL,(CMDLINE_PTR)
	LD	A,(HL)
	LD	(PARSE_LEFT),A
	INC	HL
	LD	(PARSE_PTR),HL
.next_flag
	LD	DE,TOKEN_BUF
	LD	C,TOKEN_BUF_SIZE
	CALL	NEXT_TOKEN
	RET	C
	LD	A,(TOKEN_BUF)
	CP	'-'
	JR	NZ,.host_is_tok
	LD	HL,TOKEN_BUF
	LD	DE,STR_DASH_D
	CALL	STREQ
	JR	Z,.flag_d
	JP	USAGE_EXIT
.flag_d
	LD	DE,DLL_NAME
	LD	C,DLL_NAME_SIZE
	CALL	NEXT_TOKEN
	JP	C,USAGE_EXIT
	LD	A,1
	LD	(DLL_ARG_FLAG),A
	JR	.next_flag
.host_is_tok
	LD	HL,TOKEN_BUF
	LD	DE,HOST_BUFF
	CALL	STRCPY
	LD	DE,PORT_BUFF
	LD	C,PORT_BUFF_SIZE
	CALL	NEXT_TOKEN
	RET

RESOLVE_DLL_PATH
	XOR	A
	LD	(USED_EXEDIR),A
	LD	A,(DLL_ARG_FLAG)
	OR	A
	JR	NZ,.BARE
	LD	HL,DLL_PATH
	LD	B,APPINFO_EXE_HOMEDIR
	LD	C,DSS_APPINFO
	RST	DSS
	JR	C,.BARE
	LD	HL,DLL_PATH
	LD	BC,DLL_PATH_SIZE - DLL_DEF_RESERVE
.FIND_END
	LD	A,(HL)
	OR	A
	JR	Z,.HAVE_END
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.FIND_END
	JR	.BARE
.HAVE_END
	LD	A,(DLL_PATH)
	OR	A
	JR	Z,.BARE
	DEC	HL
	LD	A,(HL)
	INC	HL
	CP	92
	JR	Z,.APPEND
	CP	'/'
	JR	Z,.APPEND
	LD	(HL),92
	INC	HL
.APPEND
	EX	DE,HL
	LD	HL,DLL_NAME
	CALL	STRCPY
	LD	A,1
	LD	(USED_EXEDIR),A
	LD	HL,DLL_PATH
	RET
.BARE
	LD	HL,DLL_NAME
	RET

SAY_LOADING
	PUSH	HL
	LD	HL,MSG_LOADING
	CALL	PUTS
	POP	HL
	PUSH	HL
	CALL	PUTS_LN
	POP	HL
	RET

NEXT_TOKEN
	PUSH	DE
	DEC	C
.skip
	LD	A,(PARSE_LEFT)
	AND	A
	JR	Z,.none
	LD	HL,(PARSE_PTR)
	LD	A,(HL)
	CP	0x21
	JR	NC,.start
	CALL	.advance
	JR	.skip
.start
	POP	DE
	PUSH	DE
.copy
	LD	A,(PARSE_LEFT)
	AND	A
	JR	Z,.end
	LD	HL,(PARSE_PTR)
	LD	A,(HL)
	CP	0x21
	JR	C,.end
	INC	C
	DEC	C
	JR	Z,.nostore
	LD	(DE),A
	INC	DE
	DEC	C
.nostore
	CALL	.advance
	JR	.copy
.end
	XOR	A
	LD	(DE),A
	POP	DE
	AND	A
	RET
.none
	POP	DE
	SCF
	RET
.advance
	LD	HL,(PARSE_PTR)
	INC	HL
	LD	(PARSE_PTR),HL
	LD	A,(PARSE_LEFT)
	DEC	A
	LD	(PARSE_LEFT),A
	RET

; ======================================================
; Small string / print helpers (verbatim from UNETTEST).
; ======================================================
STRCPY
	LD	A,(HL)
	LD	(DE),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	STRCPY

STREQ
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	CP	C
	RET	NZ
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	STREQ

PUTS
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PCHARS
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	RET

PUTS_LN
	CALL	PUTS
CRLF
	LD	HL,MSG_CRLF
	JR	PUTS

PUT_CHAR
	PUSH	AF
	PUSH	BC
	PUSH	DE
	PUSH	HL
	LD	C,DSS_PUTCHAR
	RST	DSS
	POP	HL
	POP	DE
	POP	BC
	POP	AF
	RET

PUT_HEX8
	PUSH	AF
	RRA
	RRA
	RRA
	RRA
	CALL	.nib
	POP	AF
.nib
	AND	0x0F
	ADD	A,0x90
	DAA
	ADC	A,0x40
	DAA
	JP	PUT_CHAR

PUT_DEC_A
	LD	L,A
	LD	H,0
PUT_DEC_HL
	LD	DE,DEC_BUF + 6
	XOR	A
	LD	(DE),A
.next
	DEC	DE
	CALL	DIV10_HL
	ADD	A,'0'
	LD	(DE),A
	LD	A,H
	OR	L
	JR	NZ,.next
	EX	DE,HL
	JP	PUTS

DIV10_HL
	PUSH	BC
	LD	BC,0x0D0A
	XOR	A
	ADD	HL,HL
	RLA
	ADD	HL,HL
	RLA
	ADD	HL,HL
	RLA
.dl1
	ADD	HL,HL
	RLA
	CP	C
	JR	C,.dl2
	SUB	C
	INC	L
.dl2
	DJNZ	.dl1
	POP	BC
	RET

; ======================================================
; Strings
; ======================================================
MSG_BANNER	DB "RACETEST - SEND-race defer stress (TCP)",0
MSG_USAGE	DB "Usage: RACETEST [-d FILE.DLL] HOST [PORT]",0
MSG_LOADING	DB "Loading ",0
MSG_DLL		DB "DLL: ",0
MSG_NETUP	DB "NETINIT ok",0
MSG_CONNECT	DB "connect ",0
MSG_STATS	DB "race: ",0
MSG_STATS2	DB " bytes in ",0
MSG_STATS3	DB " sends, lost=",0
MSG_PASS	DB "PASS: stream continuous (defer preserved order)",0
MSG_FAIL	DB "FAIL: expected 0x",0
MSG_FAIL2	DB " got 0x",0
MSG_FAIL3	DB " at byte ",0
MSG_NODATA	DB "no data - is the race server streaming on this port?",0
MSG_SEND_ERR	DB "send error (stopping)",0
MSG_RECV_ERR	DB "receive error (stopping)",0
MSG_ERR_LOAD	DB "Cannot load DLL:",0
MSG_LOAD_OPEN	DB "DLL file not found",0
MSG_LOAD_MEM	DB "out of DSS memory",0
MSG_LOAD_IO	DB "DLL read/seek error",0
MSG_LOAD_FMT	DB "not an L0/L1 DLL (bad file format)",0
MSG_LOAD_INIT	DB "DLL refused to start (wrong window?)",0
MSG_LOAD_CODE	DB " (code ",0
MSG_ERR_INFO	DB "DLL loaded but info query failed.",0
MSG_ERR_CALL	DB "LibMan call failed, stage ",0
MSG_ERR_SNAPSHOT	DB "Cannot inspect loaded DLL.",0
MSG_ERR_BAD_IMAGE	DB "Invalid DLL ABI/capabilities.",0
MSG_ERR_NETINIT	DB "NETINIT failed.",0
MSG_ERR_NONET	DB "Network not configured - run NETUP first.",0
MSG_ERR_HW	DB "Network hardware not found.",0
MSG_ERR_CONNECT	DB "Connect failed.",0
MSG_CRLF	DB 13,10,0

DEF_DLL		DB "UNETESP.DLL",0
DEF_HOST	DB "192.168.1.10",0
DEF_PORT	DB "9099",0
STR_DASH_D	DB "-d",0

; Dummy SEND payload (content irrelevant; the server discards it). Fixed at
; SEND_SIZE bytes so the CIPSEND window is a predictable width.
SEND_BUF	DS SEND_SIZE, 'X'

	ENDMODULE

; ======================================================
; Embedded libman 1.3 loader
; ======================================================
	INCLUDE "libman13.asm"

; ======================================================
; BSS - after all code, inside window 2.
; ======================================================
	MODULE MAIN

RECV_BUF_SIZE	EQU 1024
TOKEN_BUF_SIZE	EQU 64
DLL_NAME_SIZE	EQU 128
DLL_PATH_SIZE	EQU 272
DLL_DEF_RESERVE	EQU 16
HOST_BUFF_SIZE	EQU 64
PORT_BUFF_SIZE	EQU 16

BSS_BASE	EQU $
HANDLE		EQU BSS_BASE
CAPS		EQU HANDLE + 2
ABI_VERSION	EQU CAPS + 2
CMDLINE_PTR	EQU ABI_VERSION + 2
PARSE_PTR	EQU CMDLINE_PTR + 2
PARSE_LEFT	EQU PARSE_PTR + 2
DLL_ARG_FLAG	EQU PARSE_LEFT + 1
USED_EXEDIR	EQU DLL_ARG_FLAG + 1
; race state
TOTAL		EQU USED_EXEDIR + 1
ITERS		EQU TOTAL + 2
LOST_COUNT	EQU ITERS + 2
FAIL_AT		EQU LOST_COUNT + 2
EXPECT		EQU FAIL_AT + 2
BLOCKS_SINCE	EQU EXPECT + 1
NEED_ANCHOR	EQU BLOCKS_SINCE + 1
FAIL_FLAG	EQU NEED_ANCHOR + 1
FAIL_EXPECT	EQU FAIL_FLAG + 1
FAIL_GOT	EQU FAIL_EXPECT + 1
NODATA_FLAG	EQU FAIL_GOT + 1
DEC_BUF		EQU NODATA_FLAG + 1
INFO_BUF	EQU DEC_BUF + 8
DLL_NAME	EQU INFO_BUF + 32
DLL_PATH	EQU DLL_NAME + DLL_NAME_SIZE
HOST_BUFF	EQU DLL_PATH + DLL_PATH_SIZE
PORT_BUFF	EQU HOST_BUFF + HOST_BUFF_SIZE
TOKEN_BUF	EQU PORT_BUFF + PORT_BUFF_SIZE
RECV_BUF	EQU TOKEN_BUF + TOKEN_BUF_SIZE
DLL_BASE_H	EQU RECV_BUF + RECV_BUF_SIZE
SNAPSHOT_OLD_WIN	EQU DLL_BASE_H + 1
SNAPSHOT_DSS_ERROR	EQU SNAPSHOT_OLD_WIN + 1
DLL_PROBE	EQU SNAPSHOT_DSS_ERROR + 1
DLL_PROBE_SIZE	EQU 256
BSS_END		EQU DLL_PROBE + DLL_PROBE_SIZE

STACK_BOTTOM	EQU BSS_END
STACK_TOP	EQU STACK_BOTTOM + 0x600

	ASSERT STACK_TOP <= 0xC000

	ENDMODULE

	END MAIN.START
