#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp_base=${TMPDIR:-/tmp}/sprinter-recv-timeout-vectors
raw_file=$tmp_base.bin
sym_file=$tmp_base.sym
ram_file=$tmp_base.ram

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" \
  -I "$repo_root/src/lib" \
  -I "$repo_root/src/dll" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/recv_timeout_vectors.asm"

end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
bench_start=$(awk '/^TIMEOUT_BENCH_START:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
bench_end=$(awk '/^TIMEOUT_BENCH_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
if [ -z "$end_addr" ] || [ -z "$bench_start" ] || [ -z "$bench_end" ]; then
  echo "Could not find timeout vector symbols in $sym_file" >&2
  exit 1
fi

z88dk-ticks -l 0 -pc 4000 -end "$end_addr" -output "$ram_file" \
  "$raw_file" >/dev/null

marker=$(od -An -tu1 -j 49121 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ]; then
  echo "UNETESP zero-timeout vectors did not run to completion (marker $marker)" >&2
  exit 1
fi

result=$(od -An -tu1 -j 49120 -N 1 "$ram_file" | tr -d ' ')
if [ "$result" != 0 ]; then
  echo "UNETESP zero-timeout vector $result failed" >&2
  exit 1
fi

ticks=$(z88dk-ticks -l 0 -pc "$bench_start" -end "$bench_end" "$raw_file")
case "$ticks" in
  ''|*[!0-9]*)
    echo "Invalid z88dk-ticks timeout result: $ticks" >&2
    exit 1
    ;;
esac

# BC=2 must use just one initial spin window and one delay tick, never the
# historical repeated spin+delay unit.
max_ticks=25000
if [ "$ticks" -gt "$max_ticks" ]; then
  echo "UNETESP idle RECV timeout regressed: $ticks ticks, limit $max_ticks" >&2
  exit 1
fi

echo "UNETESP RECV timeout vectors: OK ($ticks ticks / one RTL idle tick)"

# Measure the real production delay path, not TEST_DELAY_TICK. The UART is
# empty RAM and DSS SCANKEY is non-blocking, but delay/RTS/ISA code is real.
sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" -I "$repo_root/src/dll" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/recv_cycle_vectors.asm"
end_addr=$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
for entry in BENCH_DISABLED BENCH_ENABLED TEST_CANCEL TEST_ARRIVAL; do
  start_addr=$(awk -v label="$entry:" '$1 == label {sub(/^0x0*/, "", $3); print $3}' "$sym_file")
  test -n "$start_addr" && test -n "$end_addr"
  ticks=$(z88dk-ticks -l 0 -pc "$start_addr" -end "$end_addr" -output "$ram_file" "$raw_file")
  marker=$(od -An -tu1 -j 49121 -N 1 "$ram_file" | tr -d ' ')
  result=$(od -An -tu1 -j 49120 -N 1 "$ram_file" | tr -d ' ')
  if [ "$marker" != 165 ] || [ "$result" != 0 ]; then
    echo "UNETESP production idle path failed: $entry ($marker/$result)" >&2
    exit 1
  fi
  # RTL DELAY_1MS uses 400 DEC/LD/OR/JR iterations (~10400 T-states).
  # 999 such ticks plus bounded UART/ISA overhead must fit in 12M cycles.
  # A lower bound also catches a timeout silently returning too soon.
  case "$entry" in
    BENCH_*) min_ticks=10400000; max_ticks=12000000 ;;
    *) min_ticks=20000; max_ticks=100000 ;;
  esac
  case "$ticks" in ''|*[!0-9]*) echo "Invalid cycle count: $ticks" >&2; exit 1 ;; esac
  if [ "$ticks" -lt "$min_ticks" ] || [ "$ticks" -gt "$max_ticks" ]; then
    echo "UNETESP $entry: $ticks cycles outside $min_ticks..$max_ticks" >&2
    exit 1
  fi
  echo "UNETESP $entry: OK ($ticks cycles, interrupts disabled)"
done
