#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mkdir -p "$repo_root/build"
sjasmplus --nologo --fullpath -DFTP_UART_TRACE \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$repo_root/build/FTPTRACE.sym" \
  --lst="$repo_root/build/FTPTRACE.lst" \
  --raw="$repo_root/build/FTPTRACE.EXE" "$repo_root/src/apps/ftp.asm"
echo "Built build/FTPTRACE.EXE (diagnostic only; not a download-error fix)"
