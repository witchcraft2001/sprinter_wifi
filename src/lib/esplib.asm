; ======================================================
; Library for Sprinter-WiFi ESP ISA Card
; By Roman Boykov. Copyright (c) 2024
; https://github.com/romychs
; License: BSD 3-Clause
; ======================================================

	IFNDEF	_ESP_LIB
	DEFINE	_ESP_LIB


	INCLUDE	"isa.asm"
	INCLUDE "util.asm"

;ISA_BASE_A		EQU 0xC000        						; Базовый адрес портов ISA в памяти
PORT_UART		EQU 0x03E8        						; Базовый номер порта COM3
PORT_UART_A		EQU ISA_BASE_A + PORT_UART    			; Порты чипа UART в памяти 

; UART TC16C550 Registers in memory
REG_RBR 		EQU PORT_UART_A
REG_THR 		EQU PORT_UART_A
REG_IER 		EQU PORT_UART_A + 1
REG_IIR 		EQU PORT_UART_A + 2
REG_FCR			EQU PORT_UART_A + 2
REG_LCR			EQU PORT_UART_A + 3
REG_MCR 		EQU PORT_UART_A + 4
REG_LSR 		EQU PORT_UART_A + 5
REG_MSR 		EQU PORT_UART_A + 6
REG_SCR 		EQU PORT_UART_A + 7
REG_DLL 		EQU PORT_UART_A
REG_DLM 		EQU PORT_UART_A + 1
REG_AFR 		EQU PORT_UART_A + 2



; UART TC16C550 Register bits 
MCR_DTR         EQU	0x01
MCR_RTS         EQU	0x02
MCR_RST         EQU	0x04
MCR_PGM         EQU	0x08
MCR_LOOP        EQU	0x10
MCR_AFE         EQU	0x20
LCR_WL8         EQU	0x03								; 8 bits word len
LCR_SB2         EQU	0x04								; 1.5 or 2 stp bits
LCR_DLAB        EQU	0x80								; Enable Divisor latch
FCR_FIFO        EQU	0x01								; Enable FIFO for rx and tx
FCR_RESET_RX    EQU	0x02								; Reset Rx FIFO
FCR_RESET_TX    EQU	0x04								; Reset Tx FIFO
FCR_DMA         EQU	0x08								; Set -RXRDY, -TXRDY to "1"
FCR_TR1         EQU	0x00								; Trigger on 1 byte in fifo
FCR_TR4         EQU	0x40								; Trigger on 4 bytes in fifo
FCR_TR8         EQU	0x80								; Trigger on 8 bytes in fifo
FCR_TR14        EQU	0xC0								; Trigger on 14 bytes in fifo
; Trigger 4 leaves 12 FIFO byte-times for CTS reaction. The receive/RTS
; algorithm itself remains profile-specific below.
UART_RX_PROFILE_221	EQU	1
UART_RX_PROFILE_222	EQU	2
FCR_RX_TRIGGER	EQU	FCR_TR4
LSR_DR          EQU	0x01								; Data Ready
LSR_OE          EQU	0x02								; Overrun Error
LSR_PE          EQU	0x04								; Parity Error
LSR_FE          EQU	0x08								; Framing Error
LSR_BI			EQU	0x10								; Break Interrupt
LSR_THRE        EQU	0x20								; Transmitter Holding Register Empty
LSR_TEMT        EQU	0x40								; Transmitter empty
LSR_RCVE        EQU	0x80								; Error in receiver FIFO

; Speed divider for UART
BAUD_RATE 		EQU 115200                    			; Default ESP8266 UART speed
XIN_FREQ 		EQU 14745600                  			; TL16C550 oscillator frequency
DEFAULT_DIVISOR	EQU XIN_FREQ / (BAUD_RATE * 16)  		; 8 for 115200

RS_BUFF_SIZE 	EQU	192								; AT-command response buffer (bulk +IPD data uses the separate WIN2 RECV_BUFFER). Anchors the BSS chain; sized to keep wget/ftp BSS well below the 0x8000 stack so the transfer call chain (nested receive + DSS_WRITE) keeps >=~500 B headroom after the shared REQUIRE_NET_UP code/buffer. AT responses are far smaller than 384.
MAX_BUFF_SIZE 	EQU	16384

LSTR_SIZE 		EQU	20									; Size of buffer for last response line
LF 				EQU 0x0A
CR 				EQU	0x0D

; -- 
RES_OK			EQU 0
RES_ERROR		EQU 1
RES_FAIL		EQU 2
RES_TX_TIMEOUT 	EQU 3
RES_RS_TIMEOUT	EQU 4
RES_CONNECTED	EQU 5
RES_NOT_CONN	EQU 6
RES_ENABLED		EQU 7
RES_DISABLED 	EQU	8
RES_BUSY		EQU 9

;ENABLE_RTS_CTR  EQU 0

	MODULE WIFI

; -- UART Registers offset

_RBR 			EQU	0
_THR 			EQU	0
_IER 			EQU	1
_IIR 			EQU	2
_FCR			EQU	2
_LCR			EQU	3
_MCR 			EQU	4
_LSR 			EQU	5
_MSR 			EQU	6
_SCR 			EQU	7
_DLL 			EQU	0
_DLM 			EQU	1
_AFR 			EQU	2


; ------------------------------------------------------
; Find TL550C in ISA slot
; Out: CF=1 - Not found, CF=0 - ISA.ISA_SLOT found in slot
; ------------------------------------------------------
	;IFUSED UART_FIND
UART_FIND
	PUSH	HL
	XOR 	A
	CALL	UT_T_SLOT
	JR		Z, UF_T_FND
	LD		A,1
	CALL	UT_T_SLOT
	JR		Z, UF_T_FND
	SCF
UF_T_FND
	POP		HL
	RET
; Test slot, A - ISA Slot no. 0 or 1
UT_T_SLOT
	; check IER hi bits, will be 0
	LD		(ISA.ISA_SLOT), A
	LD		HL, REG_IER
	CALL	UART_READ
	AND		0xF0
	RET		NZ

	; check SCR register
	LD		DE,0x5555
	CALL	CHK_SCR
	RET		NZ
	LD		DE,0xAAAA
	JP		CHK_SCR
	;CALL	CHK_SCR
	;RET

CHK_SCR	
	LD		HL, REG_SCR
	CALL	UART_WRITE
	CALL	UART_READ
	CP		D
	RET
	;ENDIF

; ------------------------------------------------------
; Init UART device TL16C550
; ------------------------------------------------------
	;IFUSED	UART_INIT
UART_INIT
	PUSH	AF, IX

	CALL 	ISA.ISA_OPEN
	LD		IX, PORT_UART_A
	; Preserve the field-proven 2.2.1 trigger-8 path. 2.2.2 uses trigger 4 to
	; leave more CTS reaction margin, including command responses: CIPSTART may
	; be followed immediately by a server greeting in +IPD before the caller
	; can switch from command parsing to the streaming receive routine.
	IFDEF	WIFI_STABLE_ACTIVE_RX
	IFDEF	ESP_AT_FORCE_221
	LD		A,FCR_TR8 | FCR_FIFO
	ELSE
	; Universal FTP still selects the firmware profile from NET_ESP_FW. Keep
	; the exact 2.2.1 initialization untouched; its 2.2.2 compatibility path
	; uses the same proven trigger but starts from clean FIFOs.
	LD		A,(UART_RX_PROFILE)
	CP		UART_RX_PROFILE_221
	LD		A,FCR_TR8 | FCR_RESET_RX | FCR_RESET_TX | FCR_FIFO
	JR		NZ,.STABLE_FCR_READY
	LD		A,FCR_TR8 | FCR_FIFO
.STABLE_FCR_READY
	ENDIF
	ELSE
	IFDEF	ESP_AT_FORCE_221
	LD		A,FCR_TR8 | FCR_FIFO
	ELSE
	IFDEF	ESP_AT_FORCE_222
	LD		A,FCR_TR4 | FCR_RESET_RX | FCR_RESET_TX | FCR_FIFO
	ELSE
	LD		A,(UART_RX_PROFILE)
	CP		UART_RX_PROFILE_221
	LD		A,FCR_TR4 | FCR_RESET_RX | FCR_RESET_TX | FCR_FIFO
	JR		NZ,.FCR_READY
	LD		A,FCR_TR8 | FCR_FIFO
.FCR_READY
	ENDIF
	ENDIF
	ENDIF
	LD		(IX+_FCR),A
	XOR 	A
	LD 		(IX+_IER), A								; Disable interrupts

	; Set 8bit word and Divisor for speed
	LD 		(IX+_LCR), LCR_DLAB | LCR_WL8				; Enable Baud rate latch
	LD		A,(UART_DIVISOR)
	LD 		(IX+_DLL), A
	XOR 	A
	LD		(IX+_DLM), A
	LD 		(IX+_LCR), LCR_WL8							; 8bit word, disable latch
	; Apply the mode selected before initialization: NETUP starts manually,
	; while clients load the negotiated value from NET_ESP_FLOW.
	LD		A,(UART_FLOW_MODE)
	AND	A
	LD		A,MCR_RTS
	JR		Z,.MCR_READY
	LD		A,MCR_AFE | MCR_RTS
.MCR_READY
	LD		(IX+_MCR),A
	CALL 	ISA.ISA_CLOSE

	POP 	IX,AF
	RET
	;ENDIF

; ------------------------------------------------------
; Set UART baud divisor.
; Inp: A - low byte divisor for TL16C550.
; ------------------------------------------------------
UART_SET_DIVISOR
	LD		(UART_DIVISOR),A
	RET

UART_SET_DEFAULT_DIVISOR
	LD		A,DEFAULT_DIVISOR
	JR		UART_SET_DIVISOR

; ------------------------------------------------------
; Select the UART receive profile. In a normal build this is called once by
; WCOMMON.REQUIRE_NET_UP after it reads NET_ESP_FW. Forced builds compile the
; matching receive algorithm and do not depend on this runtime value.
; Inp: A = UART_RX_PROFILE_221 or UART_RX_PROFILE_222.
; ------------------------------------------------------
UART_SET_RX_PROFILE
	LD		(UART_RX_PROFILE),A
	RET

; ------------------------------------------------------
; Select host-side flow-control mode.
; The safe default is manual RTS.  AFE is enabled only after a caller has
; changed the ESP UART to flow=3 *and* proved that an AT round trip still
; works with CTS gating enabled.  Some ESP-AT builds accept flow=3 while the
; corresponding pins are not actually muxed, in which case AFE deadlocks TX.
; ------------------------------------------------------
UART_FLOW_OFF
	XOR	A
	JR		UART_SET_FLOW_MODE

UART_FLOW_ON
	LD		A,1

UART_SET_FLOW_MODE
	LD		(UART_FLOW_MODE),A
	PUSH	DE,HL
	AND		A
	LD		E,MCR_RTS
	JR		Z,.WRITE
	LD		E,MCR_AFE | MCR_RTS
.WRITE
	LD		HL,REG_MCR
	CALL	UART_WRITE
	POP		HL,DE
	RET

; ------------------------------------------------------
; RX flow-control helpers. ESP-AT 2.2.1 retains its established manual RTS
; operation. ESP-AT 2.2.2 initially used automatic trigger-4 RTS alone, but
; real `+IPD` FTP traffic still overflowed the FIFO. Therefore both profiles
; explicitly deassert RTS around slow consumer paths; their FIFO setup remains
; profile-specific in UART_INIT/UART_EMPTY_RS above.
; ------------------------------------------------------
UART_RX_PAUSE
	PUSH	DE,HL
	LD		A,(UART_FLOW_MODE)
	LD		E,0
	AND		A
	JR		Z,.WRITE
	LD		E,MCR_AFE
.WRITE
	LD		HL,REG_MCR
	CALL	UART_WRITE
	POP		HL,DE
	RET

; Same operation while the caller already holds ISA window 3 open. Command
; readers use this at the exact CONNECT boundary: nesting ISA_OPEN would
; overwrite ISA.SAVE_MMU3 and, more importantly, leave enough time for the
; following +IPD burst to overrun the FIFO before RTS drops.
UART_RX_PAUSE_OPEN
	LD		A,(UART_FLOW_MODE)
	AND		A
	LD		A,0
	JR		Z,.WRITE
	LD		A,MCR_AFE
.WRITE
	LD		(REG_MCR),A
	RET

UART_RX_RESUME
	PUSH	DE,HL
	CALL	UART_SET_DATA_RX_MODE
	LD		A,(UART_FLOW_MODE)
	LD		E,MCR_RTS
	AND		A
	JR		Z,.WRITE
	LD		E,MCR_AFE | MCR_RTS
.WRITE
	LD	HL,REG_MCR
	CALL	UART_WRITE
	POP	HL,DE
	RET

; Resume while ISA window 3 is already open. The caller selects the required
; non-flushing trigger first, then raises RTS here and immediately starts
; draining; there is no bank-switch gap in which an eager peer can fill FIFO.
UART_RX_RESUME_OPEN
	LD		A,(UART_FLOW_MODE)
	AND		A
	LD		A,MCR_RTS
	JR		Z,.WRITE
	LD		A,MCR_AFE | MCR_RTS
.WRITE
	LD		(REG_MCR),A
	RET

; Select the profile-specific FIFO trigger before streaming payload data,
; without clearing bytes that may already have arrived. The 2.2.1 path is
; intentionally left untouched. The 2.2.2 command path already uses trigger 4,
; so this is normally an idempotent write that also repairs inherited UART
; state without flushing queued bytes.
UART_SET_DATA_RX_MODE
	IFDEF	WIFI_STABLE_ACTIVE_RX
	RET
	ELSE
	IFDEF	ESP_AT_FORCE_221
	RET
	ELSE
	IFNDEF	ESP_AT_FORCE_222
	LD		A,(UART_RX_PROFILE)
	CP		UART_RX_PROFILE_222
	RET		NZ
	ENDIF
	LD		E,FCR_TR4 | FCR_FIFO
	LD		HL,REG_FCR
	JP		UART_WRITE
	ENDIF
	ENDIF

; Non-flushing streaming-trigger selection for a caller that already mapped
; the ISA window. Keep the established 2.2.1/stable-profile no-op unchanged.
UART_SET_DATA_RX_MODE_OPEN
	IFDEF	WIFI_STABLE_ACTIVE_RX
	RET
	ELSE
	IFDEF	ESP_AT_FORCE_221
	RET
	ELSE
	IFNDEF	ESP_AT_FORCE_222
	LD		A,(UART_RX_PROFILE)
	CP		UART_RX_PROFILE_222
	RET		NZ
	ENDIF
	LD		A,FCR_TR4 | FCR_FIFO
	LD		(REG_FCR),A
	RET
	ENDIF
	ENDIF

; ------------------------------------------------------
; Read TL16C550 register
;   Inp: HL - register
;   Out: A - value from register
; ------------------------------------------------------
	;IFUSED	UART_READ
UART_READ
	CALL 	ISA.ISA_OPEN
	LD 		A, (HL)
	JP		ISA.ISA_CLOSE
	;CALL 	ISA.ISA_CLOSE
	;RET
	;ENDIF
; ------------------------------------------------------
; Write TL16C550 register
;   Inp: HL - register, E - value
; ------------------------------------------------------
	;IFUSED	UART_WRITE
UART_WRITE            
	CALL	ISA.ISA_OPEN
	LD 		(HL), E
	JP		ISA.ISA_CLOSE
	;CALL 	ISA.ISA_CLOSE
	;RET
	;ENDIF
; ------------------------------------------------------
; Wait for transmitter ready
;   Out: CF=1 - tr not ready,  CF=0 ready
; ------------------------------------------------------
	;IFUSED	UART_WAIT_TR
UART_WAIT_TR
	CALL	ISA.ISA_OPEN
	CALL	UART_WAIT_TR_INT
	JP		ISA.ISA_CLOSE
	;CALL	ISA.ISA_CLOSE
	;RET
	;ENDIF
;
; Wait, without open/close ISA
;
	;IFUSED	UART_WAIT_TR_INT

UART_WAIT_TR_INT
	PUSH	BC, HL, DE
	LD		D,A
	LD 		BC,	10000								; 10000 * 100us = 1s; ESP backpressure can hold CTS for hundreds of ms
	LD 		HL,	REG_LSR
WAIT_TR_BZY
	LD 		A,(HL)
	AND 	A, LSR_THRE
	JR 		NZ,WAIT_TR_RDY
	CALL	@UTIL.DELAY_100uS							; ~11 bit tx delay
	DEC 	BC
	LD 		A, C
	OR		B
	JR 		NZ,WAIT_TR_BZY
	SCF
WAIT_TR_RDY
	LD		A,D
	POP 	DE, HL, BC
	RET
	;ENDIF

; ------------------------------------------------------
; Transmit byte 
; Inp: E - byte
; Out: CF=1 - Not ready
; ------------------------------------------------------
	;IFUSED	UART_TX_BYTE
UART_TX_BYTE
	PUSH	DE
	CALL 	UART_WAIT_TR
	JP		C, UTB_NOT_R
	LD		HL, REG_THR
	CALL 	UART_WRITE
	XOR		A
UTB_NOT_R
	POP		DE
	RET
	;ENDIF
; ------------------------------------------------------
;  Transmit buffer 
;	Inp: HL -> buffer, BC - size
;   Out: CF=0 - Ok, CF=1 - Timeout
; ------------------------------------------------------
	;IFUSED	UART_TX_BUFFER
UART_TX_BUFFER
	PUSH	BC,DE,HL
	LD		DE, REG_THR
	CALL	ISA.ISA_OPEN
UTX_NEXT
	; buff not empty?
	LD		A, B
	OR		C
	JR		Z,UTX_EMP
	; wait until FIFO drains so we can refill it
	CALL	UART_WAIT_TR_INT
	JR		C, UTX_TXNR
	; THRE=1 means TX FIFO is empty; refill up to 16 bytes (FIFO depth)
	; before polling THRE again. Cuts per-byte poll overhead by ~16x.
	LD		A, 16
UTX_BURST
	LD		(TX_BURST_LEFT), A
	LD		A, B
	OR		C
	JR		Z, UTX_EMP
	LD		A,(HL)
	LD		(DE),A
	INC		HL
	DEC		BC
	LD		A,(TX_BURST_LEFT)
	DEC		A
	JR		NZ, UTX_BURST
	JR		UTX_NEXT
	; CF=0
UTX_EMP
	AND		A
UTX_TXNR
	CALL	ISA.ISA_CLOSE
	POP		HL,DE,BC
	RET
	;ENDIF

; ------------------------------------------------------
;  Transmit zero ended string
;	Inp: HL -> buffer
;   Out: CF=0 - Ok, CF=1 - Timeout
; ------------------------------------------------------
	;IFUSED	UART_TX_STRING
UART_TX_STRING
	PUSH	DE,HL
	LD		DE, REG_THR
	CALL	ISA.ISA_OPEN
UTXS_NEXT
	LD 		A,(HL)
	AND		A
	JR		Z,UTXS_END
	; check transmitter ready
	CALL	UART_WAIT_TR_INT
	JR		C, UTXS_TXNR
	; transmitt byte
	LD		A,(HL)
	INC		HL
	LD		(DE),A
	JR		UTXS_NEXT
	; CF=0
UTXS_END
	AND		A
UTXS_TXNR
	CALL	ISA.ISA_CLOSE
	POP		HL,DE
	RET
	;ENDIF

; ------------------------------------------------------
; Empty receiver FIFO buffer
; ------------------------------------------------------
	;IFUSED	UART_EMPTY_RS
UART_EMPTY_RS
	PUSH 	DE, HL
	; Keep the complete field-proven 2.2.1 command path unchanged. For 2.2.2,
	; trigger 4 is required even while waiting for a command response: after a
	; successful CIPSTART the peer can send its greeting immediately, so the
	; final OK and the first +IPD bytes form one continuous UART burst. Trigger
	; 8 leaves too little CTS reaction margin and was observed as an overrun in
	; FTP before the greeting could be consumed.
	;
	; The earlier attribution of truncated PING replies to trigger 4 was wrong:
	; PING's dynamically built command lacked its NUL terminator and transmitted
	; dirty BSS after CR/LF. Keep trigger selection profile-specific here.
	IFDEF	WIFI_STABLE_ACTIVE_RX
	LD		E,FCR_TR8 | FCR_RESET_RX | FCR_FIFO
	ELSE
	IFDEF	ESP_AT_FORCE_221
	LD		E,FCR_TR8 | FCR_RESET_RX | FCR_FIFO
	ELSE
	IFDEF	ESP_AT_FORCE_222
	LD		E,FCR_TR4 | FCR_RESET_RX | FCR_FIFO
	ELSE
	LD		A,(UART_RX_PROFILE)
	CP		UART_RX_PROFILE_221
	LD		E,FCR_TR4 | FCR_RESET_RX | FCR_FIFO
	JR		NZ,.FCR_READY
	LD		E,FCR_TR8 | FCR_RESET_RX | FCR_FIFO
.FCR_READY
	ENDIF
	ENDIF
	ENDIF
	LD		HL, REG_FCR
	CALL	UART_WRITE
	POP 	HL, DE
	RET
	;ENDIF

; ------------------------------------------------------
; Wait byte in receiver fifo
; Inp: BC - Wait ms
; Out: CF=1 - Timeout, FIFO is EMPTY
; ------------------------------------------------------
UART_WAIT_RS1
	PUSH	BC,HL
WAIT_MS	EQU	$+1
	LD		BC,0x2000
	JR		UVR_NEXT
UART_WAIT_RS
	PUSH	BC,HL
UVR_NEXT
	LD		HL, REG_LSR
	CALL	UART_READ
	AND		LSR_DR
	JR		NZ,UVR_OK
	; BC=0 is a poll, not a 65536 ms timeout. Sample LSR once above so an
	; already pending byte still succeeds, then stop before DELAY/DEC can wrap.
	LD		A,B
	OR		C
	JR		Z,UVR_TO
	CALL	UTIL.DELAY_1MS
	DEC		BC
	LD		A,B
	OR		C
	JR		NZ,UVR_NEXT
UVR_TO
    IFDEF TRACE
	PUSH	AF,BC,DE,HL
	PRINTLN MSG_RCV_EMPTY
	POP		HL,DE,BC,AF
	ENDIF
	SCF
UVR_OK
	POP		HL,BC
	RET

UART_WAIT_RS1_INT
	PUSH	BC,HL
	LD		BC,(WAIT_MS)
	LD		HL,200
	LD		(CANCEL_TICK),HL
	JR		UVR_NEXT_INT
UART_WAIT_RS_INT
	PUSH	BC,HL
	LD		HL,200
	LD		(CANCEL_TICK),HL
UVR_NEXT_INT
	LD		HL, REG_LSR
	LD		A,(HL)
	; LSR errors are cleared by reading the register. Preserve them for
	; UART_TX_CMD so a truncated/corrupted line followed by a valid OK cannot
	; be mistaken for a successful command.
	PUSH	AF
	AND		LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	LD		HL,CMD_LSR_ACCUM
	OR		(HL)
	LD		(HL),A
	POP		AF
	AND		LSR_DR
	JR		NZ,UVR_OK_INT
	; Keep the interrupt/open-ISA reader's zero-budget semantics identical to
	; UART_WAIT_RS: one LSR sample, no delay, and no BC underflow.
	LD		A,B
	OR		C
	JR		Z,UVR_TO_INT
	CALL	UTIL.DELAY_1MS
	; Cancel poll every ~200ms (200 * ~0.5ms each = ~100ms wall, close enough).
	LD		HL,(CANCEL_TICK)
	DEC		HL
	LD		(CANCEL_TICK),HL
	LD		A,H
	OR		L
	JR		NZ,.NO_CANCEL_CHECK
	LD		HL,200
	LD		(CANCEL_TICK),HL
	CALL	@WCOMMON.CHECK_CANCEL_IN_ISA
	JR		C,UVR_CANCEL_INT
.NO_CANCEL_CHECK
	DEC		BC
	LD		A,B
	OR		C
	JR		NZ,UVR_NEXT_INT
UVR_TO_INT
	SCF
UVR_OK_INT
	POP		HL,BC
	RET
UVR_CANCEL_INT
	; Treat user cancel as a timeout for legacy callers; WCOMMON.CANCELLED flag
	; is set so top-level error handlers can redirect to CANCEL_EXIT.
	SCF
	POP		HL,BC
	RET

; ------------------------------------------------------
; Reset ESP module
; ------------------------------------------------------
	;IFUSED	ESP_RESET
ESP_RESET
	PUSH	AF,HL
	CALL	UART_FLOW_OFF

	CALL	ISA.ISA_OPEN

	LD		HL, REG_MCR
	LD		A, MCR_RST ;| MCR_RTS						; -OUT1=0 -> RESET ESP
	LD		(REG_MCR), A
	CALL	UTIL.DELAY_1MS
	LD		A, MCR_RTS							; release reset in manual RTS mode
	LD		(HL), A
	CALL	ISA.ISA_CLOSE
	
	; wait 2s for ESP firmware boot
	LD		HL,2000
	CALL	UTIL.DELAY

	POP		HL,AF
	RET
	;ENDIF

; ------------------------------------------------------
; UART TX Command
;	Inp: HL - ptr to command, 
;		 DE - ptr to receive buffer, 
;		 BC - wait ms
;	Out: A = RES_* result, CF=1 exactly when A is non-zero.
;	      Both forms are part of the contract: old callers commonly test A,
;	      while the SEND_CMD macro tests Carry through WCOMMON.CHECK_ERROR.
; ------------------------------------------------------
	;IFUSED	UART_TX_CMD
UART_TX_CMD
	PUSH	BC, DE, HL
	XOR		A
	LD		(CMD_LSR_ACCUM),A

	; Keep 4 tail bytes free: the counted stores may fill the area exactly,
	; and the terminator/LF that close each line are written without a BC
	; decrement of their own.
	LD		A, low (RS_BUFF_SIZE-4)
	LD		(BSIZE), A
	LD		A, high (RS_BUFF_SIZE-4)
	LD		(BSIZE+1), A

	LD		(RESBUF),DE
	XOR		A
	LD		(DE), A

	LD		(WAIT_MS), BC
	CALL	UART_EMPTY_RS

	; HL - Buffer, BC - Size
	;CALL	UTIL.STRLEN
	CALL	UART_TX_STRING
	JR		NC, UTC_STRT_RX
	; error, transmit timeout
	LD		A, RES_TX_TIMEOUT
	JP		UTC_RET_NO_CLOSE
UTC_STRT_RX		
	; no transmit timeout, receive response
	; IX - pointer to begin of current line
	LD		IXH, D
	LD		IXL, E
	LD		BC,(BSIZE)
	CALL	ISA.ISA_OPEN
UTC_RCV_NXT
	; wait receiver ready
	;LD		BC,(WAIT_MS)
	CALL	UART_WAIT_RS1_INT
	JR		NC, UTC_NO_RT
	; error, read timeout
	XOR		A
	LD		(DE),A								; preserve a safe ASCIIZ partial response
	LD		A, RES_RS_TIMEOUT
	JP		UTC_RET
	; no receive timeout
UTC_NO_RT
	; read symbol from tty
	LD		HL, REG_RBR
	LD		A,(HL)
	CP		CR
	JP		Z, UTC_RCV_NXT							; Skip CR 
	CP		LF
	JR		Z, UTC_END								; LF - last symbol in responce
	LD		(DE),A
	INC		DE
	DEC		BC
	LD		A, B
	OR		C
	JR		NZ, UTC_RCV_NXT
UTC_END
	XOR		A
	LD		(DE),A									; temporary mark end of string
	PUSH 	DE										; store DE
	POP		IY
	PUSH	IX
	POP		DE										; DE - ptr to begin pf current line

	; It is 'OK<LF>'?
	LD		HL, MSG_OK
	CALL	UTIL.STRCMP
	JR		NC, UTC_RET
	; It is 'ERROR<LF>'?
	LD		HL,MSG_ERROR
	CALL	UTIL.STRCMP
	JR		C, UTC_CP_FAIL
	LD		A, RES_ERROR
	; It is 'FAIL<LF>'?
	JR		UTC_RET
UTC_CP_FAIL
	LD		HL,MSG_FAIL
	CALL	@UTIL.STRCMP
	JR		C, UTC_CP_BUSY
	LD		A, RES_FAIL
	JR		UTC_RET
UTC_CP_BUSY
	; "busy p..."/"busy s..." is a terminal state line: the interpreter has
	; rejected this command and no OK/ERROR will follow it. Report RES_BUSY
	; right away so callers can retry instead of burning the whole timeout
	; (which used to surface as a misleading RES_RS_TIMEOUT / error #4).
	EX		DE,HL									; HL = current line start
	LD		DE,MSG_BUSY
	CALL	@UTIL.STARTSWITH
	EX		DE,HL									; DE = line start again
	JR		NZ, UTC_NOMSG
	LD		A, RES_BUSY
	JR		UTC_RET
UTC_NOMSG
	; no resp message, continue receive
	PUSH	IY
	POP		DE
	LD		A, LF
	LD		(DE),A									; change 0 - EOL to LF
	INC		DE
	; The LF slot is not covered by the counted stores. Charge it here and,
	; once the buffer is spent, restart at the base: a long multi-line
	; response (stale +IPD backlog, repeated status lines) used to walk DE
	; past the response buffer into the BSS chain. Only the newest tail is
	; kept, which is all the terminal-line scan above needs.
	LD		A,B
	OR		C
	JR		Z, UTC_BUF_RESET
	DEC		BC
	LD		A,B
	OR		C
	JR		NZ, UTC_SET_LINE
UTC_BUF_RESET
	LD		DE,(RESBUF)
	LD		BC,(BSIZE)
UTC_SET_LINE
	LD		IXH,D									; store new start line ptr
	LD		IXL,E
	JP		UTC_RCV_NXT
UTC_RET
	; A terminal OK is not trustworthy if the 16550 reported an overrun or
	; framing/parity error while collecting it. Surface this as a receive
	; timeout so command-specific retry logic can safely resend the command.
	PUSH	AF
	LD		HL,CMD_LSR_ACCUM
	LD		A,(HL)
	AND		LSR_OE | LSR_PE | LSR_FE | LSR_BI | LSR_RCVE
	JR		NZ,.CORRUPT
	POP		AF
	JR		.CLOSE_OK
.CORRUPT
	POP		AF
	LD		A,RES_RS_TIMEOUT
.CLOSE_OK
	CALL	ISA.ISA_CLOSE
UTC_RET_NO_CLOSE
	POP		HL, DE, BC
	OR		A							; CF=0 for RES_OK
	RET		Z
	SCF								; CF=1 for every RES_* error
	RET
	;ENDIF

	IFDEF TRACE
MSG_RCV_EMPTY
	DB "Receiver is empty!",0	
	ENDIF

; ------------------------------------------------------
; Data definition
; ------------------------------------------------------

; Receive block size
BSIZE		DW 0

; Response buffer base for the wrap-around restart in UART_TX_CMD
RESBUF		DW 0

; UART_TX_BUFFER FIFO refill counter
TX_BURST_LEFT	DB 0

; Periodic cancel-poll counter for UART wait loops
CANCEL_TICK	DW 0

; Sticky LSR errors for the current AT command response.
CMD_LSR_ACCUM	DB 0

UART_DIVISOR	DB DEFAULT_DIVISOR

; Default is the new 2.2.2-safe start-up path. Network applications replace
; it from NET_ESP_FW before their own UART_INIT; NETUP replaces it immediately
; after its one-time firmware probe.
UART_RX_PROFILE	DB UART_RX_PROFILE_222
; Safe default for NETUP/NETRESET. Network clients replace it from the
; NET_ESP_FLOW value published by NETUP before their own UART_INIT.
UART_FLOW_MODE	DB 0

; Received message for OK result
MSG_OK		DB "OK", 0

; Received message for Error
MSG_ERROR	DB "ERROR", 0

; Received message for Failure
MSG_FAIL	DB "FAIL", 0

; Prefix of the ESP "busy p..."/"busy s..." state line
MSG_BUSY	DB "busy", 0

; Buffer to receive response from ESP
RS_BUFF	
	;DS RS_BUFF_SIZE, 0

	ENDMODULE

	ENDIF
