#!/usr/bin/env bash

# Central artifact manifest for build, package and floppy image scripts.
# When a new DSS utility, document, config template or bundled data file becomes
# part of the network package, add it here first.

DIST_NAME="sprinter-net"
DIST_DIR_NAME="SPNET"

# DSS application entry points. Each item maps to src/apps/<name>.asm and
# build/<UPPERCASE_NAME>.EXE. Add apps here only when their source is present.
# Planned apps include: wget, ntp, tftp, ftp and chat.
BUILD_APPS=(
  netprobe
  netreset
  netcfg
  netup
  tcptest
  udptest
  ping
  wget
  ntp
  tftp
  ftp
  wterm
  telnet
  unettest
)

# The experimental libman DLL. It is built and shipped on the diagnostic
# floppy image next to UNETTEST.EXE, but kept out of the release ZIP (see
# ZIP_EXCLUDE_DLLS) while the DLL API is still experimental.
BUILD_DLLS=(
  unetesp
)

# Applications that are built from source but intentionally omitted from the
# ZIP package.
ZIP_EXCLUDE_APPS=(
  tcptest
  udptest
  unettest
)

# DLLs that are built and copied to the floppy image but omitted from the ZIP
# package (experimental; ship on the diagnostic floppy only).
ZIP_EXCLUDE_DLLS=(
  unetesp
)

# Text/documentation files copied to the distribution root.
DIST_DOC_FILES=(
  README.TXT
  docs/HOWTO.TXT
  docs/USAGE.md
  docs/NETCFG.TXT
  docs/NETUP.TXT
  docs/NETRESET.TXT
  docs/NETPROBE.TXT
  docs/PING.TXT
  docs/WGET.TXT
  docs/NTP.TXT
  docs/TFTP.TXT
  docs/FTP.TXT
  docs/WTERM.TXT
  docs/TELNET.TXT
  LICENSE
)

# Documentation files stored as UTF-8 in the repo but that MUST ship in the
# distribution (zip and floppy image) encoded as CP866, the code page the DSS
# console uses for Cyrillic. package.sh / image.sh convert these with iconv
# instead of copying them verbatim. Do NOT also list them in DIST_DOC_FILES.
DIST_DOC_CP866_FILES=(
  READMERU.TXT
  docs/HOWTO_RU.TXT
)

# Configuration examples copied to the distribution root.
DIST_CONFIG_FILES=(
  config/NETSMPL.CFG
)

# Extra files copied to the distribution root. Keep this for small required
# runtime files that are neither docs nor configs.
DIST_EXTRA_FILES=(
  VERSION
  CONNECT.BAT
  examples/TFTPGET.BAT
  examples/TFTPPUT.BAT
  examples/WGETTRD.BAT
  examples/FTPLIST.BAT
)
