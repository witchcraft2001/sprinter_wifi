# Repository Guidelines

## Project Scope

This repository is for developing a package of network communication programs for Sprinter DSS. Internet access is provided through the Sprinter Wi-Fi network card, SprinterESP: <https://zxgit.org/romych/SprinterESP/src/branch/master>. Keep code and documentation focused on DSS networking workflows, ESP-AT command handling, and compatibility with real Sprinter Wi-Fi hardware.

## Project Structure & Module Organization

This repository uses `src/include/` for shared include files, `src/lib/` for
reusable DSS assembly modules, and `src/apps/` for utility entry points. Build
outputs go to `build/`; distributable zip and floppy images go to `distr/`.
Package membership is controlled by `tools/artifacts.sh`.

This workspace currently sits beside two Sprinter Wi-Fi projects. `../ESPKit/` contains software for the ISA-8 ESP8266 card: `sources/DSS/` holds sjasmplus assembly programs and shared libraries (`esplib.asm`, `isa.asm`, `util.asm`), while `sources/DOS/` holds FreeDOS/Borland C++ utilities. `../SprinterESP/` contains the hardware design: editable EasyEDA JSON files in `Sources/`, reference docs in `Docs/`, exported PDFs/images/BOM files in `Export/`, and manufacturing packages in `Gerber/`. Keep generated outputs separate from editable sources.

## Build, Test, and Development Commands

Use the project scripts for normal DSS package work:

```sh
make build      # assemble known DSS apps into build/*.EXE
make package    # create distr/sprinter-net.zip
make image      # create distr/sprinter-net.img FAT12 test floppy image
make clean      # remove generated outputs
```

The scripts are intentionally tolerant while the project is being bootstrapped:
apps listed in `tools/artifacts.sh` are skipped with a warning until their
`src/apps/*.asm` entry point exists. Direct sjasmplus builds remain useful when
debugging a single source file:

```sh
sjasmplus ../ESPKit/sources/DSS/wterm.asm
sjasmplus ../ESPKit/sources/DSS/wtftp.asm
```

Use Borland C++ 3.0-compatible tooling for `../ESPKit/sources/DOS/*.c`. Open hardware sources in EasyEDA via **Document > Open > EasyEDA Source**, then regenerate `Export/` and `Gerber/` artifacts for release changes.

## Distribution Artifacts

`tools/artifacts.sh` is the single manifest used by `tools/build.sh`,
`tools/package.sh`, and `tools/image.sh`. When adding anything that must ship
with the network package, update this manifest in the same change.

Rules for future additions:

- New DSS utility: add its lowercase entry point name to `BUILD_APPS`; the source
  must be `src/apps/<name>.asm`, and scripts will build/copy
  `build/<UPPERCASE_NAME>.EXE`.
- New user documentation: add the relative path to `DIST_DOC_FILES`. Markdown is
  copied unchanged to the zip and renamed to an 8.3 `.TXT` name in the floppy
  image.
- New Cyrillic (Russian) documentation: keep the source UTF-8 in the repo and
  add its relative path to `DIST_DOC_CP866_FILES` instead of `DIST_DOC_FILES`.
  `package.sh`/`image.sh` convert it with `iconv -f UTF-8 -t CP866` so it ships
  in the DSS console code page; do not list the same file in both arrays.
- New sample configuration: add the relative path to `DIST_CONFIG_FILES`. Never
  add a real credential-bearing `NET.CFG`; ship only templates such as
  `config/NET.CFG.sample`.
- New small required runtime asset: add it to `DIST_EXTRA_FILES`.
- If an artifact needs a subdirectory or a special 8.3 name inside the floppy
  image, update `tools/image.sh` together with `tools/artifacts.sh`.
- After changing artifact lists, run at least `make package` and, when mtools is
  available, `make image`.

## Coding Style & Naming Conventions

Preserve existing style. Assembly uses tabs for instruction alignment, uppercase labels/constants, `EQU` constants, and semicolon comments. Keep reusable routines in library files and utility entry points in app-specific `.asm` files. DOS C code should remain compatible with older Borland compilers: avoid modern extensions, use uppercase macros, and follow the existing `snake_case` function and variable naming.

For DSS assembly, avoid storing large zero-filled work buffers in `.EXE`
outputs. `sjasmplus --raw` emits `DS ...,0` bytes into the file, wasting disk
space. Prefer runtime-only BSS-style labels placed after the loaded image, for
example after `WIFI.RS_BUFF + RS_BUFF_SIZE` or after another library/app BSS
end label. Clear that runtime area at program start only when the code depends
on zeroed memory. Small state variables and required initialized data may remain
in the file.

Utilities that accept long command lines must use the full 512-byte DSS EXE
header with code file offset `0x0200`. There are two valid load profiles:

- **`ORG 0x8100` (legacy, light utilities):** load address `0x8100`, entry
  point `0x8100`, command-line storage at `0x8080`. Available memory:
  `0x8100..0xBFFF` (≈16 KB). Used by simple tools where code + BSS fits
  comfortably below the `0xC000` ISA banking window. Currently: `UDPTEST`,
  `PING`, `NETUP`, `NTP`, `NETPROBE`, `NETCFG`, `WTERM`, `NETRESET`,
  `TCPTEST`.

- **`ORG 0x4100` (preferred for data-heavy utilities):** load address
  `0x4100`, entry point `0x4100`, command-line storage at
  `load_addr - 0x80 = 0x4080`, stack top `0x8000`. Code and small BSS live in
  `0x4100..0x7FFF`; large receive/file buffers should use a DSS-allocated page
  mapped in WIN2 (`0x8000..0xBFFF`). Currently: `WGET`, `TFTP`, `FTP`,
  `TELNET`.

For `ORG 0x4100` utilities, do not assume DSS allocated WIN2
(`#8000..#BFFF`) merely because the BSS map reaches that range. If the loaded
EXE body is smaller than 16 KB and does not physically occupy `#8000..#BFFF`,
DSS may allocate only WIN1 for the program; a later `GETMEM` can then hand a
separate page to the utility. Do not fix this by padding the `.EXE` body up to
`#8000`; that violates the compact EXE rule and embeds bytes that should be
runtime memory. Instead, keep `STACK_TOP EQU 0x8000` so the stack grows downward
in WIN1, make the first startup action `DSS_GETMEM` for the required page
count, open it with `DSS_SETWIN2`, and place large buffers at `WIN2_BASE EQU
0x8000`. The `RST #10` dispatcher itself uses the current stack (`PUSH HL`,
`EX (SP),HL`, `RET`), so do not generalize this into a blanket "all DSS calls
require WIN2" rule. Current examples: `WGET`, `TFTP`, `FTP`, and `TELNET`.

In both cases the header padding is allowed and is not a runtime buffer;
large runtime buffers still must live outside the `.EXE` image (use
`DS ...,0` only for small initialised state, never for receive buffers).
Define `LOAD_ADDR`, `CMDLINE_ADDR`, `STACK_TOP` constants at the top of the
utility's source and read the cmdline via `LD HL,CMDLINE_ADDR` instead of a
hard-coded address.

Keep runtime memory maps explicit. When a utility needs command, URL, packet,
TCP/UDP receive, or configuration buffers, define them with `EQU` in a BSS map
instead of `DS ...,0`, and make sure the ranges do not overlap while both values
must stay alive. For buffers used as DSS file read/write sources, keep them
below the `0xC000` banking window unless the code explicitly manages page
switching. If a future utility needs a large buffer, allocate/use DSS paged
memory and map it through available `WIN0`-`WIN3` windows instead of embedding
or assuming a large linear buffer in the `.EXE`.

Keep optional protocol modes out of common includes. Code for features that are
not used by every network utility, such as ESP-AT multi-connection mode
(`AT+CIPMUX=1`) for passive FTP or server-style tools, must live in a separate
library include or be guarded by assembly-time conditionals. Simple clients such
as WGET, PING, NTP, UDPTEST, and TFTP should not grow from unused FTP/server
helpers.

## ESP-AT Compatibility

Every program in this package must support both ESP-AT v2.2.1 and ESP-AT
v2.2.2. A normal build, with no firmware-selection flag, must use only their
common command set and capabilities; it must not assume a command or feature
that exists in only one profile. Assembly-time conditionals may build a variant
that deliberately targets one command profile, but that forced profile must be
explicit and limited to `2.2.1` or `2.2.2`. When such a forced-profile build is
enabled, its program banner must identify the target, for example
`ESP-AT 2.2.1` or `ESP-AT 2.2.2`, so that a user can distinguish it from the
compatible default build.

Network clients and diagnostics must not call `WIFI.ESP_RESET` as an implicit
communication-recovery step. `NETUP` deliberately applies Wi-Fi/UART settings
to the current ESP session, so a hidden reset invalidates the published
`NET_*` state and breaks every following utility. Retry a plain `AT` probe via
`WCOMMON.SYNC_ESP_COMMAND`, drain/close stale sockets, and return exit status 3
if command mode cannot be recovered. Hardware reset belongs only to explicit
reset/bring-up tools such as `NETRESET`, `NETUP`, and low-level terminal
workflows that clearly announce it.

For UART receive/RTS flow control, preserve the field-proven ESP-AT 2.2.1
algorithm unchanged unless it has been revalidated on real 2.2.1 hardware.
The ESP-AT 2.2.2 path may use separately developed FIFO/AFE experiments, but
do not ship automatic-AFE-only receive if sustained real `+IPD` traffic shows
overruns: retain explicit RTS pauses until it is proven reliable. A default
application must choose the matching receive algorithm at runtime from
`NET_ESP_FW`, published by a successful `NETUP`; it must not probe the firmware
again. A forced 2.2.1 or 2.2.2 build must compile only the matching algorithm,
with no runtime fallback; its banner must show the selected profile. Do not
change the 2.2.1 path merely to share code with 2.2.2. Validate any 2.2.1
change using sustained real-hardware `+IPD` traffic, including FTP/WGET/Telnet.

`NETUP` is the sole owner of ESP-side UART negotiation. It publishes the
result as `NET_BAUD` and `NET_ESP_FLOW=3/0`; clients must configure only their
local 16550 from those values and must not resend `AT+UART_CUR` or toggle AFE
while reusing the live session. Keep the complete 2.2.1 receive path, including
short AT-command replies, on its proven trigger-8 FIFO setup. Use trigger 4 for
the complete 2.2.2 receive path: a command such as `AT+CIPSTART` can be followed
immediately by peer data, so there is no reliable boundary at which a client
can switch from a trigger-8 command response to trigger-4 `+IPD` receive.
Changing a FIFO trigger with queued bytes must never reset or flush them.

## Testing Guidelines

No broad automated test suite is present. For Telnet/Zmodem changes, run
`tools/test-zmodem.sh`; it uses `sjasmplus` plus `z88dk-ticks` to execute the
actual Z80 CRC/header/subpacket routines against lrzsz-compatible vectors. For
NETUP command sequencing or `busy p...` retry changes, run
`tools/test-netup-busy.sh`; it executes the same Z80 retry loop used by NETUP
against deterministic busy/OK/error response vectors and verifies that dynamic
AT-command builders terminate dirty runtime buffers correctly. `make test`
runs all host-side harnesses. For UART FIFO/profile changes, also run
`tools/test-uart-profiles.sh`; it assembles universal FTP/WGET plus forced
2.2.1 and 2.2.2 variants. It checks the universal/2.2.1 trigger-8 compatibility
path, the forced-2.2.2 trigger-4 path, and verifies that client executables do
not contain `AT+UART_CUR` (ESP-side UART negotiation belongs only to NETUP).
For DSS assembly, also assemble every touched entry program and
smoke-test on Sprinter DSS, emulator, or hardware. For DOS utilities, compile
the changed program and verify behavior against an ESP8266 running ESP-AT
firmware. For hardware edits, run EasyEDA ERC/DRC, inspect ISA/UART signal
names, and verify regenerated PDFs, BOMs, and Gerbers before publishing.

## Exit Status Guidelines

DSS utilities that can reasonably be used from batch scripts must return a
meaningful status through `DSS_EXIT`. Use `B=0` for success. Prefer these common
non-zero codes unless a program documents a stronger reason to differ:

- `1` - invalid command line or usage error.
- `2` - Sprinter-WiFi hardware was not found.
- `3` - ESP communication error, timeout, unsupported command, unreachable
  host, or unexpected ESP response.
- `4` - configuration error, for example missing or invalid `NET.CFG`.

Document utility-specific exit status behavior in `docs/USAGE.md` whenever a
new automation-friendly program is added or changed.

## Debugging Environment

Primary debugging uses the MAME Sprinter emulator with the local `jesperl` software ESP emulator at `/Users/dmitry/dev/zx/sprinter/mame_esp/jesperl` (<https://sourceforge.net/projects/jesperl/files/>). Real-hardware debugging may use an ESP12-F/ESP8266 module connected to a COM port and flashed with ESP-AT firmware. `jesperl` does not fully emulate the needed behavior, so tasks may require improving or extending its functionality before application bugs can be isolated reliably.

When an ESP-AT command fails in MAME/`jesperl`, do not immediately assume the
command is wrong for real ESP-AT firmware. First check whether `jesperl`
implements that exact command syntax in
`/Users/dmitry/dev/zx/sprinter/mame_esp/jesperl/jesperl_xtr.pl` and compare it
with the target ESP-AT firmware behavior. If the command is missing from
`jesperl` but valid for real ESP-AT, record it as an emulator gap and prefer
either adding a fallback path or extending `jesperl` before reverting the real
firmware-oriented implementation.

Target ESP-AT V2.2.1 firmware notes verified from `/Users/dmitry/Downloads/V2.2.1`:
the package contains flashing READMEs and binary images, not an AT command
reference. A text search of the tree and a `strings` scan of all
`bin/at/*/*.bin` and `bin/at_sdio/*/*.bin` images show active TCP receive
formats such as `+IPD,%d:` and commands such as `+CIPSEND`, `+CIPSENDEX`,
`+CIPSENDBUF`, `+CIPDINFO`, and `+CIPMUX`, but no `CIPRECVMODE`,
`CIPRECVDATA`, or `CIPRECV*` strings. Do not design or change Sprinter DSS
clients to depend on ESP-AT passive TCP receive
(`AT+CIPRECVMODE=1`/`AT+CIPRECVDATA=<n>`) for this firmware unless a different
firmware image is explicitly selected and verified.

Current `jesperl` improvement mini-spec for this project:

- Support basic no-op success commands used during initialization:
  `ATE0`, `AT`, `AT+CWMODE=1`, `AT+CWMODE_CUR=1`, `AT+SLEEP=0`,
  `AT+UART_CUR=115200,8,1,0,3`, `AT+CWLAPOPT=1,23`.
- Support Wi-Fi status and connection commands:
  `AT+CWJAP?`, `AT+CWJAP="ssid","password"`,
  `AT+CWJAP_CUR="ssid","password"`, returning realistic `OK` and `+CWJAP`
  responses.
- Support IP/DHCP/DNS variants used by ESPKit and newer ESP-AT:
  `AT+CWDHCP=1,1`, `AT+CWDHCP_CUR=1,1`, `AT+CIPSTA?`,
  `AT+CIPSTA_CUR?`, `AT+CIPSTA="ip","gw","mask"`,
  `AT+CIPSTA_CUR="ip","gw","mask"`, `AT+CIFSR`, `AT+CIPDNS?`,
  `AT+CIPDNS_CUR?`, `AT+CIPDNS=1,"dns1","dns2"`,
  `AT+CIPDNS_CUR=1,"dns1","dns2"`.
- Support TCP smoke-test commands used by `tcptest.exe` and later protocol
  clients: `AT+CIPMUX=0`, `AT+CIPSTART="TCP","host",port`,
  `AT+CIPSEND=<len>` with `>` prompt and `SEND OK`, `AT+CIPCLOSE`,
  `CLOSED`, and `+IPD,<len>:<binary payload>`.
- Do not add `AT+CIPRECVMODE`/`AT+CIPRECVDATA` to `jesperl` as a required path
  for project utilities while the target hardware firmware is ESP-AT V2.2.1.
  Emulator support for those commands would model a different firmware and must
  be treated as optional, not as proof of hardware support.
- Pace `+IPD` output toward MAME/Z80 instead of writing large TCP bursts
  instantaneously. Provide configurable knobs such as `JESPERL_IPD_CHUNK`
  (suggested default 256 or 512 bytes for debugging, 1500 for stress tests) and
  `JESPERL_Z_PACE_US` (delay between small output slices).
- Treat pacing as an emulator fidelity feature, not as a protocol change: real
  ESP modules deliver bytes through UART timing and hardware flow control, while
  current MAME/`jesperl` may not emulate RTS/CTS deeply enough to absorb large
  immediate bursts.
- `AT+CIPSTART` must not block the whole emulator process on OS-level TCP
  connect. Use non-blocking connect or a short explicit timeout, keep accepting
  Z-side input while a connection is pending, and let ESP reset/close commands
  abort the pending connect. Otherwise MAME appears to have a wedged ESP after
  a client tries an unreachable host.
- Support diagnostic commands used by `ping.exe`, especially `AT+PING="host"`
  with realistic `+PING:<time_ms>` and `OK` responses, plus `ERROR` for
  invalid or unreachable hosts.
- Support ESP SNTP commands used by `ntp.exe`: `AT+CIPSNTPCFG=1,<tz>,"server"`
  should store runtime SNTP settings and `AT+CIPSNTPTIME?` should return a
  realistic `+CIPSNTPTIME:<weekday> <month> <day> <hh:mm:ss> <year>` response
  followed by `OK`.
- Preserve enough emulator state to make the sequence realistic: selected SSID,
  connected/disconnected state, DHCP enabled flag, station IP/gateway/netmask,
  DNS servers.
- Keep responses close to ESP-AT style: CRLF line endings, final `OK`/`ERROR`,
  and optional informational lines such as `+CWJAP:...`, `+CIFSR:STAIP,...`,
  `+CIPSTA:ip:...`.
- Add quick host-side checks, for example `printf 'AT+CWJAP?\\r\\n' | nc ...`,
  for each newly supported command family.

## Commit & Pull Request Guidelines

Existing commits are short and descriptive, such as `optimization`, `Update README.md`, and `Refactoring code for best reuse in other utilities`. Prefer clearer imperative subjects, for example `Fix RTS/CTS handling in ESP library`. Pull requests should describe software or hardware scope, list manual tests and build commands, link related issues or docs, and include updated screenshots, PDFs, BOMs, or Gerbers when board outputs change.

## Security & Configuration Tips

Do not commit Wi-Fi credentials, local serial-port settings, temporary build files, or machine-specific IDE state. Document ESP-AT firmware version requirements when behavior depends on them.

## External reference sources
- You may consult the following local sibling repositories/directories for answers, platform details, and implementation ideas:
  - `/Users/dmitry/dev/zx/sprinter/sprinter_bios`
  - `/Users/dmitry/dev/zx/sprinter/Estex-DSS`
  - `/Users/dmitry/dev/zx/sprinter/sprinter_ai_doc/manual`
  - `/Users/dmitry/dev/zx/sprinter/sources/tasm_071/TASM`
  - `/Users/dmitry/dev/zx/sprinter/sources/fformat/src/fformat_v113`
  - `/Users/dmitry/dev/zx/sprinter/sources/fm/FM-SRC/FM`
  - `/Users/dmitry/dev/zx/sprinter/sdcc-sprinter-sdk`
  - `/Users/dmitry/dev/zx/sprinter/utils`
  - `/Users/dmitry/dev/zx/sprinter/sprinter_wifi/ESPKit`
  - `/Users/dmitry/dev/zx/sprinter/sprinter_wifi/SprinterESP`
  - `/Users/dmitry/dev/zx/sprinter/sprinter-rtl8019a` - CLI standard source
    for analogous network utilities such as WGET, FTP, and TFTP.
  - `/Users/dmitry/dev/zx/zx-wifi`
- Treat them as reference material only; this repository remains the source of truth for changes you make here.
