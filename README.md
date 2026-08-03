# Sprinter ESP Network Kit

Network utility package for Sprinter DSS and the SprinterESP Wi-Fi card
(ESP12-F/ESP8266 with ESP-AT firmware).

Package version: 0.2.1

## Attribution

Sprinter ESP Network Kit project author:

- Dmitry Mikhalchenkov, FidoNet: 2:5030/1997.10

This project builds on Sprinter-Wi-Fi / ESPKit DSS code authored by Roman
Boykov. The imported UART, ISA and ESP-AT support modules retain their original
BSD 3-Clause license headers.

Original SprinterESP / Sprinter-Wi-Fi repository:

https://github.com/romychs/SprinterESP

Additional project mirror/reference:

https://zxgit.org/romych/SprinterESP

Current status: project foundation, shared config, Wi-Fi bring-up and initial
TCP client core are in place. Implementation plan is tracked in `specs.md`.

New here? Start with `docs/HOWTO.TXT` (one-screen quick start: configure,
connect, test). Full reference is in `docs/USAGE.md`.

## Package Contents

- `NETPROBE.EXE`
- `NETRESET.EXE`
- `NETCFG.EXE`
- `NETUP.EXE`
- `TCPTEST.EXE`
- `UDPTEST.EXE`
- `TFTP.EXE`
- `FTP.EXE`
- `PING.EXE`
- `WGET.EXE`
- `NTP.EXE`
- `WTERM.EXE`
- `TELNET.EXE`

## Configuration

Use `config/NETSMPL.CFG` as the template for runtime network configuration
(copy it to `NET.CFG`, or just run `NETCFG.EXE /W`). Do not commit real Wi-Fi
credentials.

Recommended DSS install directory is `C:\WIFI`. Add that directory to `PATH`, or
change to it before running the tools. The runtime `NET.CFG` should live with
the installed network kit files.

On Sprinter DSS:

```text
NETCFG.EXE       show current NET.CFG values
NETCFG.EXE /W    edit and save NET.CFG interactively
NETUP.EXE        initialize ESP and connect using NET.CFG
TCPTEST.EXE      connect to example.com:80 and print a short HTTP response
TCPTEST.EXE host port path
                 test an HTTP path on a custom host and port
UDPTEST.EXE host port [message [local_port]]
                 send one UDP datagram and wait for one reply
TFTP.EXE host[:port] GET remote [-o local] [-y|-f]
                 download one file over TFTP (-y/-f overwrite; no resume)
TFTP.EXE host[:port] PUT local [-o remote]
                 upload one file over TFTP
FTP.EXE host[:port] file [-o output] [-u user] [-p pass] [-y|-f] [-r] [-d]
                 download one file over passive FTP (-y/-f overwrite, -r resume,
                 -d dot progress instead of the KB counter)
FTP.EXE host[:port] PUT local [-o remote] [-u user] [-p pass]
                 upload one file over passive FTP
FTP.EXE host[:port] [path] -l|-n [-u user] [-p pass]
                 login, enter passive mode and print a LIST/NLST listing
PING.EXE host    test host reachability using ESP-AT AT+PING
WGET.EXE url [-o output] [-y|-f] [-r] [-d]
                 download an http:// URL to a local file (-y/-f overwrite, -r resume,
                 -d dot progress instead of the KB counter)
NTP.EXE          set DSS time using NET_TZ/NET_NTP published by NETUP.EXE
TELNET.EXE host[:port] | host [port]
                 ANSI Telnet client with Zmodem and Ymodem download/upload
```

Example batch files are included in the package root:

```text
CONNECT.BAT      NETRESET, NETUP and PING 8.8.8.8
TFTPGET.BAT      sample TFTP download from 192.168.1.36
TFTPPUT.BAT      sample TFTP upload to 192.168.1.36
UDPECHO.BAT      UDPTEST 192.168.1.36 7777 hello
```

`NETCFG.EXE /W` stores the Wi-Fi password as clear text.
`NETUP.EXE` supports ESP-AT 2.2.1 and 2.2.2 without per-command fallbacks. It
probes `AT+SYSSTORE?` once: `ERROR` selects the 2.2.1 `_CUR` profile, while
`OK` selects 2.2.2 and first sends `AT+SYSSTORE=0`. Therefore Wi-Fi settings
remain session-only on both profiles. It prints and publishes the result as
`NET_ESP_FW=2.2.1` or `NET_ESP_FW=2.2.2`; software that needs
`AT+CIPRECVMODE=1` must require the 2.2.2 profile. NETUP also publishes the
actually negotiated UART flow-control mode as `NET_ESP_FLOW=3` or `0`;
clients reproduce that local 16550 mode without sending `AT+UART_CUR` again.
`BAUD` in `NET.CFG` may be set to `230400`, `115200`, `57600`, `38400`,
`19200` or `9600`; automated tools use it after `NETUP.EXE` configures the ESP with
`AT+UART_CUR`.

## ESP-AT Firmware Baseline

The recommended firmware is ESP8266 ESP-AT `V2.2.2.0`, image
[`firmware/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin`](firmware/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin).
It is also available from the
[Sprinter ESP Network Kit GitHub repository](https://github.com/witchcraft2001/sprinter_wifi/blob/main/firmware/SprinterESP-AT-v2.2.2.0-runtime-flow-fix-full-2MB.bin).
Use [the flashing guide](firmware/FLASHING.md) to install it.

V2.2.2.0 is the stable, supported baseline for this release. The package still
has a compatibility path for ESP-AT `V2.2.1`, but upgrading is strongly
recommended. Reports of corrupt downloads, missing bytes, slow transfers, or
similar transfer instability on an otherwise correct setup should be treated as
a V2.2.1 limitation first.

The supported transition profiles are ESP8266 ESP-AT `V2.2.1` and `V2.2.2`.
The 2.2.1 firmware contains command tokens for the project-critical command
families below:

- Basic: `AT`, `ATE0`, `AT+GMR`, `AT+RST`, `AT+RESTORE`, `AT+SLEEP`,
  `AT+GSLP`, `AT+SYSMSG`.
- UART: `AT+UART`, `AT+UART_CUR`, `AT+UART_DEF`, legacy `AT+IPR`.
- Wi-Fi station/AP: `AT+CWMODE`, `AT+CWMODE_CUR`, `AT+CWMODE_DEF`,
  `AT+CWJAP`, `AT+CWJAP_CUR`, `AT+CWJAP_DEF`, `AT+CWQAP`, `AT+CWLAP`,
  `AT+CWLAPOPT`, `AT+CWAUTOCONN`, `AT+CWHOSTNAME`, `AT+CIFSR`.
- IP/DNS/DHCP: `AT+CIPSTA`, `AT+CIPSTA_CUR`, `AT+CIPSTA_DEF`,
  `AT+CIPAP`, `AT+CIPAP_CUR`, `AT+CIPAP_DEF`, `AT+CIPDNS_CUR`,
  `AT+CIPDNS_DEF`, `AT+CWDHCP`, `AT+CWDHCP_CUR`, `AT+CWDHCP_DEF`.
- TCP/UDP client/server: `AT+CIPSTART`, `AT+CIPCLOSE`, `AT+CIPSEND`,
  `AT+CIPSENDEX`, `AT+CIPSENDBUF`, `AT+CIPMUX`, `AT+CIPMODE`,
  `AT+CIPSTATUS`, `AT+CIPSERVER`, `AT+CIPSERVERMAXCONN`, `AT+CIPSTO`,
  `AT+CIPDINFO`, `AT+CIPDOMAIN`, `AT+CIPSSLSIZE`.
- Diagnostics and time: `AT+PING`, `AT+CIPSNTPCFG`, `AT+CIPSNTPTIME`.

The V2.2.1 firmware do not contain `AT+CIPRECVMODE` or `AT+CIPRECVDATA`, so
ESP-AT passive TCP receive should be treated as unsupported for this firmware.
WGET must keep a reliable active `+IPD` receive path for V2.2.1.

The same firmware does expose multi-connection TCP/UDP support through
`AT+CIPMUX`, link-id `AT+CIPSTART`/`AT+CIPSEND` responses and
`+IPD,<link>,<len>:...` receive frames. This is the baseline planned for
passive FTP, where the control and data sockets must be open at the same time.
These helpers live in `src/lib/esp_tcp_multi.asm` and should be included only
by programs that explicitly enable `AT+CIPMUX=1`.

## License

BSD 3-Clause. See `LICENSE`.
