; Execute the production idle path: real delay, ISA open/close and RTS code.
; Only the UART registers (ordinary emulator RAM) and DSS SCANKEY are mocked.
; No ESP_TCP_TEST_DELAY_TICK: a mocked delay cannot catch timeout inflation.

	DEVICE NOSLOT64K
	INCLUDE "unetesp.asm"

TEST_RESULT EQU 0xBFE0
TEST_MARKER EQU 0xBFE1
	ASSERT $ <= 0x4000
	DS 0x4000-$,0
	ORG 0x4000

; Each entry runs separately, including with interrupts disabled throughout.
BENCH_DISABLED
	XOR A
	JR RUN
BENCH_ENABLED
	LD A,1
	JR RUN
TEST_CANCEL
	LD A,2
	JR RUN
TEST_ARRIVAL
	LD A,3
RUN
	DI
	LD SP,0x7FF0
	LD (SCENARIO),A
	LD (UNET.CANCEL_MODE),A
	XOR A
	LD (TEST_RESULT),A
	LD (TEST_MARKER),A
	LD (SCANS),A
	LD (REG_LSR),A
	LD (WCOMMON.CANCELLED),A
	LD A,1
	LD (WIFI.UART_FLOW_MODE),A
	LD A,MCR_AFE | MCR_RTS
	LD (REG_MCR),A
	; This harness calls routines directly, not through the DLL jump table.
	; Replace the unused table bytes at RST #10 with our DSS SCANKEY handler.
	LD A,0xC3
	LD (0x10),A
	LD HL,SCANKEY
	LD (0x11),HL
	CALL ISA.ISA_OPEN
	LD BC,1000
	CALL TCP.READ_BYTE_TIMEOUT_OPEN
	LD (BYTE_RESULT),A
	LD (BC_RESULT),BC
	LD A,0
	ADC A,0
	LD (CARRY_RESULT),A
	; No timer may enable interrupts, or require an interrupt to finish.
	LD A,I
	JP PE,FAILED
	LD A,(REG_MCR)
	CP MCR_AFE | MCR_RTS
	JR NZ,FAILED
	CALL ISA.ISA_CLOSE
	LD A,(SCENARIO)
	CP 3
	JR Z,.arrival
	LD A,(CARRY_RESULT)
	CP 1
	JR NZ,FAILED
	LD HL,(BC_RESULT)
	LD DE,1000
	AND A
	SBC HL,DE
	JR NZ,FAILED
	LD A,(SCENARIO)
	CP 2
	JR Z,.cancel
	; Empty timeout must scan 0 / 5 times, not once for every delay tick.
	LD B,0
	OR A
	JR Z,.scans
	LD B,5
.scans
	LD A,(SCANS)
	CP B
	JR NZ,FAILED
	LD A,(WCOMMON.CANCELLED)
	OR A
	JR NZ,FAILED
	JR PASSED
.cancel
	LD A,(WCOMMON.CANCELLED)
	CP 1
	JR NZ,FAILED
	LD A,(SCANS)
	CP 1
	JR NZ,FAILED
	JR PASSED
.arrival
	LD A,(CARRY_RESULT)
	OR A
	JR NZ,FAILED
	LD A,(BYTE_RESULT)
	CP 0x5A
	JR NZ,FAILED
	LD A,(BC_RESULT)
	CP 0x5A
	JR NZ,FAILED
	LD A,(WCOMMON.CANCELLED)
	OR A
	JR NZ,FAILED
	JR PASSED
FAILED
	LD A,1
	LD (TEST_RESULT),A
PASSED
	LD A,0xA5
	LD (TEST_MARKER),A
TEST_DONE
	JP TEST_DONE

; Non-blocking fake DSS service. Can inject an Esc or a byte arriving while
; the reader has temporarily released the ISA window during idle waiting.
SCANKEY
	LD A,C
	CP DSS_SCANKEY
	JR NZ,FAILED
	LD HL,SCANS
	INC (HL)
	LD A,(SCENARIO)
	CP 2
	JR Z,.esc
	CP 3
	JR NZ,.empty
	LD A,LSR_DR
	LD (REG_LSR),A
	LD A,0x5A
	LD (REG_RBR),A
.empty
	XOR A
	RET
.esc
	LD E,0x1B
	LD A,1
	OR A
	RET

SCENARIO DB 0
SCANS DB 0
BYTE_RESULT DB 0
CARRY_RESULT DB 0
BC_RESULT DW 0
