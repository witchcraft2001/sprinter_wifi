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

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" \
  -I "$repo_root/src/lib" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/ftp_receive_vectors.asm"

start_addr=$(awk '/^TEST_START:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
test -n "$start_addr"
test -n "$end_addr"
z88dk-ticks -l 16128 -pc "$start_addr" -end "$end_addr" -output "$ram_file" \
  "$raw_file" >/dev/null
marker=$(od -An -tu1 -j 49153 -N 1 "$ram_file" | tr -d ' ')
result=$(od -An -tu1 -j 49152 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ] || [ "$result" != 0 ]; then
  echo "FTP receive status vector $result failed (marker $marker)" >&2
  exit 1
fi
echo "FTP receive status and UART error precedence vectors: OK"

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/ftp_irq_vectors.asm"
start_addr=$(awk '/^TEST_START:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
test -n "$start_addr"
test -n "$end_addr"
# A single clean 4K receive plus error probes is well below 2M cycles. A
# regression into the 20000-tick idle wait fails this bound and the marker.
ticks=$(z88dk-ticks -l 16128 -pc "$start_addr" -end "$end_addr" \
  -counter 2000000 -output "$ram_file" "$raw_file")
marker=$(od -An -tu1 -j 49153 -N 1 "$ram_file" | tr -d ' ')
result=$(od -An -tu1 -j 49152 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ] || [ "$result" != 0 ]; then
  echo "FTP IRQ/fast UART abort vector $result failed (marker $marker)" >&2
  exit 1
fi
echo "FTP IRQ preservation, RTS return and immediate UART abort: OK ($ticks ticks)"

idle_addr=$(awk '/^BENCH_IDLE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
test -n "$idle_addr"
ticks=$(z88dk-ticks -l 16128 -pc "$idle_addr" -end "$end_addr" \
  -counter 24000000 -output "$ram_file" "$raw_file")
marker=$(od -An -tu1 -j 49153 -N 1 "$ram_file" | tr -d ' ')
result=$(od -An -tu1 -j 49152 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ] || [ "$result" != 0 ] || \
   [ "$ticks" -lt 19000000 ] || [ "$ticks" -gt 23000000 ]; then
  echo "FTP stable-RTS idle vector $result failed ($ticks ticks, marker $marker)" >&2
  exit 1
fi
echo "FTP 1000-tick idle: $ticks cycles, only 5 keyboard RTS pauses (21 MHz)"

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/ftp_trace_vectors.asm"
start_addr=$(awk '/^TEST_START:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
test -n "$start_addr"
test -n "$end_addr"
z88dk-ticks -l 16128 -pc "$start_addr" -end "$end_addr" \
  -counter 2000000 -output "$ram_file" "$raw_file" >/dev/null
marker=$(od -An -tu1 -j 49153 -N 1 "$ram_file" | tr -d ' ')
result=$(od -An -tu1 -j 49152 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ] || [ "$result" != 0 ]; then
  echo "FTP boundary trace vector $result failed (marker $marker)" >&2
  exit 1
fi
echo "FTP boundary trace: sticky FE, register/flow preservation, 2.2.1 bypass: OK"
