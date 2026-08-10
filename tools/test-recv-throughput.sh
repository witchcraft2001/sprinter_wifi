#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp_base=${TMPDIR:-/tmp}/sprinter-recv-throughput-vectors
raw_file=$tmp_base.bin
sym_file=$tmp_base.sym
ram_file=$tmp_base.ram

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" \
  -I "$repo_root/src/lib" \
  -I "$repo_root/src/dll" \
  --sym="$sym_file" --raw="$raw_file" "$script_dir/recv_throughput_vectors.asm"

sym_addr() {
  awk -v symbol="$1:" '$1 == symbol {sub(/^0x0*/, "", $3); print $3}' "$sym_file"
}

test_end=$(sym_addr TEST_DONE)
bench_start=$(sym_addr BENCH_START)
bench_end=$(sym_addr BENCH_DONE)
if [ -z "$test_end" ] || [ -z "$bench_start" ] || [ -z "$bench_end" ]; then
  echo "Could not find receive-throughput vector symbols in $sym_file" >&2
  exit 1
fi

z88dk-ticks -l 0 -pc 4000 -end "$test_end" -output "$ram_file" \
  "$raw_file" >/dev/null

marker=$(od -An -tu1 -j 49123 -N 1 "$ram_file" | tr -d ' ')
result=$(od -An -tu1 -j 49122 -N 1 "$ram_file" | tr -d ' ')
if [ "$marker" != 165 ] || [ "$result" != 0 ]; then
  echo "ESP payload hot-path correctness vector failed (marker $marker, result $result)" >&2
  exit 1
fi

ticks=$(z88dk-ticks -l 0 -pc "$bench_start" -end "$bench_end" "$raw_file")
case "$ticks" in
  ''|*[!0-9]*)
    echo "Invalid z88dk-ticks result: $ticks" >&2
    exit 1
    ;;
esac

max_ticks=800000
if [ "$ticks" -gt "$max_ticks" ]; then
  echo "ESP payload hot path regressed: $ticks ticks, limit $max_ticks" >&2
  exit 1
fi

echo "ESP payload hot path: $ticks ticks / 4096 bytes"
