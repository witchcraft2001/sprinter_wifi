#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp_base=${TMPDIR:-/tmp}/sprinter-ftp-burst-vectors
raw_file=$tmp_base.bin
sym_file=$tmp_base.sym
ram_file=$tmp_base.ram

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" \
  -I "$repo_root/src/lib" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/ftp_burst_vectors.asm"

end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
if [ -z "$end_addr" ]; then
  echo "Could not find TEST_DONE in $sym_file" >&2
  exit 1
fi

z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -output "$ram_file" \
  "$raw_file" >/dev/null

marker=$(od -An -tu1 -j 49153 -N 1 "$ram_file" | tr -d ' ')
result=$(od -An -tu1 -j 49152 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ] || [ "$result" != 0 ]; then
  echo "FTP multi-link burst vector $result failed (marker $marker)" >&2
  exit 1
fi

echo "FTP multi-link in-window burst vectors: OK"
