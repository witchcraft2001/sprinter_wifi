; ======================================================
; libman 1.3 DLL loader - vendored for the Sprinter ESP Network Kit.
;
; Source: sources/libman/docs/libman13/LIBMAN13.ASM
;   (Module LIBMAN v1.3, last revision 30.04.2004).
; Derived from the original loader and wrapped in MODULE LIBMAN with an include
; guard so a consumer utility (e.g. UNETTEST) can embed it without symbol
; clashes. This copy also contains DSS error diagnostics, Estex-DSS register
; preservation fixes, and deterministic LDIR page copies. Original in-line
; comments are preserved (UTF-8, Russian). Understands L0 and L1 containers.
;
; Public entry points (module-qualified):
;   LIBMAN.l_load  HL=filename ASCIIZ, A=window(1/2/3) -> HL=handle, CF=1 err
;   LIBMAN.l_info  HL=handle, DE=32-byte buffer         -> CF=1 err
;   LIBMAN.l_call  HL=handle, B=function                -> per function
;   LIBMAN.l_free  HL=handle                            -> CF=1 err
; Consumer usage and the DLL calling convention are documented in
; docs/UNETAPI.md.
;
; NOTE: this loader must reside in 0x4000..0xBFFF (it maps DLL pages into
; window 3 during load/call). lib_table (256 B) and small state live in the
; loaded image and must stay zero-initialised across the program's lifetime.
; ======================================================

	IFNDEF	_LIBMAN13
	DEFINE	_LIBMAN13

	MODULE	LIBMAN



true	equ	1
false	equ	0

; NET: why the last l_load failed. Valid only when l_load returned CF=1.
; This is a Sprinter-ESP-Kit extension to the upstream libman 1.3 loader so a
; consumer (UNETTEST) can report the concrete reason instead of a bare error.
LR_NONE		equ	0
LR_MEMORY	equ	1	; GETMEM/SETWIN/FREEMEM failed (out of DSS pages)
LR_OPEN		equ	2	; DSS open failed (file not found in search dir)
LR_IO		equ	3	; seek/read failed mid-load
LR_FORMAT	equ	4	; not an L0/L1 container, or file > 64K
LR_INIT		equ	5	; DLL INIT hook refused (l_dsserr = the DLL's code)
LR_LIMIT	equ	6	; lib_table full (64 libraries already loaded)
LR_CALL		equ	7	; libman could not dispatch INIT (l_dsserr = LCERR_*)

LCERR_NONE	equ	0
LCERR_HANDLE	equ	1	; handle points at a free lib_table entry
LCERR_WINDOW	equ	2	; lib_table contains an invalid target window
LCERR_INIT	equ	3	; DLL INIT itself returned CF=1
LCERR_SETWIN	equ	4	; DSS_SETWIN failed before entering the DLL


; КОД ДОЛЖЕН БЫТЬ В ПРЕДЕЛАХ 4000h..0BFFFh !.

l_load:	jp	_L_LOAD
l_free:	jp	_L_FREE
l_call:	jp	_L_CALL
l_info:	jp	_L_INFO


;==================================================================
;  Таблица загрузки библиотек (макс. 64 шт.)
;==================================================================
; Размер таблицы: 256 байт
; Макс. число элементов: 64
; Длина элемента: 4 байта
; Структура отдельного элемента таблицы:
;
;    +00  - 0/1 свободен/занят
;    +01  - дескр. блока памяти
;    +02  - ст.байт адреса начала
;    +03  - ст.байт адреса конца

max_count equ	64			; макс. число загр. библиотек

lib_table:
	ds	256			; размер таблицы




;==================================================================
;  Загрузка библиотеки в память
;==================================================================
;   ld      hl,filename   ;имя файла
;   ld      a,win         ;окно 1,2,3
;   call    l_load
;   jp      c,error
;   ld      (handle),hl   ;дескр. библы
;
_L_LOAD:
	push	ix
	push	iy
	push	de
	push    af
	push    hl
	ld	a,LR_MEMORY		; NET: first stage is the 2-page GETMEM below
	ld	(l_reason),a
	xor	a
	ld	(l_dsserr),a
	ld	a,true
	ld	(ll_fr+1),a		; флаг релокации
	ld	(ll_fc+1),a		; флаг компрессии
	xor	a			; NET: clear the zero-run decoder flag so a prior
	ld	(llzero+1),a		; l_load that failed mid-decode can't corrupt this one
	in      a,(0E2h)
	ld      (lloldw+1),a		; сохр. начальную Page3
	; выделить блок в 2 страницы
	ld      bc,023Dh
	rst     10h
	jp      c,llerr1		; ошибка выделения
	ld      (llid),a		; дескр. выдел. блока памяти
	; сразу подготовить одну страницу
	; под загрузку файла библы.
	ld      bc,003Bh		; подкл. 1-ю страницу блока в 3-е окно
	rst     10h
	jp      c,llerr1		; ошибка подключения
	pop     hl
	ld	a,LR_OPEN		; NET: stage = opening the DLL file (HL=name)
	ld	(l_reason),a
	; открыть файл
	ld      a,1			; на чтение
	ld      c,11h
	rst     10h
	jp      c,llerr2
	ld      (llhand),a		; дескр. открытой библы
	ld	a,LR_IO			; NET: from here failures are seek/read I/O
	ld	(l_reason),a
	; указатель в конец файла
	ld      hl,0
	push	hl
	pop	ix
	ld      a,(llhand)		; NET: reload handle - the LR_IO store above
					; clobbered A, which the original relied on
					; holding the open handle for this MOVE_FP
	ld      bc,0215h		; MOVE_FP
	rst     10h
	jp      c,llerr0		; ошибка перемещения указателя
	ld      a,h
	or      l
	jp      nz,llfmt0		; NET: слишком большой файл (LR_FORMAT)
	push    ix			; размер файла, мл.разряд
	; вернуть указатель в начало файла
	ld      hl,0
	push	hl
	pop	ix
	ld      a,(llhand)		; дескр. открытой библы
	ld      bc,0015h		; MOVE_FP
	rst     10h
	pop     hl
	ld      (llsize),hl		; размер библы
	jp      c,llerr0		; ошибка перемещения указателя
	; чтение файла
	ld      c,13h
	ld      de,16			; число чит. байт
	ld      hl,llbuf		; буфер первых 16-ти байт заголовка
	ld      a,(llhand)		; дескр. открытой библы
	rst     10h
	jp      c,llerr0
	; вернуться в начало файла
	ld      hl,0
	push	hl
	pop	ix
	ld      a,(llhand)		; дескр. открытой библы
	ld      bc,0015h		; MOVE_FP
	rst     10h
	jp      c,llerr0		; ошибка перемещения указателя
	; берем данные из первых 16-ти байт заголовка
	ld	ix,llbuf		; буфер первых 16-ти байт заголовка
	ld	a,(ix+0)
	cp	"L"
	jp	nz,llfmt0		; NET: не знакомый формат библы (LR_FORMAT)
	ld	e,true
	ld	a,(ix+1)
	cp	"1"
	jr	z,ll0s
	cp	"0"
	jp	nz,llfmt0		; NET: не верный формат библы (LR_FORMAT)
	dec	e
ll0s:	ld	a,e
	ld	(l1_form+1),a		; true/false  уст. формат библы
	ld      e,(ix+2)		; общ. размер библы (de идет для функ.чтения)
	ld      d,(ix+3)
	ld	l,(ix+4)		; размер библы без рел-таблицы
	ld	h,(ix+5)
	ld	c,(ix+6)		; размер рел-таблицы
	ld	b,(ix+7)
	; библа сжата ? (de=hl ?)
	add	hl,bc			; заголовок + код библы = размер библы
	ld	a,h
	cp	d
	jr	nz,ll0r			; сжата
	ld	a,l
	cp	e
	jr	nz,ll0r			; сжата
	xor	a			; false
	ld	(ll_fc+1),a		; сбр. флаг компрессии (библа не сжата)
	; библа перемещаемая ?
ll0r:	ld	a,b
	cp	c
	jr	nz,ll0			; да, рел-таблица не равна нулю
	xor	a			; false
	ld	(ll_fr+1),a		; сбр. флаг релокации
	; прочитать всю библу в подгот. страницу
	; de=размер библы
ll0:	ld      c,13h
	ld      hl,0C000h		; буфер чтения
	ld      a,(llhand)		; дескр. библы
	rst     10h
	jp      c,llerr0		; ошибка чтения
	;
	ld      hl,0C000h		; начало 0-й страницы
	ld      d,h			; также для 1-й страницы
	ld      e,l
	; hl - упак. данные в 0-й странице
	; de - распак. данные в 1-й странице
loop:	ld      bc,16			; размер "порции"
	push    de
	ld      de,llbuf		; исп. буфер первых 16-ти байт заголовка
	; NET: use an ordinary Z80 copy here. The original accelerator sequence is
	; sensitive to the exact Sprinter accelerator state and can leave a valid
	; L1 header with a damaged code body. Sixteen-byte LDIR chunks are fast
	; enough for a <16 KB DLL and deterministic on DSS/emulators/hardware.
	ldir
	push    hl
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      bc,013Bh		; подкл. 2-ю страницу блока в 3-е окно
	rst     10h
	pop     hl
	pop     de
	jp      c,llmem0		; NET: ошибка подкл. страницы (LR_MEMORY)
	ld      bc,16			; decoder chunk size (DSS may clobber BC)
	push    hl
	ld      hl,llbuf		; буфер первых 16-ти байт заголовка
ll_fc:	ld	a,true			; флаг компрессии
	or	a
	jr	z,ll1z			; не было компрессии
	; de == 0C010h ?
	ld      a,d
	cp      0C0h			; ст.байт начала страницы
	jr      nz,ll2
	ld      a,e
	cp      10h			; размер блока
	jr      nc,ll2
	; аксель
ll1z:	di
	ld      bc,16
	ldir
	ei
	jr      ll3
;-
ll2:	ld	b,c			; b=16
llzero:	ld      a,false			; флаг последовательности нулей
	or      a
	jr      z,ll2a			; false
	xor     a
	ld      (llzero+1),a
	jr      ll2c
	;
ll2a:	ld      a,(hl)
	or      a
	jr      nz,ll2b
	inc     hl
	dec     b
	jr      z,ll2e
ll2c:	ld      (de),a
	inc     de			; de++ for decoding
	dec     (hl)
	jr      nz,ll2c
	inc     hl
	jr      ll2d
	;
ll2e:	ld      a,true
	ld      (llzero+1),a		; флаг последовательности нулей
	jr      ll3
	;
ll2b:	ld      (de),a
	inc     hl
	inc     de
ll2d:	djnz	ll2a
;-
ll3:	push    de
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      bc,003Bh		; подкл. 1-ю страницу блока в 3-е окно
	rst     10h
	pop     de
	pop     hl			; hl=0C010h ?
	ld      a,(llsize+1)		; ст.байт размера библы
	ld      b,a
	ld      a,h
	sub     0C0h
	cp      b
	jp      c,loop			; назад в цикл
	jr      nz,ll4
	ld      a,(llsize)		; мл.байт размера библы
	ld      b,a
	ld      a,l
	cp      b
	jp      c,loop			; назад в цикл
	;
ll4:	xor     a			; false
	ld      (llzero+1),a		; флаг последов. нулей
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      bc,013Bh		; подкл. 2-ю страницу в 3-е окно
	rst     10h
	ld      hl,0C004h		; +4 адрес начала рел-таблицы (заголовок)
	ld      e,(hl)
	inc     hl
	ld      d,(hl)
	inc     hl
	ex      de,hl
	push    hl
	pop     iy			; начало рел-таблицы (для remake)
	dec     hl
ll_fr:	ld	a,true			; флаг релокации
	or	a
	jr	nz,ll4a
	; библа была не перемещаемая (без рел-таблицы)
	ld	hl,4000h		; макс. размер не перемещ. библы
ll4a:	ld      (llsize),hl		; размер библы (код)
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      bc,003Bh		; подкл. 1-ю страницу в 3-е окно
	rst     10h
	; Clear the 256-byte page-occupancy table without relying on accelerator
	; pseudo-instructions (see the transfer loop above).
	ld      hl,0C000h
	ld      de,0C001h
	ld      bc,255
	ld      (hl),0
	ldir
	ld      hl,lib_table		; 256 байт, таблица библ
	ld      b,max_count		; 64 макс. число загр. библиотек
ll5:	ld      a,(hl)
	or      a
	jr      z,ll5c
	push    hl
	pop     ix			; адрес в таблице библ
	ld      h,0C0h
	ld      l,(ix+1)
	ld      a,(ix+3)
	and     3Fh
	inc     a
	cp      (hl)
	jr      c,ll5a
	ld      (hl),a
ll5a:	push    ix
	pop     hl
ll5c:	inc     hl
	inc     hl
	inc     hl
	inc     hl
	djnz	ll5
	ld      hl,lib_table		; 256 байт таблица библ
	ld      b,max_count		; 64 макс. число загр. библиотек
ll5b:	ld      a,(hl)
	or      a
	jr      z,ll6
	inc     hl
	inc     hl
	inc     hl
	inc     hl
	djnz	ll5b
	jp      lltbl0			; NET: таблица библ заполнена (LR_LIMIT)
	;
ll6:	push    hl
	pop     ix			; адрес в таблице
	; просканировать таблицу
	ld      hl,0C000h
	ld      bc,256			; размер таблицы
ll7:	ld      a,(hl)
	or      a
	jr      nz,ll8			; занятая запись
ll7a:	inc     hl
	dec     bc
	ld      a,b
	or      c
	jr      nz,ll7
	; выделить блок в 1-ну страницу
	ld      bc,013Dh
	rst     10h
	jp      c,llmem0		; NET: ошибка выделения (LR_MEMORY; was llerr4)
	ld      l,a
	ld      d,0
	ld      a,(llsize+1)		; ст.байт размера библы
	jr      ll8c
	;
ll8:	ld      d,a
	ld      a,(llsize+1)		; ст.байт размера библы
	add     a,d
	cp      40h			; (40)00
	jr      nc,ll7a
ll8c:	ld      e,a
	pop     af			; 0
	; A = окно (1,2,3)
	dec	a			; a=1 ?
	jr      nz,ll8a
	ld      a,40h			; (40)00	page 1
	jr      ll9
ll8a:	dec	a			; a=2 ?
	jr      nz,ll8b
	ld      a,80h			; (80)00	page 2
	jr      ll9
ll8b:	ld      a,0C0h			; (C0)00	page 3
ll9:	ld	c,a
	add     a,d
	ld      d,a
	ld	a,c			; восст."a"
	add     a,e
	ld      e,a
	ld      (ix+0),true		; флаг "занятый элемент" в таблице
	ld      (ix+1),l		; дескр. страницы библы
	ld      (ix+2),d		; ст.байт адреса начала библы
	ld      (ix+3),e		; ст.байт адреса конца библы
	push	de
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      bc,013Bh		; подкл. 2-ю страницу в 3-е окно
	rst     10h
	pop	bc			; новый адрес кода
	; Do not carry IY across the GETMEM/SETWIN calls above. Estex-DSS and BIOS
	; do not guarantee index-register preservation there; a clobbered IY makes
	; remake read a bogus relocation bitmap and the first DLL call can jump to
	; garbage (DSS then reports #27, unexpected application termination).
	; Rebuild the bitmap pointer from the canonical header now that page 2 is
	; mapped, immediately before relocation. This mirrors current libman 1.3.
	ld	hl,0C004h
	ld	e,(hl)
	inc	hl
	ld	d,(hl)
	push	de
	pop	iy
	ld	de,0C000h
	add     iy,de			; начало рел-таблицы + 0C000h
	ld	hl,0C000h		; адрес исх. кода
l1_form:ld	a,true			; флаг формата библы
	or	a
	jr	z,nofix			; "L0" формат
	; "L1" формат
	ld	de,32			; длина заголовка
	add	hl,de			; скоррект. начало исх. кода
nofix:	ld      de,(llsize)		; длина кода (размер библы)
	ld	a,(ll_fr+1)		; флаг релокации
	or	a
	call	nz,remake		; настроить переходы
	ld      hl,0C000h
	ld      a,(ix+2)
	or      0C0h
	ld      d,a
	ld      e,0
ll10:	push    de
	ld      de,llbuf		; буфер первых 16-ти байт заголовка
	ld      bc,16
	ldir
	pop     de
	push    hl
	push	de
	ld      a,(ix+1)		; дескр. блока из 2-х страниц
	ld      bc,003Bh		; подкл. 1-ю страницу в 3-е окно
	rst     10h
	pop	de
	ld      hl,llbuf		; буфер первых 16-ти байт заголовка
	ld      bc,16
	ldir
	push	de
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      bc,013Bh		; подкл. 2-ю страницу в 3-е окно
	rst     10h
	pop	de
	pop     hl
	ld      a,(ix+3)
	or      0C0h
	cp      d
	jr      nc,ll10
	ld      a,(ix+1)		; дескр. блока из 2-х страниц
	ld      bc,003Bh		; подкл. 1-ю страницу в 3-е окно
	rst     10h
	push    ix
	ld      a,(llid)		; дескр. выдел. блока из 2-х страниц
	ld      c,3Eh			; освободить блок памяти
	rst     10h
	jp      c,llmem0		; NET: ошибка освобождения (LR_MEMORY; was llerr5)
	pop     hl
	ld      bc,lib_table		; 256 байт таблица библ
	sbc     hl,bc
	ld      a,l
	rra				; 2-й бит (4-ки) на место 0-го
	rra				; адрес ячейки в таблице библ -> в номер дескр.
	ld      l,a			; номер дескр. загр. библы
	ld      h,0
	ld      b,h			; 0-й номер функции
lloldw:	ld      a,-1			; сохр. начальная Page3
	out     (0E2h),a		; восст. страницу
	call    l_call			; иниц. (загрузить) библу
	push	af
	push	hl
	ld      a,(llhand)		; дескр. библы
	ld      c,12h			; закрыть файл
	rst     10h
	jr      c,llerr1		; ошибка закрытия
	pop	hl
	pop	af
	pop	de
	pop	iy
	pop	ix
	ret	nc
	push	af			; INIT/dispatcher refused: preserve returned A/CF
	ld	a,(l_call_error)
	cp	LCERR_INIT
	jr	z,.init_refused
	cp	LCERR_SETWIN
	jr	z,.call_setwin
	ld	(l_dsserr),a		; NET: internal l_call stage, not DLL's A
	ld	a,LR_CALL
	ld	(l_reason),a
	jr	.release_failed
.call_setwin
	ld	a,(l_call_dsserr)
	ld	(l_dsserr),a		; raw DSS_SETWIN error
	ld	a,LR_CALL
	ld	(l_reason),a
	jr	.release_failed
.init_refused
	pop	af
	push	af
	ld	(l_dsserr),a		; NET: record the DLL INIT refusal code
	ld	a,LR_INIT
	ld	(l_reason),a
.release_failed
	call	l_free			; выгрузить библу
	pop	af
	ret
	;
	; NET: failure-reason ladder. Each entry records LIBMAN.l_reason (stage)
	; and LIBMAN.l_dsserr (the raw DSS/INIT code) so a consumer can report WHY
	; the load failed, then returns the original contract (CF=1, A=-1).
	; The upstream llerr4 (`pop hl` -> one pop too many) and llerr5 (no pop)
	; unwinds were stack-unbalanced and jumped through garbage on rare DSS
	; failures; their sites now enter via llmem0 -> llerr0c, which closes the
	; file and pops exactly the four saved register words.
llfmt0:	ld	a,LR_FORMAT		; NET: not an L0/L1 container / file > 64K
	ld	(l_reason),a
	xor	a
	ld	(l_dsserr),a		; no DSS code - the bytes were wrong
	jr	llerr0c
	;
lltbl0:	ld	a,LR_LIMIT		; NET: lib_table full (64 libraries)
	ld	(l_reason),a
	xor	a
	ld	(l_dsserr),a		; A is not an error code here
	jr	llerr0c
	;
llmem0:	ld	(l_dsserr),a		; NET: DSS error from GETMEM/SETWIN/FREEMEM
	ld	a,LR_MEMORY
	ld	(l_reason),a
	jr	llerr0c
	;
llerr0:	ld	(l_dsserr),a		; NET: DSS error from seek/read (A still live)
llerr0c:
	ld      a,(llhand)		; дескр. библы
	ld      c,12h			; закрыть файл
	rst     10h
	jr      llerr2c			; NET: keep the recorded error (skip re-store)
	;
llerr1:	pop     hl
llerr2:	ld	(l_dsserr),a		; NET: DSS error from alloc/open (A still live)
llerr2c:
	pop     af
	pop	de
	pop	iy
	pop	ix
llerr3:	scf
	ld	a,-1
	ret

llbuf:	ds	16			; буфер первых 16-ти байт заголовка
llsize:	dw	0			; размер библы
llid:	db	0			; дескр. выдел. блока из 2-х страниц
llhand:	db	0			; дескр. открытой библы
l_reason:	db	0		; NET: LR_* stage of the last failed l_load
l_dsserr:	db	0		; NET: raw DSS/INIT code at that failure



;==================================================================
;  Коррекция адресов переходов по таблице перемещений
;==================================================================
; de = длина кода
; bc = новый адрес кода (b=старший байт)
; hl = адрес коррект. кода
; iy = начало рел-таблицы
;
remake:	ld	c,b
rmk1:	ld	b,8			; разрядность байта
	ld	a,(iy+0)
rmk2:	rla
	call	c,reloc			; правка ст.байта адреса
	ex	af,af'
	inc	hl
	dec	de
	ld	a,d
	or	e
	ret	z
	ex	af,af'
	djnz	rmk2
	inc	iy
	jr	rmk1
	;
reloc:	ex	af,af'
	ld	a,(hl)
	add	a,c
	ld	(hl),a
	ex	af,af'
	ret





;==================================================================
;  Выгрузка библиотеки из памяти
;==================================================================
;
;    ld      hl,(handle)
;    call    l_free
;    jp      c,error
;
_L_FREE:
	push	de
	push	bc
	ld      b,1			; номер функции
	call    l_call
	;ld      d,0
	;ld      e,l
	ex	de,hl			; поставил
	ld      hl,lib_table		; 256 байт таблица библ
	add     hl,de
	add     hl,de
	add     hl,de
	add     hl,de
	ld      a,(hl)			; +0 свободна/занята
	or      a
	scf
	jr      z,lf_ee
	ld      (hl),0
	inc     hl
	ld      c,(hl)			; +1 дескр. окна
	ld      hl,lib_table		; 256 байт таблица библ
	ld      b,max_count		; 64 макс. число загр. библиотек
	ld      e,0
lf1:	ld      a,(hl)
	or	a			; LD does not set Z: test this table entry explicitly
	jr      z,lf2
	inc     hl
	ld      a,(hl)
	cp      c
	jr      nz,lf3
	inc     e
	jr      lf3
	;
lf2:	inc     hl
lf3:	inc     hl
	inc     hl
	inc     hl
	djnz	lf1
	ld      a,e
	or      a
	jr      nz,lf_e
	ld      a,c			; дескр. блока
	ld      c,3Eh			; освободить блок
	rst     10h
	jr	lf_ee
	;
lf_e:	xor     a
lf_ee:	pop	bc
	pop	de
	ret




;==================================================================
;  Вызов процедур библиотеки на исполнение
;==================================================================
; Передаваемые параметры в: a,de,ix,iy and alt. regs
;
;    ld      hl,(handle)  ;дескр. библы
;    ld      b,function   ;номер функции
;    call    l_call
;    jp      c,error
;
;    out: hl=handle
;
_L_CALL:
	push    hl
	push    de
	push    bc
	push    af
	xor	a
	ld	(lcflag),a
	ld	(l_call_error),a
	ld	(l_call_dsserr),a
	ld	a,b			; номер функции
	ld	(lc_fun),a
	ld      a,l			; дескр. библы
	rla				; 0-й бит на место 2-го
	rla				; восст. адрес ячейки в таблице библ
	ld      l,a
	ld      de,lib_table		; 256 байт таблица библ
	add     hl,de			; перейти на адрес элемента таблицы
	ld      a,(hl)			; +0 ячейка занятости
	or      a
	jp      z,lc_er2		; ошибка, элемент не занят
	inc     hl
	ld      a,(hl)			; +1 дескр. блока памяти
	push    af
	inc     hl
	ld      h,(hl)			; +2 ст.байт адрес начала
	ld      l,20h			; смещ. на размер заголовка
	ld      (lcstart),hl		; начало кода библы в окне
	ld      a,h
	and     0C0h
	ld      (lcoldp),a
	cp      40h
	jr      nz,lc1
	in      a,(0A2h)
	jr      lc3
	;
lc1:	cp      80h
	jr      nz,lc2
	in      a,(0C2h)
	jr      lc3
	;
lc2:	cp      0C0h
	jr      nz,lc_er3
	in      a,(0E2h)
lc3:	ld      (lc4_+1),a
	pop     af			; дескр. блока памяти (из +1)
	; IX/IY are public DLL argument registers. Estex-DSS/BIOS does not promise
	; to preserve them while SETWIN resolves the physical page, so keep the
	; caller's values until immediately before entering the export function.
	push	ix
	push	iy
	; Do not use generic DSS_SETWIN (#38) here. Current Estex-DSS derives the
	; slot port with OR %100'0010 (0x42 instead of 0x82), so WIN1 is written
	; through port 0x62 instead of SLOT1/0xA2. l_call already knows the target
	; window from H; select the explicit, working API entry point.
	ld      b,0			; first page of the allocated DLL block
	bit     7,h
	jr      z,lc_map_win1
	bit     6,h
	jr      z,lc_map_win2
	ld      c,3Bh			; DSS_SETWIN3
	jr      lc_map
lc_map_win1:
	ld      c,39h			; DSS_SETWIN1
	jr      lc_map
lc_map_win2:
	ld      c,3Ah			; DSS_SETWIN2
lc_map:
	rst     10h
	jr	c,lc_setwin_error	; Estex-DSS defines CF=1 as a real mapping error
	pop	iy
	pop	ix
	pop     af
	pop     bc
	pop     de
	; возможные передаваемые
	; аргументы функции:
	; a,de,ix,iy and alt. regs
	ld      hl,(lcstart)		; начало кода библы в окне
	ld      c,b			; номер передаваемой функции
	ld      b,0
	add     hl,bc			;1+1=2 обойти init, free (0,1) функции
	add     hl,bc			;2+1=3
	add     hl,bc			;3+1=4
	ld      bc,lc_
	push    bc			; в стек точку возврата
	jp      (hl)			; Вызов функции

lc_:	pop     hl			; восст. вход. дескриптор (и баланс стека)
	ld	c,a			; сохр."a"
	jr	nc,lc4_
	ld	a,(lc_fun)
	or	a			; тест на 0-ю функцию
	jr	nz,lc4_
	ld	a,LCERR_INIT
	ld	(l_call_error),a
	dec	a			; a=0FFh
	ld	(lcflag),a
lc4_:	ld      a,-1
	ld      b,a
	ld      a,(lcoldp)
	cp      40h
	jr      nz,lc1_
	ld      a,b
	out     (0A2h),a
	jr      lc3_
	;
lc1_:	cp      80h
	jr      nz,lc2_
	ld      a,b
	out     (0C2h),a
	jr      lc3_
	;
lc2_:	cp      0C0h
	jr      nz,lc_er0
	ld      a,b
	out     (0E2h),a
lc3_:	ld	a,(lcflag)
	rlca				; уст. carry-флаг
	ld	a,c			; восст."a"
	ret
	;
lc_er3:ld	a,LCERR_WINDOW
	ld	(l_call_error),a
	pop     af			; discard saved block descriptor
	jr	lc_er2_unwind
lc_setwin_error:
	ld	(l_call_dsserr),a	; preserve DSS error before restoring caller AF
	pop	iy			; discard SETWIN-protected public arguments
	pop	ix
	ld	a,LCERR_SETWIN
	ld	(l_call_error),a
	jr	lc_er2_unwind
lc_er2:ld	a,LCERR_HANDLE
	ld	(l_call_error),a
lc_er2_unwind:
	pop     af
	pop     bc
	pop     de
lc_er1:	pop     hl
lc_er0:	scf
	ret


lcstart:dw	0
lcoldp:	db	0
lc_fun:	db	0
lcflag:	db	0
l_call_error:
	db	0
l_call_dsserr:
	db	0





;==================================================================
;  Получить информацию о библиотеке
;==================================================================
; copy lib info to buffer
;
;    ld      hl,(handle)    ;дескр. библы
;    ld      de,buffer32    ;буфер, 32 байта
;    call    l_info
;    jp      c,error
;
_L_INFO:
	push    hl
	push    de
	push    bc
	ld      a,l
	add	a,a			; handle * 4; do not depend on caller CF
	add	a,a
	ld	l,a
	ld      bc,lib_table		; 256 байт таблица библ
	add     hl,bc
	ld      a,(hl)			;+0 флаг "свободна/занята"
	or      a
	scf
	jr      z,li_er			; ошибка
	inc     hl
	ld      b,(hl)			;+1 дескр. страницы библы
	inc     hl
	ld      a,(hl)
	or      0C0h
	ld      h,a
	ld      l,0
	in      a,(0E2h)
	ld      (lioldw+1),a
	push	hl			; Estex-DSS SETWIN clobbers HL while deriving SLOT
	push	de			; and does not promise to preserve DE either
	ld      a,b			; дескр. страницы библы
	ld      bc,003Bh		; подкл. в 3-е окно
	rst     10h
	pop	de
	pop	hl
	jr	c,li_map_error
	ld      bc,32			; длина info
	ldir
lioldw:	ld	a,-1			; восст. порт
	out	(0E2h),a
	xor	a
	jr	li_er
li_map_error:
	ld	a,(lioldw+1)		; restore WIN3 without destroying the failure path
	out	(0E2h),a
	scf
li_er:	pop	bc
	pop	de
	pop	hl
	ret

	ENDMODULE

	ENDIF
