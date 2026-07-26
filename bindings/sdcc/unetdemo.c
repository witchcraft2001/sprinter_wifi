/*
 * unetdemo.c - minimal C consumer of the UNET network DLL.
 *
 *   UNETDEMO                 (defaults: UNETESP.DLL, example.com:80)
 *
 * Bring the network up first (NETUP). Build in the compact layout so the DLL
 * owns window 1 (see the Makefile: CODE_LOC = 0x8100).
 */
#include <stdio.h>
#include <sprinter.h>
#include "unet.h"

/* Resolved against the current directory (DSS does not search PATH or the
   EXE's own directory). Run UNETDEMO from the directory that holds the DLL,
   or change this to a full path such as "C:\\WIFI\\UNETESP.DLL". */
#define DLL_NAME "UNETESP.DLL"
#define HOST     "example.com"
#define PORT     "80"

static char buf[512];

void main(void)
{
    i8  rc;
    u16 caps, bits;
    i16 n;

    dss_clrscr();
    printf("UNETDEMO - C binding smoke test\r\n");

    rc = unet_load(DLL_NAME, 1);
    if (rc != UNET_LOAD_OK) {
        printf("load failed: %d\r\n", rc);
        return;
    }

    caps = unet_caps();
    printf("caps = 0x%X\r\n", caps);

    rc = unet_netstatus(&bits);
    printf("net status: %d (bits 0x%X)\r\n", rc, bits);

    rc = unet_init();
    if (rc != NERR_OK) {
        printf("NETINIT failed: %d\r\n", rc);
        unet_lasterr(buf, sizeof(buf));
        printf("lasterr: %s\r\n", buf);
        unet_free();
        return;
    }

    if (unet_getinfo(UNET_IF_IP, buf, sizeof(buf)) == NERR_OK)
        printf("IP: %s\r\n", buf);

    n = unet_ping(HOST, 3000);
    if (n >= 0) printf("ping: %d ms\r\n", n);
    else        printf("ping failed: %d\r\n", -n);

    rc = unet_connect(HOST, PORT);
    if (rc != NERR_OK) {
        printf("connect failed: %d\r\n", rc);
        unet_free();
        return;
    }

    unet_send("HEAD / HTTP/1.0\r\nHost: " HOST "\r\nConnection: close\r\n\r\n",
              (u16)sizeof("HEAD / HTTP/1.0\r\nHost: " HOST "\r\nConnection: close\r\n\r\n") - 1);

    printf("--- reply ---\r\n");
    for (;;) {
        n = unet_recv(buf, sizeof(buf) - 1, 4000, 0);
        if (n > 0) { buf[n] = 0; printf("%s", buf); continue; }
        if (n == 0) break;          /* idle */
        break;                       /* closed / error */
    }
    printf("\r\n--- done ---\r\n");

    unet_close();
    unet_done();
    unet_free();
}
