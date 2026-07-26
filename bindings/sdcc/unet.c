/*
 * unet.c - UNET DLL loader + call wrappers for the SDCC Sprinter SDK.
 *
 * Loads a libman 1.3 / L1 DLL: allocates a page, maps it into the target
 * window, streams the file through a small chunk buffer while decompressing
 * the zero-RLE image straight into the window, applies the L1 relocation
 * bitmap, and calls the DLL INIT hook. Function calls go through a tiny asm
 * trampoline (unetll.s) that marshals the A/DE/IX/IY register convention the
 * DLL expects.
 *
 * Static footprint: one 256-byte chunk buffer + the 1 KB relocation bitmap.
 * Any DLL whose decoded image fits the 16 KB window loads, regardless of
 * file size.
 *
 * After unet_free() the window's contents are undefined (the page is
 * returned to DSS but no previous mapping is restored - DSS has no
 * "query current window" call); do not touch the window afterwards.
 */
#include "unet.h"

/* Register block exchanged with the DLL through the asm trampoline. */
typedef struct {
    u8  a;
    u16 de;
    u16 ix;
    u16 iy;
} unet_regs;

extern void unet_raw_call(u16 target, unet_regs *r);

#define UNET_RELOC_MAX  1024
#define UNET_CHUNK      256

static u8  g_block = 0xFF;      /* GETMEM block id, 0xFF = none loaded */
static u16 g_base  = 0;         /* window base address (0x4000 / 0x8000) */

static u8 s_bitmap[UNET_RELOC_MAX];

/* Sequential-read state for the streaming decoder. */
static u8  s_chunk[UNET_CHUNK];
static u16 s_chunk_len, s_chunk_pos;
static u16 s_file_left;
static i16 s_fd;

static u16 rd16(const u8 *p) { return (u16)p[0] | ((u16)p[1] << 8); }

/* Invoke DLL function fn with the given register inputs; return its A. */
static u8 call_fn(u8 fn, unet_regs *r)
{
    unet_raw_call(g_base + 0x20 + (u16)fn * 3, r);
    return r->a;
}

/* Next file byte (0..255), or -1 on EOF / read error. */
static i16 next_byte(void)
{
    u16 want;
    if (s_chunk_pos >= s_chunk_len) {
        want = (s_file_left < UNET_CHUNK) ? s_file_left : UNET_CHUNK;
        if (want == 0) return -1;
        if (dss_read(s_fd, s_chunk, want) != (i16)want) return -1;
        s_file_left -= want;
        s_chunk_len = want;
        s_chunk_pos = 0;
    }
    return s_chunk[s_chunk_pos++];
}

/*
 * Store decoded output byte number op:
 *   op <  code_size  -> the window page (code image incl 32-byte header)
 *   op >= code_size  -> the relocation bitmap
 */
static u8 *s_page;
static u16 s_code_size;

static void put_out(u16 op, u8 v)
{
    if (op < s_code_size) s_page[op] = v;
    else                  s_bitmap[op - s_code_size] = v;
}

/*
 * Decode the stream (16-byte verbatim prefix + zero-RLE remainder, or a
 * plain byte-for-byte image when not compressed) into page + bitmap.
 * Returns 0 on success, -1 on a malformed/short stream.
 */
static i8 decode_stream(u16 expected, u8 compressed)
{
    u16 op = 0;
    i16 v;
    u16 cnt;

    if (!compressed) {
        while (op < expected) {
            if ((v = next_byte()) < 0) return -1;
            put_out(op++, (u8)v);
        }
        return 0;
    }

    while (op < 16 && op < expected) {          /* verbatim prefix */
        if ((v = next_byte()) < 0) return -1;
        put_out(op++, (u8)v);
    }
    while (op < expected) {
        if ((v = next_byte()) < 0) return -1;
        if (v) {
            put_out(op++, (u8)v);
            continue;
        }
        if ((v = next_byte()) < 0) return -1;
        cnt = (u16)v;
        if (cnt == 0) cnt = 256;
        while (cnt-- && op < expected) put_out(op++, 0);
    }
    return 0;
}

i8 unet_load(const char *dll_name, u8 window)
{
    u16 file_size, code_size, reloc_size, i;
    u8  compressed, page_hi;
    u8 *page;
    u8  hdr[8];
    unet_regs r;

    if (window == 1)      g_base = 0x4000;
    else if (window == 2) g_base = 0x8000;
    else                  return UNET_LOAD_EWINDOW;   /* window must be 1 or 2 */

    g_block = dss_getmem();
    if (g_block == 0xFF) return UNET_LOAD_ENOMEM;
    dss_setwin(window, g_block);
    page = (u8 *)g_base;

    /* dll_name is resolved against the DSS current directory (libman/DSS do
       not search PATH or the program's own directory). Pass a full path, or
       run the program from the directory that holds the DLL. */
    s_fd = dss_open(dll_name, O_RDONLY);
    if (s_fd < 0) { dss_freemem(g_block); g_block = 0xFF; return UNET_LOAD_EOPEN; }

    /* The size fields live in the first 8 bytes, which are verbatim in the
       stream even when the image is compressed (16-byte verbatim prefix). */
    if (dss_read(s_fd, hdr, 8) != 8) goto bad_format;
    if (hdr[0] != 'L' || hdr[1] != '1') goto bad_format;

    file_size  = rd16(hdr + 2);
    code_size  = rd16(hdr + 4);
    reloc_size = rd16(hdr + 6);

    if (file_size < 8 || code_size < 32 || (code_size + reloc_size) < 32)
        goto bad_format;
    if (reloc_size > UNET_RELOC_MAX) {
        dss_close(s_fd); dss_freemem(g_block); g_block = 0xFF;
        return UNET_LOAD_ETOOBIG;
    }
    if ((code_size - 32) > 0x4000u) goto bad_format;

    dss_seek(s_fd, 0, SEEK_SET);
    s_file_left = file_size;
    s_chunk_len = s_chunk_pos = 0;
    s_page      = page;
    s_code_size = code_size;

    compressed = (u8)((code_size + reloc_size) != file_size);
    if (decode_stream(code_size + reloc_size, compressed) != 0) goto bad_format;
    dss_close(s_fd);

    /* L1 relocation: add the page high byte to every flagged code byte. */
    page_hi = (u8)(g_base >> 8);
    for (i = 0; i < (u16)(reloc_size * 8); i++) {
        if (s_bitmap[i >> 3] & (0x80 >> (i & 7))) {
            if ((u16)(32 + i) < code_size)
                page[32 + i] += page_hi;
        }
    }

    /* INIT hook (function 0): A=0 on success, non-zero = refuse. */
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    if (call_fn(UNET_FN_INIT, &r) != 0) {
        dss_freemem(g_block); g_block = 0xFF; return UNET_LOAD_EINIT;
    }
    return UNET_LOAD_OK;

bad_format:
    dss_close(s_fd);
    dss_freemem(g_block); g_block = 0xFF;
    return UNET_LOAD_EFORMAT;
}

void unet_free(void)
{
    unet_regs r;
    if (g_block == 0xFF) return;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    call_fn(UNET_FN_FINI, &r);
    dss_freemem(g_block);
    g_block = 0xFF;
}

u16 unet_caps(void)
{
    unet_regs r;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    call_fn(UNET_FN_GETCAPS, &r);
    return r.de;
}

i8 unet_init(void)
{
    unet_regs r;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    return (i8)call_fn(UNET_FN_NETINIT, &r);
}

i8 unet_done(void)
{
    unet_regs r;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    return (i8)call_fn(UNET_FN_NETDONE, &r);
}

i8 unet_connect(const char *host, const char *port)
{
    unet_regs r;
    r.a = 0;                       /* channel 0 */
    r.de = (u16)host;
    r.ix = (u16)port;
    r.iy = 0;
    return (i8)call_fn(UNET_FN_CONNECT, &r);
}

i8 unet_udpopen(const char *host, const char *rport, const char *lport)
{
    unet_regs r;
    r.a = 0;
    r.de = (u16)host;
    r.ix = (u16)rport;
    r.iy = (u16)lport;             /* NULL -> default local port */
    return (i8)call_fn(UNET_FN_UDPOPEN, &r);
}

i16 unet_send(const void *buf, u16 len)
{
    unet_regs r;
    u8 st;
    r.a = 0;
    r.de = (u16)buf;
    r.ix = len;
    r.iy = 0;
    st = call_fn(UNET_FN_SEND, &r);
    if (st != NERR_OK) return (i16)(-(i16)st);
    return (i16)r.de;              /* bytes sent */
}

i16 unet_recv(void *buf, u16 max, u16 timeout_ms, u16 *flags)
{
    unet_regs r;
    u8 st;
    r.a = 0;
    r.de = (u16)buf;
    r.ix = max;
    r.iy = timeout_ms;
    st = call_fn(UNET_FN_RECV, &r);
    if (flags) *flags = r.ix;
    if (st == NERR_OK) return (i16)r.de;          /* >0 data, 0 idle */
    return (i16)(-(i16)st);                        /* -NERR_CLOSED etc. */
}

i8 unet_close(void)
{
    unet_regs r;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    return (i8)call_fn(UNET_FN_CLOSE, &r);
}

i8 unet_resolve(const char *host, char *dst)
{
    unet_regs r;
    r.a = 0;
    r.de = (u16)host;
    r.ix = (u16)dst;
    r.iy = 0;
    return (i8)call_fn(UNET_FN_RESOLVE, &r);
}

i16 unet_ping(const char *host, u16 timeout_ms)
{
    unet_regs r;
    u8 st;
    r.a = 0;
    r.de = (u16)host;
    r.ix = 0;
    r.iy = timeout_ms;
    st = call_fn(UNET_FN_PING, &r);
    if (st != NERR_OK) return (i16)(-(i16)st);
    return (i16)r.de;              /* round-trip ms */
}

void unet_rxpause(void)
{
    unet_regs r;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    call_fn(UNET_FN_RXPAUSE, &r);
}

void unet_rxresume(void)
{
    unet_regs r;
    r.a = 0; r.de = 0; r.ix = 0; r.iy = 0;
    call_fn(UNET_FN_RXRESUME, &r);
}

i8 unet_getinfo(u8 field, char *dst, u16 max)
{
    unet_regs r;
    r.a = field;
    r.de = (u16)dst;
    r.ix = max;
    r.iy = 0;
    return (i8)call_fn(UNET_FN_GETINFO, &r);
}

i8 unet_lasterr(char *dst, u16 max)
{
    unet_regs r;
    r.a = 0;
    r.de = (u16)dst;
    r.ix = max;
    r.iy = 0;
    return (i8)call_fn(UNET_FN_LASTERR, &r);
}

i8 unet_setopt(u8 option, u16 value)
{
    unet_regs r;
    r.a = option;
    r.de = value;
    r.ix = 0;
    r.iy = 0;
    return (i8)call_fn(UNET_FN_SETOPT, &r);
}

i8 unet_netstatus(u16 *bits)
{
    unet_regs r;
    u8 st;
    r.a = 0xFF;
    r.de = 0; r.ix = 0; r.iy = 0;
    st = call_fn(UNET_FN_STATUS, &r);
    if (bits) *bits = r.de;
    return (i8)st;
}
