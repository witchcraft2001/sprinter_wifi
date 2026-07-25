; ======================================================
; ESP-AT UDP helper routines for Sprinter ESP Network Kit
; Single-connection UDP client over Sprinter-WiFi UART.
; ======================================================

	IFNDEF	_ESP_UDP
	DEFINE	_ESP_UDP

UDP_DEFAULT_TIMEOUT	EQU 5000
UDP_CMD_SIZE		EQU 192

	MODULE UDP

; ------------------------------------------------------
; Open a single UDP endpoint.
; In: HL - host ASCIIZ, DE - remote port ASCIIZ.
; Uses a fixed local port and UDP mode 2 so the remote peer can change.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
OPEN
	PUSH	IX
	LD	IX,DEFAULT_LOCAL_PORT
	CALL	OPEN_LOCAL
	POP	IX
	RET

; ------------------------------------------------------
; Open a fixed-remote UDP endpoint using the minimal syntax shared by old
; NONOS-AT and ESP-AT. This is the correct mode for request/reply protocols
; such as NTP: replies must come from the configured peer, and no explicit
; local port or mutable-remote mode is required.
; In: HL - host ASCIIZ, DE - remote port ASCIIZ.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
OPEN_FIXED
	PUSH	IX
	LD	(PTR_HOST),HL
	LD	(PTR_REMOTE_PORT),DE
	CALL	BUILD_OPEN_PREFIX
	LD	DE,CMD_CRLF
	CALL	APPEND_STR
	CALL	SEND_OPEN
	POP	IX
	RET

; ------------------------------------------------------
; Open a single UDP endpoint with explicit local port.
; In: HL - host ASCIIZ, DE - remote port ASCIIZ, IX - local port ASCIIZ.
; Out: CF=0/A=0 on success, CF=1/A=ESP result code on failure.
; ------------------------------------------------------
OPEN_LOCAL
	LD	(PTR_HOST),HL
	LD	(PTR_REMOTE_PORT),DE
	LD	(PTR_LOCAL_PORT),IX

	CALL	BUILD_OPEN_PREFIX
	LD	DE,CMD_COMMA
	CALL	APPEND_STR
	LD	IX,(PTR_LOCAL_PORT)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CIPSTART_SUFFIX
	CALL	APPEND_STR
	JR	SEND_OPEN

; Build AT+CIPSTART="UDP","<host>",<remote-port> in CMD_BUFFER.
; Out: HL points at the terminating zero, ready for optional arguments/CRLF.
BUILD_OPEN_PREFIX
	LD	HL,CMD_BUFFER
	LD	DE,CMD_CIPSTART_PREFIX
	CALL	APPEND_STR
	LD	IX,(PTR_HOST)
	CALL	APPEND_IX_STR
	LD	DE,CMD_CIPSTART_REMOTE
	CALL	APPEND_STR
	LD	IX,(PTR_REMOTE_PORT)
	CALL	APPEND_IX_STR
	RET

SEND_OPEN
	; Retry while the ESP still answers "busy p..." right after NETUP's join;
	; see TCP.TX_CMD_BUSY_RETRY in esp_tcp.asm.
	LD	HL,CMD_BUFFER
	LD	BC,UDP_DEFAULT_TIMEOUT
	JP	TCP.TX_CMD_BUSY_RETRY

; ------------------------------------------------------
; Send one UDP payload through the currently opened endpoint.
; In: HL - payload, BC - payload length.
; ------------------------------------------------------
SEND_BUFFER
	JP	TCP.SEND_BUFFER

; Send a datagram payload and immediately hand UART parsing to RECEIVE.
; Required for fast request/reply protocols: a peer response may arrive before
; ESP prints SEND OK, and WAIT_SEND_OK cannot retain an unsolicited +IPD frame.
SEND_BUFFER_NO_WAIT
	JP	TCP.SEND_BUFFER_NO_WAIT

; ------------------------------------------------------
; Receive one UDP datagram/payload chunk.
; In: HL - destination buffer, BC - max bytes, DE - timeout ms.
; Out: CF=0/A=0/BC=stored bytes on success.
; ------------------------------------------------------
RECEIVE
	JP	TCP.RECEIVE

; ------------------------------------------------------
; Close the current UDP endpoint.
; ------------------------------------------------------
CLOSE
	JP	TCP.CLOSE

; ------------------------------------------------------
; Append ASCIIZ from DE to destination at HL.
; Out: HL points to destination end.
; ------------------------------------------------------
APPEND_STR
	LD	A,(DE)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	DE
	JR	APPEND_STR

APPEND_IX_STR
	LD	A,(IX+0)
	LD	(HL),A
	AND	A
	RET	Z
	INC	HL
	INC	IX
	JR	APPEND_IX_STR

CMD_CIPSTART_PREFIX
	DB	"AT+CIPSTART=",34,"UDP",34,",",34,0
CMD_CIPSTART_REMOTE
	DB	34,",",0
CMD_COMMA
	DB	",",0
CMD_CIPSTART_SUFFIX
	DB	",2",13,10,0
CMD_CRLF
	DB	13,10,0

DEFAULT_LOCAL_PORT
	DB	"1069",0

PTR_HOST		DW 0
PTR_REMOTE_PORT	DW 0
PTR_LOCAL_PORT	DW 0

	IFNDEF	ESP_UDP_BSS_BASE_OVERRIDE
ESP_UDP_BSS_BASE	EQU TCP.TCP_BSS_END
	ENDIF

UDP_BSS_BASE	EQU ESP_UDP_BSS_BASE
CMD_BUFFER	EQU UDP_BSS_BASE
UDP_BSS_END	EQU CMD_BUFFER + UDP_CMD_SIZE

	ENDMODULE

	ENDIF
