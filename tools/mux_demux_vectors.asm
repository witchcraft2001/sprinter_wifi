; Host-side regression harness for the ESP_TCP_MUX two-channel receive
; demultiplexer (esp_tcp.asm). Runs the REAL RECEIVE_MUX / WAIT_IPD_HEADER_MUX /
; MUX_PARSE_IPD_HDR / stash routines against a scripted UART byte source, so it
; verifies link-aware "+IPD,<link>,<len>:" parsing, cross-channel stashing with
; early return, per-channel replay order, "<link>,CLOSED" demultiplexing and
; ordering against buffered data, per-channel overflow accounting, and the mux
; response dialect in the SEND window. Run through tools/test-mux-demux.sh.

	DEVICE NOSLOT64K

; Enable the feature and shrink the buffers so overflow is cheap to exercise.
	DEFINE	ESP_TCP_RX_DEFER
	DEFINE	ESP_TCP_MUX
	DEFINE	ESP_TCP_TEST_READER
	DEFINE	TCP_RX_DEFER_SIZE 32

; Constants normally supplied by esplib.asm.
RS_BUFF_SIZE	EQU 192
REG_RBR		EQU 0xC3E8
REG_LSR		EQU 0xC3ED
LSR_DR		EQU 0x01
LSR_OE		EQU 0x02
RES_ERROR	EQU 1
RES_FAIL	EQU 2
RES_TX_TIMEOUT	EQU 3
RES_RS_TIMEOUT	EQU 4
RES_NOT_CONN	EQU 6
RES_BUSY	EQU 9

TEST_RESULT	EQU 0xC000
TEST_MARKER	EQU 0xC001	; 0xA5 once the vector chain has actually run
RECV_DEST	EQU 0xC100

	MACRO ASSERT_W16 addr?, val?
	LD	HL,(addr?)
	LD	DE,val?
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JP	NZ,FAILED
	ENDM

	MACRO ASSERT_B addr?, val?
	LD	A,(addr?)
	CP	val?
	JP	NZ,FAILED
	ENDM

; Select a channel's defer context so the working cursors can be asserted.
	MACRO SELECT_CH ch?
	LD	A,ch?
	CALL	TCP.DEFER_SELECT
	ENDM

	ORG 0x4000

TEST_START
	XOR	A
	LD	(TEST_RESULT),A
	LD	(TEST_MARKER),A
	CALL	TCP.RX_DEFER_RESET_ALL

; ------------------------------------------------------------------
; Vector 1: a frame for the channel being read is delivered to the caller.
; ------------------------------------------------------------------
	LD	A,1
	LD	(STAGE),A
	LD	HL,IN_OWN
	LD	BC,IN_OWN_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 5
	LD	HL,RECV_DEST
	LD	DE,EXP_HELLO
	LD	B,5
	CALL	CMP_MEM
	ASSERT_W16 TCP.PAYLOAD_LEFT, 0

; ------------------------------------------------------------------
; Vector 2: a frame for the OTHER channel is stashed for it, and the read
; returns immediately with nothing so the caller can switch channels.
; ------------------------------------------------------------------
	LD	A,2
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_FOREIGN
	LD	BC,IN_FOREIGN_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED		; idle, not an error
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 0
	; channel 0 must still be empty, channel 1 must hold the frame
	SELECT_CH 0
	ASSERT_W16 TCP.DEFER_W, 0
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 5	; 2-byte header + "ABC"
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_ABC
	LD	B,5
	CALL	CMP_MEM
	; and reading channel 1 replays it
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 3
	LD	HL,RECV_DEST
	LD	DE,EXP_ABC
	LD	B,3
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 3: a +IPD racing the CIPSEND '>' prompt is captured into the
; window of the link it belongs to, not the one currently selected.
; ------------------------------------------------------------------
	LD	A,3
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	XOR	A
	LD	(ISA.OPEN_COUNT),A
	LD	(ISA.CLOSE_COUNT),A
	SELECT_CH 0			; reading/sending on channel 0
	LD	HL,IN_PROMPT
	LD	BC,IN_PROMPT_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_PROMPT
	JP	C,FAILED		; must have seen '>'
	ASSERT_B ISA.OPEN_COUNT, 1	; one fast, balanced capture window
	ASSERT_B ISA.CLOSE_COUNT, 1
	ASSERT_B TCP.DEFER_CUR_CH, 0	; selection restored after the capture
	SELECT_CH 0
	ASSERT_W16 TCP.DEFER_W, 0	; nothing for the sending channel
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 6	; header + "WXYZ"
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_WXYZ
	LD	B,6
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 4: the SEND window speaks the mux dialect: "<id>,CLOSED" only
; latches a peer close and keeps waiting, "<id>,SEND OK" terminates.
; ------------------------------------------------------------------
	LD	A,4
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_SENDOK
	LD	BC,IN_SENDOK_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED		; must have matched "0,SEND OK"
	ASSERT_B TCP.MUX_CLOSED_MASK, 2	; "1,CLOSED" latched for channel 1
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 4	; header + "QQ" captured on the way
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_QQ
	LD	B,4
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 5: a close for the other channel does not end our read; the scan
; continues to our own data, and the close stays latched for its owner.
; ------------------------------------------------------------------
	LD	A,5
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_XCLOSE
	LD	BC,IN_XCLOSE_LEN
	CALL	SET_INPUT
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 2
	LD	HL,RECV_DEST
	LD	DE,EXP_HI
	LD	B,2
	CALL	CMP_MEM
	ASSERT_B TCP.MUX_CLOSED_MASK, 1	; channel 0 closed
	; channel 0 now reports the close without touching the UART
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	NC,FAILED
	CP	RES_NOT_CONN
	JP	NZ,FAILED

; ------------------------------------------------------------------
; Vector 6: data buffered for a channel is delivered before its close is
; reported (matches the UNETRTL FIN contract).
; ------------------------------------------------------------------
	LD	A,6
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_DATA_THEN_CLOSE
	LD	BC,IN_DATA_THEN_CLOSE_LEN
	CALL	SET_INPUT
	; reading channel 0 stashes channel 1's frame, then sees "1,CLOSED"
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 0
	; first read of channel 1 must return the buffered data, not the close
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 4
	LD	HL,RECV_DEST
	LD	DE,EXP_TAIL
	LD	B,4
	CALL	CMP_MEM
	; only the next read reports the close
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	NC,FAILED
	CP	RES_NOT_CONN
	JP	NZ,FAILED

; ------------------------------------------------------------------
; Vector 7: overflow is accounted per channel. A frame too big for one
; channel's window is dropped and flags only that channel.
; ------------------------------------------------------------------
	LD	A,7
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_BIG_FOREIGN
	LD	BC,IN_BIG_FOREIGN_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 0	; 40+2 > 32: dropped
	ASSERT_B TCP.DEFER_LOST, 1
	SELECT_CH 0
	ASSERT_B TCP.DEFER_LOST, 0	; the other channel is unaffected

; ------------------------------------------------------------------
; Vector 8: opening a channel purges only that channel's window.
; ------------------------------------------------------------------
	LD	A,8
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_FOR_CH0
	LD	BC,IN_FOR_CH0_LEN
	CALL	SET_INPUT
	LD	A,1			; reading channel 1 stashes channel 0's frame
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	SELECT_CH 0
	ASSERT_W16 TCP.DEFER_W, 5	; header + "RST"
	; purging the other channel must leave this one alone
	LD	A,1
	CALL	TCP.RX_DEFER_RESET_CH
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 0
	SELECT_CH 0
	ASSERT_W16 TCP.DEFER_W, 5	; survives
	; purging this channel clears it
	LD	A,0
	CALL	TCP.RX_DEFER_RESET_CH
	SELECT_CH 0
	ASSERT_W16 TCP.DEFER_W, 0

; ------------------------------------------------------------------
; Vector 9: with room to spare the receive loop consumes back-to-back
; frames for this channel within one call (the bulk-transfer path).
; ------------------------------------------------------------------
	LD	A,9
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_BACK2BACK
	LD	BC,IN_BACK2BACK_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,2000				; >= TCP_ACTIVE_IPD_MAX: keep reading
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 6			; "ABC" + "DEF" in one call
	LD	HL,RECV_DEST
	LD	DE,EXP_ABCDEF
	LD	B,6
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 10: a foreign frame that follows our own one back-to-back is
; stashed for its channel; our bytes are still returned right away.
; ------------------------------------------------------------------
	LD	A,10
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_MIXED_BURST
	LD	BC,IN_MIXED_BURST_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,2000
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 3
	LD	HL,RECV_DEST
	LD	DE,EXP_ABC
	LD	B,3
	CALL	CMP_MEM
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 5		; header + "UVW"
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_UVW
	LD	B,5
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 11: async suspend in WAIT_PROMPT mid-"+IPD," prefix. The silence
; falls after "+IP"; the resume must finish matching the prefix and stash the
; foreign frame instead of misreading its tail as junk - the exact failure a
; restarting matcher would produce.
; ------------------------------------------------------------------
	LD	A,11
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.ASYNC_RESET
	LD	A,1
	LD	(TCP.ASYNC_MODE),A
	XOR	A
	LD	(TCP.LINK_ID),A
	LD	HL,IN_ASYNC1A
	LD	BC,IN_ASYNC1A_LEN
	CALL	SET_INPUT
	LD	HL,PAYLOAD_XYZ
	LD	BC,3
	CALL	TCP.SEND_BUFFER
	JP	NC,FAILED		; must suspend, not succeed
	CP	RES_AGAIN
	JP	NZ,FAILED
	ASSERT_B TCP.ASYNC_PEND, 1	; awaiting the prompt
	LD	HL,IN_ASYNC1B
	LD	BC,IN_ASYNC1B_LEN
	CALL	SET_INPUT
	CALL	TCP.SEND_BUFFER_RESUME
	JP	C,FAILED
	ASSERT_B TCP.ASYNC_PEND, 0	; transaction complete
	ASSERT_B TCP.SEND_PHASE, 1	; payload went out exactly once
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 5	; header + "ABC": the split frame survived
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_ABC
	LD	B,5
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 12: async suspend in WAIT_SEND_OK mid-line ("Recv 3 by|tes"), with a
; foreign frame arriving after the resume. The line must reassemble across the
; suspension and the frame must reach its channel's stash.
; ------------------------------------------------------------------
	LD	A,12
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.ASYNC_RESET
	LD	A,1
	LD	(TCP.ASYNC_MODE),A
	XOR	A
	LD	(TCP.LINK_ID),A
	LD	HL,IN_ASYNC2A
	LD	BC,IN_ASYNC2A_LEN
	CALL	SET_INPUT
	LD	HL,PAYLOAD_XYZ
	LD	BC,3
	CALL	TCP.SEND_BUFFER
	JP	NC,FAILED
	CP	RES_AGAIN
	JP	NZ,FAILED
	ASSERT_B TCP.ASYNC_PEND, 2	; payload sent, awaiting SEND OK
	ASSERT_B TCP.SEND_PHASE, 1
	LD	HL,IN_ASYNC2B
	LD	BC,IN_ASYNC2B_LEN
	CALL	SET_INPUT
	CALL	TCP.SEND_BUFFER_RESUME
	JP	C,FAILED
	ASSERT_B TCP.ASYNC_PEND, 0
	LD	A,(TCP.WSO_FLAGS)
	AND	1			; the real "SEND OK" line was matched
	JP	Z,FAILED
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 4	; header + "ZZ"
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_FRAME_ZZ
	LD	B,4
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 13: while a send is suspended, RECEIVE_MUX serves only buffered data
; and never touches the live stream (it would eat the pending '>' / SEND OK).
; ------------------------------------------------------------------
	LD	A,13
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.ASYNC_RESET
	; preload channel 1's stash, then mark a suspended transaction
	LD	HL,IN_FOREIGN
	LD	BC,IN_FOREIGN_LEN
	CALL	SET_INPUT
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX		; stashes "ABC" for channel 1
	JP	C,FAILED
	LD	A,2
	LD	(TCP.ASYNC_PEND),A
	LD	HL,IN_OWN		; live bytes that must NOT be consumed
	LD	BC,IN_OWN_LEN
	CALL	SET_INPUT
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 3		; the stash was replayed...
	ASSERT_W16 WIFI.INPUT_LEFT, IN_OWN_LEN	; ...and the wire untouched
	; drained + still suspended: idle immediately, wire still untouched
	LD	A,1
	LD	HL,RECV_DEST
	LD	BC,100
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 0
	ASSERT_W16 WIFI.INPUT_LEFT, IN_OWN_LEN
	CALL	TCP.ASYNC_RESET

; ------------------------------------------------------------------
; Vector 14: a live payload that goes silent while SEND tries to rescue it
; remains live. AT+CIPSEND is not transmitted, and a later capture continues
; at the exact byte count instead of losing framing.
; ------------------------------------------------------------------
	LD	A,14
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,5
	LD	(TCP.PAYLOAD_LEFT),HL
	LD	A,1
	LD	(TCP.MUX_PAYLOAD_LINK),A
	XOR	A
	LD	(TCP.LINK_ID),A
	LD	(WIFI.TX_STRING_COUNT),A
	LD	HL,IN_PART_A
	LD	BC,IN_PART_A_LEN
	CALL	SET_INPUT
	LD	HL,PAYLOAD_XYZ
	LD	BC,3
	CALL	TCP.SEND_BUFFER
	JP	NC,FAILED
	CP	RES_RS_TIMEOUT
	JP	NZ,FAILED
	ASSERT_B WIFI.TX_STRING_COUNT, 0
	ASSERT_W16 TCP.PAYLOAD_LEFT, 3
	ASSERT_B TCP.MUX_PAYLOAD_LINK, 1
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 4	; patched header + "AB"
	LD	HL,IN_PART_B
	LD	BC,IN_PART_B_LEN
	CALL	SET_INPUT
	CALL	TCP.MUX_CAPTURE_PENDING_PAYLOAD
	JP	C,FAILED
	ASSERT_W16 TCP.PAYLOAD_LEFT, 0
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 9	; {2,"AB"}, then {3,"CDE"}
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_SPLIT
	LD	B,9
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 15: the same invariant holds when the timeout happens in a complete
; +IPD header captured during the CIPSEND response window.
; ------------------------------------------------------------------
	LD	A,15
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	LD	HL,IN_SPLIT_FRAME_A	; prefix "+IPD," was consumed by the caller
	LD	BC,IN_SPLIT_FRAME_A_LEN
	CALL	SET_INPUT
	CALL	TCP.MUX_CAPTURE_IPD_FRAME
	JP	NC,FAILED
	CP	RES_RS_TIMEOUT
	JP	NZ,FAILED
	ASSERT_W16 TCP.PAYLOAD_LEFT, 3
	ASSERT_B TCP.MUX_PAYLOAD_LINK, 1
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 4
	LD	HL,IN_PART_B
	LD	BC,IN_PART_B_LEN
	CALL	SET_INPUT
	CALL	TCP.MUX_CAPTURE_PENDING_PAYLOAD
	JP	C,FAILED
	ASSERT_W16 TCP.PAYLOAD_LEFT, 0
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 9
	LD	HL,TCP.DEFER_BUF1
	LD	DE,EXP_SPLIT
	LD	B,9
	CALL	CMP_MEM

; ------------------------------------------------------------------
; Vector 16: CIPSTART may be followed by peer data before its final OK. In
; command-response mode the same parser must stash that +IPD, retain CONNECT,
; and terminate on the bare OK without treating payload bytes as response text.
; ------------------------------------------------------------------
	LD	A,16
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.SEND_STATE_RESET
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	HL,IN_CONNECT_IPD_OK
	LD	BC,IN_CONNECT_IPD_OK_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED
	LD	A,(TCP.WSO_FLAGS)
	AND	8			; CONNECT was observed before +IPD/OK
	JP	Z,FAILED
	SELECT_CH 0
	ASSERT_W16 TCP.DEFER_W, 7
	LD	HL,TCP.DEFER_BUF0
	LD	DE,EXP_FRAME_HELLO
	LD	B,7
	CALL	CMP_MEM
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A

; ------------------------------------------------------------------
; Vector 17: "busy p..." is terminal for an AT command. No OK follows it, so
; waiting for a timeout would misclassify a retryable refusal as ESP silence.
; ------------------------------------------------------------------
	LD	A,17
	LD	(STAGE),A
	CALL	TCP.SEND_STATE_RESET
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	HL,IN_BUSY
	LD	BC,IN_BUSY_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	NC,FAILED
	CP	RES_BUSY
	JP	NZ,FAILED
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A

; ------------------------------------------------------------------
; Vector 18: CIPSTART is proven by its own <id>,CONNECT. Do not wait for the
; final OK: an immediate streaming peer may keep +IPD queued ahead of it. The
; untouched stream tail belongs to the first RECV.
; ------------------------------------------------------------------
	LD	A,18
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	CALL	TCP.SEND_STATE_RESET
	XOR	A
	LD	(TCP.LINK_ID),A
	LD	(WIFI.RX_PAUSE_COUNT),A
	LD	(WIFI.RX_RESUME_COUNT),A
	LD	(WIFI.RX_PAUSE_OPEN_COUNT),A
	LD	(WIFI.RX_RESUME_OPEN_COUNT),A
	LD	(ISA.OPEN_COUNT),A
	LD	(ISA.CLOSE_COUNT),A
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CONNECT),A
	LD	HL,IN_CONNECT_STREAM
	LD	BC,IN_CONNECT_STREAM_LEN
	CALL	SET_INPUT
	CALL	TCP.MUX_WAIT_SEND_OK
	JP	C,FAILED
	ASSERT_W16 WIFI.INPUT_LEFT, IN_CONNECT_STREAM_TAIL_LEN
	LD	A,(TCP.WSO_FLAGS)
	AND	8
	JP	Z,FAILED
	ASSERT_B WIFI.RX_PAUSE_COUNT, 1
	ASSERT_B WIFI.RX_PAUSE_OPEN_COUNT, 1
	ASSERT_B TCP.MUX_CONNECT_PAUSED, 1
	ASSERT_B ISA.OPEN_COUNT, 1
	ASSERT_B ISA.CLOSE_COUNT, 1
	; The first RECV opens the UART window before raising RTS, then drains the
	; already queued +IPD payload through the open-window reader.
	LD	A,0
	LD	HL,RECV_DEST
	LD	BC,3
	LD	DE,1000
	CALL	TCP.RECEIVE_MUX
	JP	C,FAILED
	LD	(LAST_BC),BC
	ASSERT_W16 LAST_BC, 3
	LD	HL,RECV_DEST
	LD	DE,EXP_ABC
	LD	B,3
	CALL	CMP_MEM
	ASSERT_B WIFI.RX_RESUME_COUNT, 1
	ASSERT_B WIFI.RX_RESUME_OPEN_COUNT, 1
	ASSERT_B TCP.MUX_CONNECT_PAUSED, 0
	ASSERT_B ISA.OPEN_COUNT, 2
	ASSERT_B ISA.CLOSE_COUNT, 2

; ------------------------------------------------------------------
; Vector 19: a stale bare OK is not enough for CIPSTART, and CONNECT for the
; requested link (not merely any link notification) completes it.
; ------------------------------------------------------------------
	LD	A,19
	LD	(STAGE),A
	CALL	TCP.SEND_STATE_RESET
	LD	A,1
	LD	(TCP.LINK_ID),A
	LD	HL,IN_STALE_OK_CONNECT
	LD	BC,IN_STALE_OK_CONNECT_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED
	ASSERT_W16 WIFI.INPUT_LEFT, 0
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CONNECT),A

; ------------------------------------------------------------------
; Vector 20: CIPCLOSE completes on its own <id>,CLOSED even when another link
; is streaming. Waiting for a final OK here would recreate the shutdown hang.
; ------------------------------------------------------------------
	LD	A,20
	LD	(STAGE),A
	CALL	TCP.RX_DEFER_RESET_ALL
	XOR	A
	LD	(TCP.LINK_ID),A
	LD	A,1
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CLOSED),A
	LD	HL,IN_CLOSE_STREAM
	LD	BC,IN_CLOSE_STREAM_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	C,FAILED
	ASSERT_W16 WIFI.INPUT_LEFT, IN_CLOSE_STREAM_TAIL_LEN
	ASSERT_B TCP.MUX_CLOSED_MASK, 1
	SELECT_CH 1
	ASSERT_W16 TCP.DEFER_W, 4
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CLOSED),A

; ------------------------------------------------------------------
; Vector 21: a recovery CIPSTART may receive ALREADY CONNECTED when the first
; silent attempt opened the link but its CONNECT notification was lost.
; ------------------------------------------------------------------
	LD	A,21
	LD	(STAGE),A
	CALL	TCP.SEND_STATE_RESET
	LD	A,1
	LD	(TCP.LINK_ID),A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CONNECT),A
	LD	HL,IN_ALREADY_CONNECTED
	LD	BC,IN_ALREADY_CONNECTED_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	NC,FAILED
	CP	RES_ERROR
	JP	NZ,FAILED
	LD	A,(TCP.WSO_FLAGS)
	AND	0x10
	JP	Z,FAILED
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CONNECT),A

; ------------------------------------------------------------------
; Vector 22: CONNECT for another link must not poison the target-link recovery
; flag. Otherwise a delayed channel-0 notification can falsely open channel 1.
; ------------------------------------------------------------------
	LD	A,22
	LD	(STAGE),A
	CALL	TCP.SEND_STATE_RESET
	LD	A,1
	LD	(TCP.LINK_ID),A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CONNECT),A
	LD	HL,IN_FOREIGN_CONNECT_ERROR
	LD	BC,IN_FOREIGN_CONNECT_ERROR_LEN
	CALL	SET_INPUT
	CALL	TCP.WAIT_SEND_OK
	JP	NC,FAILED
	CP	RES_ERROR
	JP	NZ,FAILED
	LD	A,(TCP.WSO_FLAGS)
	AND	8
	JP	NZ,FAILED
	XOR	A
	LD	(TCP.MUX_ACCEPT_OK),A
	LD	(TCP.MUX_ACCEPT_CONNECT),A

	JP	PASSED

FAILED
	LD	A,(STAGE)
	LD	(TEST_RESULT),A
PASSED
	LD	A,0xA5
	LD	(TEST_MARKER),A
	JR	TEST_DONE
STAGE	DB 0

TEST_DONE
	HALT

; ------------------------------------------------------------------
; Helpers
; ------------------------------------------------------------------
SET_INPUT
	LD	(WIFI.INPUT_PTR),HL
	LD	(WIFI.INPUT_LEFT),BC
	RET

CMP_MEM
.l
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAILED
	INC	HL
	INC	DE
	DJNZ	.l
	RET

; Scripted byte source shared by both readers (the open-window reader is
; redirected here by ESP_TCP_TEST_READER; the send-window reader arrives
; through the WIFI stubs below).
TEST_READ_BYTE
	PUSH	HL
	LD	HL,(WIFI.INPUT_LEFT)
	LD	A,H
	OR	L
	JR	Z,.empty
	DEC	HL
	LD	(WIFI.INPUT_LEFT),HL
	LD	HL,(WIFI.INPUT_PTR)
	LD	A,(HL)
	INC	HL
	LD	(WIFI.INPUT_PTR),HL
	POP	HL
	LD	C,A
	AND	A			; CF=0: byte delivered
	RET
.empty
	POP	HL
	SCF
	RET

LAST_BC		DW 0

; Scripted UART input streams.
IN_OWN		DB "+IPD,0,5:HELLO"
IN_OWN_LEN	EQU $-IN_OWN
IN_FOREIGN	DB "+IPD,1,3:ABC"
IN_FOREIGN_LEN	EQU $-IN_FOREIGN
IN_PROMPT	DB "+IPD,1,4:WXYZ>"
IN_PROMPT_LEN	EQU $-IN_PROMPT
IN_SENDOK	DB "+IPD,1,2:QQ",13,10,"1,CLOSED",13,10,"Recv 3 bytes",13,10,"0,SEND OK",13,10
IN_SENDOK_LEN	EQU $-IN_SENDOK
IN_XCLOSE	DB "0,CLOSED",13,10,"+IPD,1,2:HI"
IN_XCLOSE_LEN	EQU $-IN_XCLOSE
IN_DATA_THEN_CLOSE DB "+IPD,1,4:TAIL",13,10,"1,CLOSED",13,10
IN_DATA_THEN_CLOSE_LEN EQU $-IN_DATA_THEN_CLOSE
IN_BIG_FOREIGN	DB "+IPD,1,40:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
IN_BIG_FOREIGN_LEN EQU $-IN_BIG_FOREIGN
IN_FOR_CH0	DB "+IPD,0,3:RST"
IN_FOR_CH0_LEN	EQU $-IN_FOR_CH0
IN_BACK2BACK	DB "+IPD,0,3:ABC+IPD,0,3:DEF"
IN_BACK2BACK_LEN EQU $-IN_BACK2BACK
IN_MIXED_BURST	DB "+IPD,0,3:ABC+IPD,1,3:UVW"
IN_MIXED_BURST_LEN EQU $-IN_MIXED_BURST
; Async suspend/resume splits.
IN_ASYNC1A	DB "+IP"		; silence falls mid-prefix
IN_ASYNC1A_LEN	EQU $-IN_ASYNC1A
IN_ASYNC1B	DB "D,1,3:ABC>Recv 3 bytes",13,10,13,10,"SEND OK",13,10
IN_ASYNC1B_LEN	EQU $-IN_ASYNC1B
IN_ASYNC2A	DB ">Recv 3 by"	; prompt+payload done, silence mid-line
IN_ASYNC2A_LEN	EQU $-IN_ASYNC2A
IN_ASYNC2B	DB "tes",13,10,"+IPD,1,2:ZZ",13,10,"SEND OK",13,10
IN_ASYNC2B_LEN	EQU $-IN_ASYNC2B
PAYLOAD_XYZ	DB "XYZ"
IN_PART_A	DB "AB"
IN_PART_A_LEN	EQU $-IN_PART_A
IN_PART_B	DB "CDE"
IN_PART_B_LEN	EQU $-IN_PART_B
IN_SPLIT_FRAME_A DB "1,5:AB"
IN_SPLIT_FRAME_A_LEN EQU $-IN_SPLIT_FRAME_A
IN_CONNECT_IPD_OK DB "0,CONNECT",13,10,"+IPD,0,5:HELLO",13,10,"OK",13,10
IN_CONNECT_IPD_OK_LEN EQU $-IN_CONNECT_IPD_OK
IN_BUSY		DB "busy p...",13,10
IN_BUSY_LEN	EQU $-IN_BUSY
IN_CONNECT_STREAM DB "0,CONNECT",13,10
IN_CONNECT_STREAM_TAIL DB "+IPD,0,3:ABC",13,10,"OK",13,10
IN_CONNECT_STREAM_LEN EQU $-IN_CONNECT_STREAM
IN_CONNECT_STREAM_TAIL_LEN EQU $-IN_CONNECT_STREAM_TAIL
IN_STALE_OK_CONNECT DB "OK",13,10,"0,CONNECT",13,10,"1,CONNECT",13,10
IN_STALE_OK_CONNECT_LEN EQU $-IN_STALE_OK_CONNECT
IN_CLOSE_STREAM DB "+IPD,1,2:QQ",13,10,"0,CLOSED",13,10
IN_CLOSE_STREAM_TAIL DB "+IPD,1,3:END"
IN_CLOSE_STREAM_LEN EQU $-IN_CLOSE_STREAM
IN_CLOSE_STREAM_TAIL_LEN EQU $-IN_CLOSE_STREAM_TAIL
IN_ALREADY_CONNECTED DB "ALREADY CONNECTED",13,10,"ERROR",13,10
IN_ALREADY_CONNECTED_LEN EQU $-IN_ALREADY_CONNECTED
IN_FOREIGN_CONNECT_ERROR DB "0,CONNECT",13,10,"ERROR",13,10
IN_FOREIGN_CONNECT_ERROR_LEN EQU $-IN_FOREIGN_CONNECT_ERROR

; Expected payloads and buffer contents ({len16le, payload}).
EXP_HELLO	DB "HELLO"
EXP_ABC		DB "ABC"
EXP_HI		DB "HI"
EXP_TAIL	DB "TAIL"
EXP_FRAME_ABC	DB 3,0,"ABC"
EXP_FRAME_WXYZ	DB 4,0,"WXYZ"
EXP_FRAME_QQ	DB 2,0,"QQ"
EXP_FRAME_ZZ	DB 2,0,"ZZ"
EXP_FRAME_UVW	DB 3,0,"UVW"
EXP_ABCDEF	DB "ABCDEF"
EXP_SPLIT	DB 2,0,"AB",3,0,"CDE"
EXP_FRAME_HELLO DB 5,0,"HELLO"

; ------------------------------------------------------------------
; Stubs for the modules esp_tcp.asm depends on.
; ------------------------------------------------------------------
	MODULE WIFI

RS_BUFF		EQU 0xD000
INPUT_PTR	DW 0
INPUT_LEFT	DW 0
CMD_LSR_ACCUM	DB 0		; line-error accumulator (send-window diagnostics)
TX_STRING_COUNT DB 0
RX_PAUSE_COUNT DB 0
RX_RESUME_COUNT DB 0
RX_PAUSE_OPEN_COUNT DB 0
RX_RESUME_OPEN_COUNT DB 0

; Send-window reader path (UART_WAIT_RS + UART_READ split).
UART_WAIT_RS
	PUSH	HL
	LD	HL,(INPUT_LEFT)
	LD	A,H
	OR	L
	POP	HL
	JR	Z,.empty
	OR	A			; CF=0: byte ready
	RET
.empty
	SCF
	RET

UART_READ
	PUSH	BC,DE,HL
	LD	HL,(INPUT_PTR)
	LD	A,(HL)
	INC	HL
	LD	(INPUT_PTR),HL
	LD	HL,(INPUT_LEFT)
	DEC	HL
	LD	(INPUT_LEFT),HL
	POP	HL,DE,BC
	RET

UART_TX_STRING
	LD	A,(TX_STRING_COUNT)
	INC	A
	LD	(TX_STRING_COUNT),A
	OR	A
	RET
UART_TX_BUFFER
	OR	A
	RET
UART_TX_CMD
	XOR	A
	RET
UART_EMPTY_RS
	RET
UART_SET_DATA_RX_MODE
	RET
UART_SET_DATA_RX_MODE_OPEN
	RET
UART_RX_PAUSE
	LD	A,(RX_PAUSE_COUNT)
	INC	A
	LD	(RX_PAUSE_COUNT),A
	RET
UART_RX_PAUSE_OPEN
	LD	A,(RX_PAUSE_COUNT)
	INC	A
	LD	(RX_PAUSE_COUNT),A
	LD	A,(RX_PAUSE_OPEN_COUNT)
	INC	A
	LD	(RX_PAUSE_OPEN_COUNT),A
	RET
UART_RX_RESUME
	LD	A,(RX_RESUME_COUNT)
	INC	A
	LD	(RX_RESUME_COUNT),A
	RET
UART_RX_RESUME_OPEN
	LD	A,(RX_RESUME_COUNT)
	INC	A
	LD	(RX_RESUME_COUNT),A
	LD	A,(RX_RESUME_OPEN_COUNT)
	INC	A
	LD	(RX_RESUME_OPEN_COUNT),A
	RET

	ENDMODULE

	MODULE ISA
OPEN_COUNT	DB 0
CLOSE_COUNT	DB 0
ISA_OPEN
	PUSH	HL
	LD	HL,OPEN_COUNT
	INC	(HL)
	POP	HL
	RET
ISA_CLOSE
	PUSH	HL
	LD	HL,CLOSE_COUNT
	INC	(HL)
	POP	HL
	RET
	ENDMODULE

	MODULE WCOMMON
CANCELLED	DB 0
CHECK_CANCEL_IN_ISA
	OR	A			; CF=0: never cancelled in the harness
	RET
	ENDMODULE

	MODULE UTIL
; Only STRCMP/STARTSWITH run on the tested paths; the rest resolve symbols.
; Both copy the real util.asm register/flag conventions.
STARTSWITH
	PUSH	HL,DE
.sw_next
	LD	A,(DE)
	OR	A
	JR	Z,.sw_end
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.sw_end
	INC	HL
	INC	DE
	JR	.sw_next
.sw_end
	POP	DE,HL
	RET
STRCMP
	PUSH	DE,HL
.next
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.ne
	AND	A
	JR	Z,.eq
	INC	DE
	INC	HL
	JR	.next
.ne
	SCF
.eq
	POP	HL,DE
	RET
UTOA
	RET
DELAY
	RET
DELAY_1MS
	RET
	ENDMODULE

	INCLUDE "esp_tcp.asm"

	END TEST_START
