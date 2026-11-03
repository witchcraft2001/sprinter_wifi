; ======================================================
; AT+CWLAP response parser for NETCFG Wi-Fi scan.
;
; Included inside MODULE MAIN by src/apps/netcfg.asm and by
; tools/netcfg_scan_vectors.asm, so the host-side harness runs the exact
; same Z80 parsing code as the application.
;
; Tolerates both the real ESP-AT AT+CWLAPOPT=1,23 short form
;   +CWLAP:(<ecn>,"<ssid>",<rssi>,<ch>)
; and the full/default field form used by jesperl and unfiltered scans
;   +CWLAP: (<ecn>,"<ssid>",<rssi>,"<mac>",<ch>,...)
; Hidden APs (empty "" SSID) and any other line are treated as invisible /
; not a record and are skipped; this parser never signals a hard error to
; its caller, only "this line is not a usable record".
;
; Required definitions:
;   WIFI.RS_BUFF, RS_BUFF_SIZE
;   NETCFG.CFG_SSID, NETCFG.CFG_PASS, NETCFG.CFG_SSID_SIZE
;   UTIL.STARTSWITH
; ======================================================

	IFNDEF	_NETCFG_SCAN
	DEFINE	_NETCFG_SCAN

CWLAP_MAX_LIST	EQU 20
CWLAP_SSID_MAX	EQU NETCFG.CFG_SSID_SIZE-1

; ------------------------------------------------------
; Parse one AT+CWLAP record line.
; In:  HL - start of a line inside RS_BUFF (LF- or NUL-terminated, no
;           leading LF).
; Out: CF=0 and AP_* filled - visible record recognized.
;      CF=1 - not a CWLAP line, hidden SSID, or malformed record.
;      HL is not meaningful to the caller on return; re-derive the line
;      start via CWLAP_NEXT_LINE instead.
; ------------------------------------------------------
CWLAP_PARSE_LINE
	PUSH	DE
	LD	DE,MSG_CWLAP_PREFIX
	CALL	UTIL.STARTSWITH
	JP	NZ,.FAIL
	LD	DE,7					; strlen("+CWLAP:")
	ADD	HL,DE
.SKIP_SP
	LD	A,(HL)
	CP	' '
	JR	NZ,.SKIP_SP_DONE
	INC	HL
	JR	.SKIP_SP
.SKIP_SP_DONE
	LD	A,(HL)
	CP	'('
	JP	NZ,.FAIL
	INC	HL
	CALL	PARSE_DEC8
	JP	C,.FAIL
	LD	(AP_ECN),A
	LD	A,(HL)
	CP	','
	JP	NZ,.FAIL
	INC	HL
	LD	A,(HL)
	CP	'"'
	JP	NZ,.FAIL
	INC	HL
	LD	(AP_SSID),HL
	LD	B,0
.SSID_LOOP
	LD	A,(HL)
	CP	'"'
	JR	Z,.SSID_DONE
	AND	A
	JP	Z,.FAIL
	CP	10
	JP	Z,.FAIL
	INC	HL
	INC	B
	JR	.SSID_LOOP
.SSID_DONE
	LD	A,B
	AND	A
	JP	Z,.FAIL				; hidden AP ("" SSID) - not selectable
	LD	(AP_SSID_LEN),A
	INC	HL					; skip closing quote
	LD	A,(HL)
	CP	','
	JP	NZ,.FAIL
	INC	HL
	XOR	A
	LD	(AP_RSSI_NEG),A
	LD	A,(HL)
	CP	'-'
	JR	NZ,.RSSI_DIGITS
	INC	HL
	LD	A,1
	LD	(AP_RSSI_NEG),A
.RSSI_DIGITS
	CALL	PARSE_DEC8
	JP	C,.FAIL
	LD	(AP_RSSI),A
	LD	A,(HL)
	CP	','
	JP	NZ,.FAIL
	INC	HL
	LD	A,(HL)
	CP	'"'
	JR	NZ,.CHAN_DIRECT
	; Full/default field form: <rssi>,"<mac>",<ch>,...  Skip the quoted MAC.
	INC	HL
.MAC_LOOP
	LD	A,(HL)
	AND	A
	JP	Z,.FAIL
	CP	10
	JP	Z,.FAIL
	INC	HL
	CP	'"'
	JR	NZ,.MAC_LOOP
	LD	A,(HL)
	CP	','
	JP	NZ,.FAIL
	INC	HL
.CHAN_DIRECT
	CALL	PARSE_DEC8
	JP	C,.FAIL
	LD	(AP_CHAN),A
	POP	DE
	OR	A						; CF=0
	RET
.FAIL
	POP	DE
	SCF
	RET

; ------------------------------------------------------
; Move HL to the start of the next line, or leave it at a NUL terminator.
; ------------------------------------------------------
CWLAP_NEXT_LINE
	LD	A,(HL)
	AND	A
	RET	Z
	INC	HL
	CP	10
	RET	Z
	JR	CWLAP_NEXT_LINE

; ------------------------------------------------------
; Find the A-th (1-based) visible record in RS_BUFF. Indices beyond
; CWLAP_MAX_LIST always miss, matching CWLAP_COUNT's cap: SELECT_AP only ever
; offers 1..count, but an oversized scan response could otherwise still hold
; more than CWLAP_MAX_LIST visible records.
; In:  A - 1-based record index.
; Out: CF=0, AP_* filled, HL - pointer to that record's line start.
;      CF=1 - index not found (ran off the end of RS_BUFF, or index > CWLAP_MAX_LIST).
; ------------------------------------------------------
CWLAP_FIND
	CP	CWLAP_MAX_LIST+1
	JR	NC,.OUT_OF_RANGE
	; The outer counter is kept in C, not B: CWLAP_PARSE_LINE's own SSID-length
	; scratch counter uses B directly (PARSE_DEC8 is the only part of the line
	; parser that preserves BC across the call), so B cannot survive here.
	PUSH	BC
	LD	C,A
	LD	HL,WIFI.RS_BUFF
.SCAN
	LD	A,(HL)
	AND	A
	JR	Z,.NOTFOUND
	PUSH	HL
	CALL	CWLAP_PARSE_LINE
	POP	DE					; DE = this line's start; flags survive POP
	JR	C,.ADVANCE
	DEC	C
	JR	Z,.FOUND
.ADVANCE
	PUSH	DE
	POP	HL
	CALL	CWLAP_NEXT_LINE
	JR	.SCAN
.FOUND
	PUSH	DE
	POP	HL
	POP	BC
	OR	A						; CF=0
	RET
.NOTFOUND
	POP	BC
	SCF
	RET
.OUT_OF_RANGE
	SCF
	RET

; ------------------------------------------------------
; Count visible records in RS_BUFF, capped at CWLAP_MAX_LIST.
; Out: A - number of visible records (at most CWLAP_MAX_LIST).
;      CF=1 - more than CWLAP_MAX_LIST visible records were present: the
;      count was capped and the caller should say the list is incomplete.
; ------------------------------------------------------
CWLAP_COUNT
	; See CWLAP_FIND: the running count is kept in C, since CWLAP_PARSE_LINE
	; clobbers B as its own SSID-length scratch counter.
	PUSH	BC,HL
	LD	C,0
	LD	HL,WIFI.RS_BUFF
.SCAN
	LD	A,(HL)
	AND	A
	JR	Z,.DONE
	PUSH	HL
	CALL	CWLAP_PARSE_LINE
	POP	DE
	JR	C,.ADVANCE
	INC	C
	LD	A,C
	CP	CWLAP_MAX_LIST+1
	JR	NC,.CAPPED
.ADVANCE
	PUSH	DE
	POP	HL
	CALL	CWLAP_NEXT_LINE
	JR	.SCAN
.CAPPED
	LD	A,CWLAP_MAX_LIST
	POP	HL,BC
	SCF
	RET
.DONE
	LD	A,C
	POP	HL,BC
	OR	A						; CF=0
	RET

; ------------------------------------------------------
; Apply the A-th (1-based) record as the new SSID/PASS choice.
; In:  A - 1-based record index.
; Out: CF=0, A - ecn of the applied record; CFG_SSID updated with the raw
;      SSID bytes (truncated to CWLAP_SSID_MAX) and NUL-terminated; CFG_PASS
;      cleared when the network is open (ecn=0).
;      CF=1 - index not found; CFG_SSID/CFG_PASS untouched.
; ------------------------------------------------------
CWLAP_APPLY_CHOICE
	CALL	CWLAP_FIND
	RET	C
	PUSH	HL
	LD	HL,(AP_SSID)
	LD	DE,NETCFG.CFG_SSID
	LD	A,(AP_SSID_LEN)
	CP	CWLAP_SSID_MAX+1
	JR	C,.LEN_OK
	LD	A,CWLAP_SSID_MAX
.LEN_OK
	LD	B,A
	LD	A,B
	AND	A
	JR	Z,.COPIED
.COPY_LOOP
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	DJNZ	.COPY_LOOP
.COPIED
	XOR	A
	LD	(DE),A
	POP	HL
	LD	A,(AP_ECN)
	AND	A
	JR	NZ,.NOT_OPEN
	XOR	A
	LD	(NETCFG.CFG_PASS),A
.NOT_OPEN
	LD	A,(AP_ECN)
	OR	A						; CF=0
	RET

; ------------------------------------------------------
; In:  A - ecn value.
; Out: HL - pointer to an ASCIIZ security type name.
; ------------------------------------------------------
CWLAP_SECURITY_NAME
	CP	8
	JR	NC,.UNKNOWN
	PUSH	DE
	LD	E,A
	LD	D,0
	LD	HL,SEC_NAME_PTRS
	ADD	HL,DE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL
	POP	DE
	RET
.UNKNOWN
	LD	HL,SEC_NAME_UNKNOWN
	RET

; ------------------------------------------------------
; Parse an unsigned decimal number, saturating at 255.
; In:  HL - text pointer.
; Out: A - value 0..255 (saturated at 3 digits); HL advanced past every
;      consumed digit character; CF=1 - no digit found, HL unchanged.
; ------------------------------------------------------
PARSE_DEC8
	PUSH	BC,DE
	XOR	A
	LD	E,A					; E = 1 once a digit has been seen
	LD	D,A					; D = digits accumulated so far (capped at 3)
	LD	BC,0					; BC = accumulator
.LOOP
	LD	A,(HL)
	CP	'0'
	JR	C,.DONE
	CP	'9'+1
	JR	NC,.DONE
	SUB	'0'
	INC	HL
	LD	E,1
	PUSH	AF
	LD	A,D
	CP	3
	JR	NC,.SKIP_ACC
	INC	D
	POP	AF
	PUSH	HL
	LD	H,B
	LD	L,C
	ADD	HL,HL				; *2
	LD	B,H
	LD	C,L
	ADD	HL,HL				; *4
	ADD	HL,HL				; *8
	ADD	HL,BC				; *8 + *2 = *10
	ADD	A,L
	LD	L,A
	JR	NC,.NOCY
	INC	H
.NOCY
	LD	B,H
	LD	C,L
	POP	HL
	JR	.LOOP
.SKIP_ACC
	POP	AF
	JR	.LOOP
.DONE
	LD	A,E
	AND	A
	JR	Z,.NODIGIT
	LD	A,B
	AND	A
	JR	Z,.LOW
	LD	A,255
	JR	.RESTORE
.LOW
	LD	A,C
.RESTORE
	POP	DE,BC
	OR	A						; CF=0
	RET
.NODIGIT
	POP	DE,BC
	SCF
	RET

MSG_CWLAP_PREFIX	DB "+CWLAP:",0

SEC_NAME_PTRS
	DW	SEC_NAME_OPEN, SEC_NAME_WEP, SEC_NAME_WPA, SEC_NAME_WPA2
	DW	SEC_NAME_WPA_WPA2, SEC_NAME_WPA2_ENT, SEC_NAME_WPA3, SEC_NAME_WPA2_WPA3
SEC_NAME_OPEN		DB "Open",0
SEC_NAME_WEP		DB "WEP",0
SEC_NAME_WPA		DB "WPA",0
SEC_NAME_WPA2		DB "WPA2",0
SEC_NAME_WPA_WPA2	DB "WPA/WPA2",0
SEC_NAME_WPA2_ENT	DB "WPA2-Ent",0
SEC_NAME_WPA3		DB "WPA3",0
SEC_NAME_WPA2_WPA3	DB "WPA2/WPA3",0
SEC_NAME_UNKNOWN	DB "?",0

AP_ECN		DB 0
AP_RSSI		DB 0
AP_RSSI_NEG	DB 0
AP_CHAN		DB 0
AP_SSID		DW 0
AP_SSID_LEN	DB 0

	ENDIF
